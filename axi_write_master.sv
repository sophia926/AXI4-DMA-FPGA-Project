module axi_write_master #(
    parameter int ADDR_WIDTH    = 32,
    parameter int DATA_WIDTH    = 32,
    parameter int LENGTH_WIDTH  = 32,
    parameter int FIFO_DEPTH    = 16,
    parameter int MAX_BURST_LEN = 16
) (
    input  logic clk,
    input  logic rst_n,

    // ============================================================
    // DMA WRITE COMMAND
    // ============================================================
    input  logic [ADDR_WIDTH-1:0]   cmd_dest_addr,
    input  logic [LENGTH_WIDTH-1:0] cmd_length_bytes,
    input  logic                    cmd_valid,
    output logic                    cmd_ready,

    // ============================================================
    // STATUS
    // ============================================================
    output logic busy,
    output logic done,
    output logic error,

    // ============================================================
    // AXI4 WRITE ADDRESS CHANNEL
    // ============================================================
    output logic [ADDR_WIDTH-1:0] m_axi_awaddr, // starting destination byte address for burst
    output logic [7:0]            m_axi_awlen, // number of beats in burst minus one
    output logic [2:0]            m_axi_awsize, // encoded number of bytes in each beat
    output logic [1:0]            m_axi_awburst, // address behavior across the burst, 2'b01 means incrementing
    output logic                  m_axi_awvalid, // indicates that the write-address request is valid
    input  logic                  m_axi_awready, // sent by memory when it accepts that request

    // ============================================================
    // AXI4 WRITE DATA CHANNEL
    // ============================================================
    output logic [DATA_WIDTH-1:0]   m_axi_wdata, // current data word being written
    output logic [DATA_WIDTH/8-1:0] m_axi_wstrb, // one bit per byte indicating which bytes of m_axi_wdata are valid
    output logic                    m_axi_wlast, // indicates teh final data beat of the current burst
    output logic                    m_axi_wvalid, // indicates that the current write-data beat is valid
    input  logic                    m_axi_wready, // sent by memory when it can accept the current beat

    // ============================================================
    // AXI4 WRITE RESPONSE CHANNEL
    // ============================================================
    input  logic [1:0] m_axi_bresp,
    input  logic       m_axi_bvalid,
    output logic       m_axi_bready, // when the master is ready to accept the response

    // ============================================================
    // DMA FIFO READ INTERFACE
    // ============================================================
    input  logic [DATA_WIDTH-1:0] fifo_read_data,
    input  logic                  fifo_read_valid,
    output logic                  fifo_read_ready,

    // Number of words currently stored in the FIFO
    input logic [$clog2(FIFO_DEPTH+1)-1:0] fifo_count
);

    // ============================================================
    // DERIVED PARAMETERS
    // ============================================================
    localparam int BYTES_PER_BEAT = DATA_WIDTH / 8;
    localparam int AXI_SIZE       = $clog2(BYTES_PER_BEAT);

    localparam int BURST_COUNT_WIDTH =
        (MAX_BURST_LEN <= 1) ? 1 : $clog2(MAX_BURST_LEN + 1);

    // ============================================================
    // STATE MACHINE
    // ============================================================
    typedef enum logic [2:0] {
        IDLE,
        PREPARE_AW,
        WAIT_DATA,
        SEND_AW,
        SEND_W,
        WAIT_B
    } state_t;

    state_t state;

    // ============================================================
    // COMMAND AND TRANSFER REGISTERS
    // ============================================================

    // Destination address for the current or next burst
    logic [ADDR_WIDTH-1:0] current_addr;

    // Bytes from the DMA command not yet completed
    logic [LENGTH_WIDTH-1:0] bytes_remaining;

    // Number of beats in the current burst
    logic [BURST_COUNT_WIDTH-1:0] burst_beats;

    // Number of write-data beats already accepted
    logic [BURST_COUNT_WIDTH-1:0] beat_count;

    // ============================================================
    // BURST CALCULATION SIGNALS
    // ============================================================
    logic [LENGTH_WIDTH-1:0] beats_remaining;
    logic [LENGTH_WIDTH-1:0] beats_to_4k_boundary;
    logic [BURST_COUNT_WIDTH-1:0] next_burst_beats;

    // ============================================================
    // HANDSHAKE SIGNALS
    // ============================================================
    logic cmd_fire;
    logic aw_fire;
    logic w_fire;
    logic b_fire;

    // ============================================================
    // BURST-LENGTH CALCULATION
    // ============================================================
    always_comb begin
        // Convert bytes_remaining into beats_remaining
        beats_remaining = bytes_remaining / BYTES_PER_BEAT;

        // Determine the number of beats before the next 4 KB boundary
        beats_to_4k_boundary = (4096-current_addr[11:0]) / BYTES_PER_BEAT;

        // Choose the minimum of: beats_remaining, MAX_BURST_LEN, and beats_to_4k_boundary -> assign it to next_burst_beats
        if (beats_remaining < MAX_BURST_LEN) begin
            if (beats_remaining < beats_to_4k_boundary) next_burst_beats = beats_remaining;
            else next_burst_beats = beats_to_4k_boundary;
        end
        else begin // MAX_BURST_LEN < beats_remaining
            if (MAX_BURST_LEN < beats_to_4k_boundary) next_burst_beats = MAX_BURST_LEN;
            else next_burst_beats = beats_to_4k_boundary;
        end
    end

    // ============================================================
    // OUTPUT AND HANDSHAKE LOGIC
    // ============================================================
    always_comb begin
        // Default command and status outputs
        cmd_ready = 1'b0;
        busy      = 1'b0;

        // Default AXI write-address outputs
        m_axi_awaddr  = current_addr;
        m_axi_awlen   = burst_beats - 1'b1;
        m_axi_awsize  = AXI_SIZE;
        m_axi_awburst = 2'b01;
        m_axi_awvalid = 1'b0;

        // Default AXI write-data outputs
        m_axi_wdata  = fifo_read_data;
        m_axi_wstrb  = {DATA_WIDTH/8{1'b1}};
        m_axi_wlast  = 1'b0;
        m_axi_wvalid = 1'b0;

        // Default AXI response output
        m_axi_bready = 1'b0;

        // Default FIFO control
        fifo_read_ready = 1'b0;

        // Default handshake signals
        cmd_fire = 1'b0;
        aw_fire  = 1'b0;
        w_fire   = 1'b0;
        b_fire   = 1'b0;

        case (state)
            IDLE: begin
                cmd_ready = 1'b1;
                busy = 1'b0;
                // Accept a DMA write command
                cmd_fire = cmd_valid && cmd_ready;
            end

            PREPARE_AW: begin
                busy = 1'b1;
            end

            WAIT_DATA: begin
                // Wait until the FIFO contains the complete burst.
                busy = 1'b1;
                m_axi_awvalid = 1'b0;
            end

            SEND_AW: begin
                // Present the AXI write-address request.
                busy = 1'b1;
                m_axi_awvalid = 1'b1;
                aw_fire = m_axi_awvalid && m_axi_awready;
            end

            SEND_W: begin
                // Transfer FIFO words over the AXI W channel.
                busy = 1'b1;
                m_axi_wvalid = fifo_read_valid;
                fifo_read_ready = m_axi_wready;
                if (beat_count == burst_beats - 1) m_axi_wlast = 1'b1;
                w_fire = m_axi_wvalid && m_axi_wready;
            end

            WAIT_B: begin
                // Accept the AXI write response.
                busy = 1'b1;
                m_axi_bready = 1'b1;
                b_fire = m_axi_bvalid && m_axi_bready;
            end

            default: begin
                // Keep default outputs.
            end
        endcase
    end

    // ============================================================
    // STATE, ADDRESS, AND COUNTER UPDATES
    // ============================================================
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state           <= IDLE;
            current_addr    <= '0;
            bytes_remaining <= '0;
            burst_beats     <= '0;
            beat_count      <= '0;
            done            <= 1'b0;
            error           <= 1'b0;
        end
        else begin
            // done will be a one-cycle pulse.
            done <= 1'b0;

            if (cmd_fire) begin
                if (cmd_dest_addr % BYTES_PER_BEAT!=0 || cmd_length_bytes%BYTES_PER_BEAT!=0) begin
                    error <= 1'b1;
                    done <= 1'b1;
                    state <= IDLE;
                end
                else begin
                    current_addr <= cmd_dest_addr;
                    bytes_remaining <= cmd_length_bytes;
                    error <= 1'b0;
                    beat_count <= '0;
                    burst_beats <= '0;
                    state <= PREPARE_AW;
                end
            end

            else if (state==PREPARE_AW) begin
                if (next_burst_beats=='0) begin
                    done <= 1'b1;
                    state <= IDLE;
                end
                else begin
                    burst_beats <= next_burst_beats;
                    beat_count <= '0;
                    state <= WAIT_DATA;
                end
            end

            else if (state==WAIT_DATA) begin
                if (fifo_count >= burst_beats) begin
                    state <= SEND_AW;
                end
            end

            else if (aw_fire) begin
                beat_count <= '0;
                state <= SEND_W;
            end

            else if (w_fire) begin
                beat_count <= beat_count + 1'b1;
                if (beat_count == burst_beats - 1) begin
                    state <= WAIT_B;
                end
            end

            else if (b_fire) begin
                case (m_axi_bresp)
                    2'b10, 2'b11: error <= 1'b1;
                    default: ;
                endcase

                if (bytes_remaining == burst_beats * BYTES_PER_BEAT) begin
                    bytes_remaining <= '0;
                    done <= 1'b1;
                    state <= IDLE;
                end
                else begin
                    current_addr <= current_addr + burst_beats * BYTES_PER_BEAT;
                    bytes_remaining <= bytes_remaining - burst_beats * BYTES_PER_BEAT;
                    state <= PREPARE_AW; // calculate the next burst
                end
            end

        end
    end

endmodule