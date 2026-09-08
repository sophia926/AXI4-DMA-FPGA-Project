module axi_dma_top_level #(
    parameter int ADDR_WIDTH    = 32,
    parameter int DATA_WIDTH    = 32,
    parameter int LENGTH_WIDTH  = 32,
    parameter int FIFO_DEPTH    = 16,
    parameter int MAX_BURST_LEN = 16
) (
    input  logic clk,
    input  logic rst_n,

    // ============================================================
    // DMA COMMAND INTERFACE
    // ============================================================
    input  logic [ADDR_WIDTH-1:0]   source_addr,
    input  logic [ADDR_WIDTH-1:0]   dest_addr,
    input  logic [LENGTH_WIDTH-1:0] length_bytes,
    input  logic                    start,
    output logic                    ready,

    // ============================================================
    // DMA STATUS
    // ============================================================
    output logic busy,
    output logic done,
    output logic error,

    // ============================================================
    // AXI4 READ ADDRESS CHANNEL
    // ============================================================
    output logic [ADDR_WIDTH-1:0] m_axi_araddr,
    output logic [7:0]            m_axi_arlen,
    output logic [2:0]            m_axi_arsize,
    output logic [1:0]            m_axi_arburst,
    output logic                  m_axi_arvalid,
    input  logic                  m_axi_arready,

    // ============================================================
    // AXI4 READ DATA CHANNEL
    // ============================================================
    input  logic [DATA_WIDTH-1:0] m_axi_rdata,
    input  logic [1:0]            m_axi_rresp,
    input  logic                  m_axi_rlast,
    input  logic                  m_axi_rvalid,
    output logic                  m_axi_rready,

    // ============================================================
    // AXI4 WRITE ADDRESS CHANNEL
    // ============================================================
    output logic [ADDR_WIDTH-1:0] m_axi_awaddr,
    output logic [7:0]            m_axi_awlen,
    output logic [2:0]            m_axi_awsize,
    output logic [1:0]            m_axi_awburst,
    output logic                  m_axi_awvalid,
    input  logic                  m_axi_awready,

    // ============================================================
    // AXI4 WRITE DATA CHANNEL
    // ============================================================
    output logic [DATA_WIDTH-1:0]   m_axi_wdata,
    output logic [DATA_WIDTH/8-1:0] m_axi_wstrb,
    output logic                    m_axi_wlast,
    output logic                    m_axi_wvalid,
    input  logic                    m_axi_wready,

    // ============================================================
    // AXI4 WRITE RESPONSE CHANNEL
    // ============================================================
    input  logic [1:0] m_axi_bresp,
    input  logic       m_axi_bvalid,
    output logic       m_axi_bready
);

    // ============================================================
    // TOP-LEVEL COMMAND STATE
    // ============================================================
    typedef enum logic [1:0] {
        IDLE,
        ISSUE_COMMANDS,
        RUN_TRANSFER
    } state_t;

    state_t state;

    logic [ADDR_WIDTH-1:0]   source_addr_reg;
    logic [ADDR_WIDTH-1:0]   dest_addr_reg;
    logic [LENGTH_WIDTH-1:0] length_bytes_reg;

    // Each pending bit remains asserted until its corresponding
    // submodule accepts the command.
    logic read_cmd_pending;
    logic write_cmd_pending;

    // Completion pulses may arrive on different cycles, so remember them.
    logic read_done_seen;
    logic write_done_seen;

    // ============================================================
    // READ-MASTER STATUS AND COMMAND WIRES
    // ============================================================
    logic read_cmd_ready;
    // logic read_busy;
    logic read_done;
    logic read_error;

    // ============================================================
    // WRITE-MASTER STATUS AND COMMAND WIRES
    // ============================================================
    logic write_cmd_ready;
    // logic write_busy;
    logic write_done;
    logic write_error;

    // ============================================================
    // FIFO WIRES
    // ============================================================
    logic [DATA_WIDTH-1:0] fifo_write_data;
    logic                  fifo_write_valid;
    logic                  fifo_write_ready;

    logic [DATA_WIDTH-1:0] fifo_read_data;
    logic                  fifo_read_valid;
    logic                  fifo_read_ready;

    // logic fifo_full;
    // logic fifo_empty;
    logic [$clog2(FIFO_DEPTH+1)-1:0] fifo_count;

    // ============================================================
    // TOP-LEVEL CONTROL OUTPUTS
    // ============================================================
    always_comb begin
        ready = 1'b0;
        busy  = 1'b0;

        case (state)
            IDLE: begin
                // Advertise that a new DMA command can be accepted
                ready = 1'b1;
                busy = 1'b0;
            end

            ISSUE_COMMANDS: begin
                // Keep the DMA busy while each submodule accepts its copy of the command
                busy = 1'b1;
                ready = 1'b0;
                
            end

            RUN_TRANSFER: begin
                // Keep the DMA busy until both engines finish.
                busy = 1'b1;
                ready = 1'b0;
            end

            default: begin
                // Keep safe defaults.
            end
        endcase
    end

    // ============================================================
    // TOP-LEVEL COMMAND AND COMPLETION CONTROL
    // ============================================================
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state             <= IDLE;
            source_addr_reg   <= '0;
            dest_addr_reg     <= '0;
            length_bytes_reg  <= '0;
            read_cmd_pending  <= 1'b0;
            write_cmd_pending <= 1'b0;
            read_done_seen    <= 1'b0;
            write_done_seen   <= 1'b0;
            done              <= 1'b0;
            error             <= 1'b0;
        end
        else begin
            // done should be asserted for only one clock cycle.
            done <= 1'b0;

            if (start && ready) begin
                source_addr_reg <= source_addr;
                dest_addr_reg <= dest_addr;
                length_bytes_reg <= length_bytes;
                read_cmd_pending <= 1'b1;
                write_cmd_pending <= 1'b1;
                state <= ISSUE_COMMANDS;
                read_done_seen <= 1'b0;
                write_done_seen <= 1'b0;
                error <= 1'b0;
            end

            else if (state==ISSUE_COMMANDS) begin
                if (read_cmd_pending && read_cmd_ready) read_cmd_pending <= 1'b0;
                if (write_cmd_pending && write_cmd_ready) write_cmd_pending <= 1'b0;

                if ((!read_cmd_pending || read_cmd_ready) && (!write_cmd_pending || write_cmd_ready)) begin
                    state <= RUN_TRANSFER;
                end
            end


            else if (state==RUN_TRANSFER) begin
                if ((read_done || read_done_seen) && (write_done || write_done_seen)) begin
                    done <= 1'b1;
                    state <= IDLE;
                end

                if (read_error || write_error) begin
                    error <= 1'b1;
                end
            end

            // A master can accept and complete a short command while the top level is still in ISSUE_COMMANDS waiting for the other master
            if (read_done) read_done_seen <= 1'b1;
            if (write_done) write_done_seen <= 1'b1;


        end
    end

    // ============================================================
    // AXI READ MASTER
    // ============================================================
    axi_read_master #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .DATA_WIDTH(DATA_WIDTH),
        .LENGTH_WIDTH(LENGTH_WIDTH),
        .MAX_BURST_LEN(MAX_BURST_LEN)
    ) read_master (
        .clk(clk),
        .rst_n(rst_n),
        .cmd_source_addr(source_addr_reg),
        .cmd_length_bytes(length_bytes_reg),
        .cmd_valid(read_cmd_pending),
        .cmd_ready(read_cmd_ready),
        .busy(),
        .done(read_done),
        .error(read_error),
        .m_axi_araddr(m_axi_araddr),
        .m_axi_arlen(m_axi_arlen),
        .m_axi_arsize(m_axi_arsize),
        .m_axi_arburst(m_axi_arburst),
        .m_axi_arvalid(m_axi_arvalid),
        .m_axi_arready(m_axi_arready),
        .m_axi_rdata(m_axi_rdata),
        .m_axi_rresp(m_axi_rresp),
        .m_axi_rlast(m_axi_rlast),
        .m_axi_rvalid(m_axi_rvalid),
        .m_axi_rready(m_axi_rready),
        .fifo_write_data(fifo_write_data),
        .fifo_write_valid(fifo_write_valid),
        .fifo_write_ready(fifo_write_ready)
    );
    
    // ============================================================
    // DATA FIFO
    // ============================================================
    dma_fifo #(
        .DATA_WIDTH(DATA_WIDTH),
        .FIFO_DEPTH(FIFO_DEPTH)
    ) dma_fifo (
        .clk(clk),
        .rst_n(rst_n),
        .write_data(fifo_write_data),
        .write_valid(fifo_write_valid),
        .write_ready(fifo_write_ready),
        .read_data(fifo_read_data),
        .read_valid(fifo_read_valid),
        .read_ready(fifo_read_ready),
        .full(),
        .empty(),
        .count(fifo_count)
    );

    // ============================================================
    // AXI WRITE MASTER
    // ============================================================
    axi_write_master #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .DATA_WIDTH(DATA_WIDTH),
        .LENGTH_WIDTH(LENGTH_WIDTH),
        .FIFO_DEPTH(FIFO_DEPTH),
        .MAX_BURST_LEN(MAX_BURST_LEN)
    ) write_master (
        .clk(clk),
        .rst_n(rst_n),
        .cmd_dest_addr(dest_addr_reg),
        .cmd_length_bytes(length_bytes_reg),
        .cmd_valid(write_cmd_pending),
        .cmd_ready(write_cmd_ready),
        .busy(),
        .done(write_done),
        .error(write_error),
        .m_axi_awaddr(m_axi_awaddr),
        .m_axi_awlen(m_axi_awlen),
        .m_axi_awsize(m_axi_awsize),
        .m_axi_awburst(m_axi_awburst),
        .m_axi_awvalid(m_axi_awvalid),
        .m_axi_awready(m_axi_awready),
        .m_axi_wdata(m_axi_wdata),
        .m_axi_wstrb(m_axi_wstrb),
        .m_axi_wlast(m_axi_wlast),
        .m_axi_wvalid(m_axi_wvalid),
        .m_axi_wready(m_axi_wready),
        .m_axi_bresp(m_axi_bresp),
        .m_axi_bvalid(m_axi_bvalid),
        .m_axi_bready(m_axi_bready),
        .fifo_read_data(fifo_read_data),
        .fifo_read_valid(fifo_read_valid),
        .fifo_read_ready(fifo_read_ready),
        .fifo_count(fifo_count)
    );

endmodule
