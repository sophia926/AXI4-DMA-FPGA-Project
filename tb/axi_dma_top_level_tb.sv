`timescale 1ns/1ps

module axi_dma_top_level_tb;

    localparam int ADDR_WIDTH    = 32;
    localparam int DATA_WIDTH    = 32;
    localparam int LENGTH_WIDTH  = 32;
    localparam int FIFO_DEPTH    = 16;
    localparam int MAX_BURST_LEN = 16;
    localparam int MEM_WORDS     = 4096;
    localparam int BYTE_SHIFT    = $clog2(DATA_WIDTH / 8);

    logic clk;
    logic rst_n;

    logic [ADDR_WIDTH-1:0]   source_addr;
    logic [ADDR_WIDTH-1:0]   dest_addr;
    logic [LENGTH_WIDTH-1:0] length_bytes;
    logic                    start;
    logic                    ready;
    logic                    busy;
    logic                    done;
    logic                    error;

    logic [ADDR_WIDTH-1:0] m_axi_araddr;
    logic [7:0]            m_axi_arlen;
    logic [2:0]            m_axi_arsize;
    logic [1:0]            m_axi_arburst;
    logic                  m_axi_arvalid;
    logic                  m_axi_arready;

    logic [DATA_WIDTH-1:0] m_axi_rdata;
    logic [1:0]            m_axi_rresp;
    logic                  m_axi_rlast;
    logic                  m_axi_rvalid;
    logic                  m_axi_rready;

    logic [ADDR_WIDTH-1:0] m_axi_awaddr;
    logic [7:0]            m_axi_awlen;
    logic [2:0]            m_axi_awsize;
    logic [1:0]            m_axi_awburst;
    logic                  m_axi_awvalid;
    logic                  m_axi_awready;

    logic [DATA_WIDTH-1:0]   m_axi_wdata;
    logic [DATA_WIDTH/8-1:0] m_axi_wstrb;
    logic                    m_axi_wlast;
    logic                    m_axi_wvalid;
    logic                    m_axi_wready;

    logic [1:0] m_axi_bresp;
    logic       m_axi_bvalid;
    logic       m_axi_bready;

    // Burst-capable AXI memory model state.
    logic [DATA_WIDTH-1:0] memory [0:MEM_WORDS-1];

    logic                  read_active;
    logic [ADDR_WIDTH-1:0] read_addr_reg;
    logic [2:0]            read_size_reg;
    logic [8:0]            read_beats_left;

    logic                  write_active;
    logic [ADDR_WIDTH-1:0] write_addr_reg;
    logic [2:0]            write_size_reg;
    logic [8:0]            write_beats_left;
    logic                  bvalid_reg;
    logic [1:0]            bresp_reg;

    logic [7:0] cycle_count;
    logic       enable_ready_stalls;

    integer i;
    integer byte_lane;

    axi_dma_top_level #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .DATA_WIDTH(DATA_WIDTH),
        .LENGTH_WIDTH(LENGTH_WIDTH),
        .FIFO_DEPTH(FIFO_DEPTH),
        .MAX_BURST_LEN(MAX_BURST_LEN)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .source_addr(source_addr),
        .dest_addr(dest_addr),
        .length_bytes(length_bytes),
        .start(start),
        .ready(ready),
        .busy(busy),
        .done(done),
        .error(error),
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
        .m_axi_bready(m_axi_bready)
    );

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    // The memory model can delay acceptance of addresses and write data.
    // Once RVALID or BVALID is asserted, it remains asserted until handshake.
    always_comb begin
        m_axi_arready = !read_active &&
                        (!enable_ready_stalls || cycle_count[1:0] != 2'b00);

        m_axi_rvalid = read_active;
        m_axi_rdata  = memory[read_addr_reg >> BYTE_SHIFT];
        m_axi_rresp  = 2'b00;
        m_axi_rlast  = read_active && (read_beats_left == 1);

        m_axi_awready = !write_active && !bvalid_reg &&
                        (!enable_ready_stalls || cycle_count[2:0] != 3'b000);

        m_axi_wready = write_active &&
                       (!enable_ready_stalls || cycle_count[1:0] != 2'b00);

        m_axi_bvalid = bvalid_reg;
        m_axi_bresp  = bresp_reg;
    end

    // Burst-capable AXI memory model.
    // Use a normal clocked testbench process instead of always_ff because
    // the test sequence also initializes and preloads the memory array.
    always @(posedge clk) begin
        if (!rst_n) begin
            read_active      <= 1'b0;
            read_addr_reg    <= '0;
            read_size_reg    <= '0;
            read_beats_left  <= '0;
            write_active     <= 1'b0;
            write_addr_reg   <= '0;
            write_size_reg   <= '0;
            write_beats_left <= '0;
            bvalid_reg       <= 1'b0;
            bresp_reg        <= 2'b00;
            cycle_count      <= '0;
        end
        else begin
            cycle_count <= cycle_count + 1'b1;

            if (m_axi_arvalid && m_axi_arready) begin
                assert (m_axi_arburst == 2'b01)
                    else $fatal(1, "Memory model only supports INCR reads");
                assert (m_axi_arsize == BYTE_SHIFT)
                    else $fatal(1, "Unexpected ARSIZE: %0d", m_axi_arsize);

                read_active     <= 1'b1;
                read_addr_reg   <= m_axi_araddr;
                read_size_reg   <= m_axi_arsize;
                read_beats_left <= {1'b0, m_axi_arlen} + 9'd1;
            end

            if (m_axi_rvalid && m_axi_rready) begin
                if (read_beats_left == 1) begin
                    read_active     <= 1'b0;
                    read_beats_left <= '0;
                end
                else begin
                    read_addr_reg   <= read_addr_reg + (1 << read_size_reg);
                    read_beats_left <= read_beats_left - 1'b1;
                end
            end

            if (m_axi_awvalid && m_axi_awready) begin
                assert (m_axi_awburst == 2'b01)
                    else $fatal(1, "Memory model only supports INCR writes");
                assert (m_axi_awsize == BYTE_SHIFT)
                    else $fatal(1, "Unexpected AWSIZE: %0d", m_axi_awsize);

                write_active     <= 1'b1;
                write_addr_reg   <= m_axi_awaddr;
                write_size_reg   <= m_axi_awsize;
                write_beats_left <= {1'b0, m_axi_awlen} + 9'd1;
            end

            if (m_axi_wvalid && m_axi_wready) begin
                assert (m_axi_wlast == (write_beats_left == 1))
                    else $fatal(1,
                        "WLAST mismatch: beats_left=%0d WLAST=%b",
                        write_beats_left, m_axi_wlast);

                for (byte_lane = 0;
                     byte_lane < DATA_WIDTH/8;
                     byte_lane = byte_lane + 1) begin
                    if (m_axi_wstrb[byte_lane]) begin
                        memory[write_addr_reg >> BYTE_SHIFT]
                              [byte_lane*8 +: 8] <=
                            m_axi_wdata[byte_lane*8 +: 8];
                    end
                end

                if (write_beats_left == 1) begin
                    write_active     <= 1'b0;
                    write_beats_left <= '0;
                    bvalid_reg       <= 1'b1;
                    bresp_reg        <= 2'b00;
                end
                else begin
                    write_addr_reg   <= write_addr_reg +
                                        (1 << write_size_reg);
                    write_beats_left <= write_beats_left - 1'b1;
                end
            end

            if (m_axi_bvalid && m_axi_bready) begin
                bvalid_reg <= 1'b0;
                bresp_reg  <= 2'b00;
            end
        end
    end

    task automatic initialize_regions(
        input logic [ADDR_WIDTH-1:0] source_base,
        input logic [ADDR_WIDTH-1:0] destination_base,
        input integer                word_count,
        input logic [DATA_WIDTH-1:0] pattern_base
    );
        integer word_index;
        begin
            for (word_index = 0;
                 word_index < word_count;
                 word_index = word_index + 1) begin
                memory[(source_base >> BYTE_SHIFT) + word_index] =
                    pattern_base + word_index;
                memory[(destination_base >> BYTE_SHIFT) + word_index] =
                    '0;
            end
        end
    endtask

    task automatic issue_and_wait(
        input logic [ADDR_WIDTH-1:0]   command_source,
        input logic [ADDR_WIDTH-1:0]   command_destination,
        input logic [LENGTH_WIDTH-1:0] command_length
    );
        integer timeout_cycles;
        begin
            wait (ready === 1'b1);
            @(negedge clk);
            source_addr = command_source;
            dest_addr   = command_destination;
            length_bytes = command_length;
            start       = 1'b1;
            #1;

            assert (ready)
                else $fatal(1, "DMA was not ready to accept command");

            @(posedge clk);
            #1;
            start = 1'b0;

            timeout_cycles = 0;
            while (!done && timeout_cycles < 5000) begin
                @(posedge clk);
                #1;
                timeout_cycles = timeout_cycles + 1;
            end

            assert (done)
                else $fatal(1, "DMA timed out after %0d cycles",
                            timeout_cycles);
            assert (!busy)
                else $fatal(1, "DMA remained busy when done asserted");
            assert (ready)
                else $fatal(1, "DMA was not ready after completion");
            assert (!error)
                else $fatal(1, "DMA reported an unexpected error");

            @(posedge clk);
            #1;
            assert (!done)
                else $fatal(1, "DMA done was not a one-cycle pulse");
        end
    endtask

    task automatic check_copy(
        input logic [ADDR_WIDTH-1:0] source_base,
        input logic [ADDR_WIDTH-1:0] destination_base,
        input integer                word_count
    );
        integer word_index;
        begin
            for (word_index = 0;
                 word_index < word_count;
                 word_index = word_index + 1) begin
                assert (memory[(destination_base >> BYTE_SHIFT) + word_index]
                        === memory[(source_base >> BYTE_SHIFT) + word_index])
                    else $fatal(1,
                        "Copy mismatch at word %0d: expected %h, got %h",
                        word_index,
                        memory[(source_base >> BYTE_SHIFT) + word_index],
                        memory[(destination_base >> BYTE_SHIFT) + word_index]);
            end
        end
    endtask

    initial begin
        rst_n               = 1'b0;
        source_addr         = '0;
        dest_addr           = '0;
        length_bytes        = '0;
        start               = 1'b0;
        enable_ready_stalls = 1'b0;

        for (i = 0; i < MEM_WORDS; i = i + 1)
            memory[i] = '0;

        // ========================================================
        // TEST 1: RESET
        // ========================================================
        repeat (2) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;
        #1;

        assert (ready)  else $fatal(1, "Reset: ready is low");
        assert (!busy)  else $fatal(1, "Reset: busy is high");
        assert (!done)  else $fatal(1, "Reset: done is high");
        assert (!error) else $fatal(1, "Reset: error is high");
        $display("Test 1 passed: reset");

        // ========================================================
        // TEST 2: SINGLE-WORD COPY
        // ========================================================
        initialize_regions(32'h00000100, 32'h00000400,
                           1, 32'hA1000000);
        issue_and_wait(32'h00000100, 32'h00000400, 32'd4);
        check_copy(32'h00000100, 32'h00000400, 1);
        $display("Test 2 passed: single-word copy");

        // ========================================================
        // TEST 3: ONE FOUR-BEAT BURST
        // ========================================================
        initialize_regions(32'h00000200, 32'h00000500,
                           4, 32'hB2000000);
        issue_and_wait(32'h00000200, 32'h00000500, 32'd16);
        check_copy(32'h00000200, 32'h00000500, 4);
        $display("Test 3 passed: four-beat burst copy");

        // ========================================================
        // TEST 4: MULTIPLE BURSTS
        // 80 bytes = 20 beats = 16 beats plus 4 beats.
        // ========================================================
        initialize_regions(32'h00000800, 32'h00000C00,
                           20, 32'hC3000000);
        issue_and_wait(32'h00000800, 32'h00000C00, 32'd80);
        check_copy(32'h00000800, 32'h00000C00, 20);
        $display("Test 4 passed: multiple-burst copy");

        // ========================================================
        // TEST 5: READ AND WRITE 4 KB BOUNDARY SPLITTING
        // Both addresses have four beats remaining before a boundary.
        // ========================================================
        initialize_regions(32'h00000FF0, 32'h00001FF0,
                           8, 32'hD4000000);
        issue_and_wait(32'h00000FF0, 32'h00001FF0, 32'd32);
        check_copy(32'h00000FF0, 32'h00001FF0, 8);
        $display("Test 5 passed: 4 KB boundary split");

        // ========================================================
        // TEST 6: TRANSFER WITH AXI READY BACKPRESSURE
        // ========================================================
        enable_ready_stalls = 1'b1;
        initialize_regions(32'h00002200, 32'h00002600,
                           32, 32'hE5000000);
        issue_and_wait(32'h00002200, 32'h00002600, 32'd128);
        check_copy(32'h00002200, 32'h00002600, 32);
        enable_ready_stalls = 1'b0;
        $display("Test 6 passed: transfer under AXI backpressure");

        // ========================================================
        // TEST 7: ZERO-LENGTH COMMAND
        // ========================================================
        issue_and_wait(32'h00003000, 32'h00003400, 32'd0);
        $display("Test 7 passed: zero-length command");

        $display("All AXI DMA integration tests passed");
        $stop;
    end

endmodule
