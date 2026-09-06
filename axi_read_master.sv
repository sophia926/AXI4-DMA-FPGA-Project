module axi_read_master #(
    parameter int ADDR_WIDTH    = 32,
    parameter int DATA_WIDTH    = 32,
    parameter int LENGTH_WIDTH  = 32,
    parameter int MAX_BURST_LEN = 16
) (
    input  logic clk,
    input  logic rst_n,

    // ============================================================
    // DMA READ COMMAND
    // ============================================================
    input  logic [ADDR_WIDTH-1:0]   cmd_source_addr,
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
    // AXI4 READ ADDRESS CHANNEL
    // ============================================================
    output logic [ADDR_WIDTH-1:0] m_axi_araddr, // Starting byte address of the requested read burst
    output logic [7:0]            m_axi_arlen, // number of beats in the burst minus on
    output logic [2:0]            m_axi_arsize, // number of bytes per beat, log2(bytes)
    output logic [1:0]            m_axi_arburst, // addressing mode used across the burst
    output logic                  m_axi_arvalid, // read master is presenting a valid burst request
    input  logic                  m_axi_arready, // AXI slave is ready to accept the burst request 

    // ============================================================
    // AXI4 READ DATA CHANNEL
    // ============================================================
    input  logic [DATA_WIDTH-1:0] m_axi_rdata, // data word returned by the AXI slave
    input  logic [1:0]            m_axi_rresp, // indicates whether the current read beat completed successfuly or returned an error
    input  logic                  m_axi_rlast, // indicates that the current data beat is the final beat of the burst
    input  logic                  m_axi_rvalid, // indicates that m_axi_rdata, m_axi_rresp, and m_axi_rlast are valid
    output logic                  m_axi_rready, // indicates that the read master is ready to accept the current read beat

    // ============================================================
    // DMA FIFO WRITE INTERFACE
    // ============================================================
    output logic [DATA_WIDTH-1:0] fifo_write_data, // data word being apssed from the AXI read channel into the DMA FIFO
    output logic                  fifo_write_valid, // 1 if fifo_write_data contains a valid word
    input  logic                  fifo_write_ready // 1 if DMA FIFO has space to accept the word
);

    // ============================================================
    // DERIVED PARAMETERS
    // ============================================================
    localparam int BYTES_PER_BEAT = DATA_WIDTH / 8; // number of bytes carried by one AXI data transfer
    localparam int AXI_SIZE       = $clog2(BYTES_PER_BEAT);

    localparam int BURST_COUNT_WIDTH =
        (MAX_BURST_LEN <= 1) ? 1 : $clog2(MAX_BURST_LEN + 1); // number of bits needed to store a burst size between 0 and MAX_BURST_LEN

    // ============================================================
    // STATE MACHINE
    // ============================================================
    typedef enum logic [1:0] {
        IDLE,
        PREPARE_AR,
        SEND_AR,
        RECEIVE_R
    } state_t;

    state_t state;

    // ============================================================
    // COMMAND AND TRANSFER REGISTERS
    // ============================================================

    // Address used for the next AXI burst.
    logic [ADDR_WIDTH-1:0] current_addr;

    // Total number of bytes from the complete DMA command that have not yet been assigned to an AXI burst
    logic [LENGTH_WIDTH-1:0] bytes_remaining;

    // Number of beats in the current burst.
    logic [BURST_COUNT_WIDTH-1:0] burst_beats;

    // Number of data beats received in the current burst.
    logic [BURST_COUNT_WIDTH-1:0] beat_count;

    // ============================================================
    // BURST CALCULATION SIGNALS
    // ============================================================

    // Number of beats remaining in the complete DMA command.
    // Same thing as bytes_remaining / BYTES_PER_BEAT
    logic [LENGTH_WIDTH-1:0] beats_remaining;

    // Number of beats possible before reaching a 4 KB boundary.
    // AXI bursts are not allowed to cross a 4KB address boundary
    logic [LENGTH_WIDTH-1:0] beats_to_4k_boundary;

    // Number of beats selected for the next burst.
    logic [BURST_COUNT_WIDTH-1:0] next_burst_beats;

    // ============================================================
    // HANDSHAKE SIGNALS
    // ============================================================
    logic cmd_fire;
    logic ar_fire;
    logic r_fire;

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
        // Default assignments
        cmd_ready        = 1'b0;

        m_axi_araddr     = current_addr;
        m_axi_arlen      = burst_beats - 1'b1;
        m_axi_arsize     = AXI_SIZE;
        m_axi_arburst    = 2'b01;  // INCR burst
        m_axi_arvalid    = 1'b0;

        fifo_write_data  = m_axi_rdata;
        fifo_write_valid = 1'b0;
        m_axi_rready     = 1'b0;

        busy             = 1'b0;

        cmd_fire         = 1'b0;
        ar_fire          = 1'b0;
        r_fire           = 1'b0;

        case (state)
            IDLE: begin
                cmd_ready = 1'b1;
                busy = 1'b0;
                cmd_fire = cmd_valid && cmd_ready;
            end

            PREPARE_AR: begin
                busy = 1'b1;
            end

            SEND_AR: begin
                busy = 1'b1;
                m_axi_arvalid = 1'b1;
                ar_fire = m_axi_arvalid && m_axi_arready;
            end

            // Connect the AXI R channel to the FIFO
            RECEIVE_R: begin
                busy = 1'b1;
                fifo_write_data = m_axi_rdata;
                fifo_write_valid = m_axi_rvalid;
                m_axi_rready = fifo_write_ready;
                r_fire = m_axi_rvalid && m_axi_rready;
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
            // done should normally be a one-cycle pulse.
            done <= 1'b0;



            // Accept a new DMA read command
            // A new command is accepted only when both cmd_valid and cmd_ready are high on a rising clock edge
            if (cmd_fire) begin
                // Design only supports full-width beats
                // Source address must be aligned to BYTES_PER_BEAT
                // For a 32-bit bus, both values must be divisible by 4, meaning their lowest two bits must be 0
                if (cmd_source_addr % BYTES_PER_BEAT != 0 || cmd_length_bytes % BYTES_PER_BEAT != 0) begin
                    error <= 1'b1;
                    done <= 1'b1;
                    state <= IDLE;
                end
                else begin
                    current_addr <= cmd_source_addr;
                    bytes_remaining <= cmd_length_bytes;
                    error <= 1'b0; // clear any previous error
                    burst_beats <= '0;
                    beat_count <= '0;
                    state <= PREPARE_AR;
                end
            end

            if (state==PREPARE_AR) begin
                // if the next calculated burst beat contains 0 beats
                if (next_burst_beats == '0) begin
                    done <= 1'b1;
                    state <= IDLE;
                end
                else begin
                    burst_beats <= next_burst_beats;
                    beat_count <= '0; // reset beat count
                    state <= SEND_AR;
                end
            end

            // AXI slave has accepted the burst request
            if (ar_fire) begin
                beat_count <= '0;
                state <= RECEIVE_R;
            end

            // Increment beat count
            if (r_fire) begin
                // If response was not okay (10 and 11 are errors), set error
                if (m_axi_rresp[1]) begin
                    error <= 1'b1;
                end
                beat_count <= beat_count + 1'b1;

                if (beat_count == burst_beats - 1) begin
                    current_addr <= current_addr + burst_beats * BYTES_PER_BEAT;
                    
                    // current burst consumed all remaining bytes
                    if (bytes_remaining == burst_beats * BYTES_PER_BEAT) begin
                        done <= 1'b1;
                        state <= IDLE;
                        bytes_remaining <= '0;
                    end
                    // need to issue another burst
                    else begin
                        bytes_remaining <= bytes_remaining - burst_beats * BYTES_PER_BEAT;
                        state <= PREPARE_AR;
                    end

                    // If rlast isn't asserted on the last beat
                    if (!m_axi_rlast) error <= 1'b1;
                end
                // If rlast is asserted too early
                else if (m_axi_rlast) error <= 1'b1;
            end

        end
    end

endmodule