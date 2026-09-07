`timescale 1ns/1ps

module axi_write_master_tb;

    localparam int ADDR_WIDTH    = 32;
    localparam int DATA_WIDTH    = 32;
    localparam int LENGTH_WIDTH  = 32;
    localparam int FIFO_DEPTH    = 16;
    localparam int MAX_BURST_LEN = 16;

    logic clk;
    logic rst_n;

    logic [ADDR_WIDTH-1:0]   cmd_dest_addr;
    logic [LENGTH_WIDTH-1:0] cmd_length_bytes;
    logic                    cmd_valid;
    logic                    cmd_ready;

    logic busy;
    logic done;
    logic error;

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

    logic [DATA_WIDTH-1:0] fifo_write_data;
    logic                  fifo_write_valid;
    logic                  fifo_write_ready;
    logic [DATA_WIDTH-1:0] fifo_read_data;
    logic                  fifo_read_valid;
    logic                  fifo_read_ready;
    logic                  fifo_full;
    logic                  fifo_empty;
    logic [$clog2(FIFO_DEPTH+1)-1:0] fifo_count;

    integer i;

    axi_write_master #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .DATA_WIDTH(DATA_WIDTH),
        .LENGTH_WIDTH(LENGTH_WIDTH),
        .FIFO_DEPTH(FIFO_DEPTH),
        .MAX_BURST_LEN(MAX_BURST_LEN)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .cmd_dest_addr(cmd_dest_addr),
        .cmd_length_bytes(cmd_length_bytes),
        .cmd_valid(cmd_valid),
        .cmd_ready(cmd_ready),
        .busy(busy),
        .done(done),
        .error(error),
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

    dma_fifo #(
        .DATA_WIDTH(DATA_WIDTH),
        .FIFO_DEPTH(FIFO_DEPTH)
    ) fifo (
        .clk(clk),
        .rst_n(rst_n),
        .write_data(fifo_write_data),
        .write_valid(fifo_write_valid),
        .write_ready(fifo_write_ready),
        .read_data(fifo_read_data),
        .read_valid(fifo_read_valid),
        .read_ready(fifo_read_ready),
        .full(fifo_full),
        .empty(fifo_empty),
        .count(fifo_count)
    );

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    task automatic push_fifo(input logic [DATA_WIDTH-1:0] data);
        @(negedge clk);
        fifo_write_data  = data;
        fifo_write_valid = 1'b1;
        #1;

        assert (fifo_write_ready)
            else $fatal(1, "FIFO preload failed: FIFO is not ready");

        @(posedge clk);
        #1;
        fifo_write_valid = 1'b0;
    endtask

    // Sends a destination address and byte length to the write master
    task automatic start_command(
        input logic [ADDR_WIDTH-1:0]   address,
        input logic [LENGTH_WIDTH-1:0] length
    );
        @(negedge clk);
        cmd_dest_addr   = address;
        cmd_length_bytes = length;
        cmd_valid       = 1'b1;
        #1;

        assert (cmd_ready)
            else $fatal(1, "Command failed: write master is not ready");

        @(posedge clk);
        #1;
        cmd_valid = 1'b0;
    endtask

    // Checks burst address information, introduces address backpressure, and then accepts the request
    task automatic accept_aw(
        input logic [ADDR_WIDTH-1:0] expected_addr,
        input logic [7:0]            expected_len
    );
        wait (m_axi_awvalid === 1'b1);
        @(negedge clk);
        #1;

        assert (m_axi_awaddr == expected_addr)
            else $fatal(1, "Expected AWADDR %h, got %h",
                        expected_addr, m_axi_awaddr);

        assert (m_axi_awlen == expected_len)
            else $fatal(1, "Expected AWLEN %0d, got %0d",
                        expected_len, m_axi_awlen);

        assert (m_axi_awsize == 3'd2)
            else $fatal(1, "Expected AWSIZE 2, got %0d", m_axi_awsize);

        assert (m_axi_awburst == 2'b01)
            else $fatal(1, "Expected incrementing AWBURST, got %b",
                        m_axi_awburst);

        // Hold AWREADY low for one additional cycle to verify that the
        // request remains valid and stable under address backpressure.
        @(posedge clk);
        #1;

        assert (m_axi_awvalid)
            else $fatal(1, "AWVALID dropped before the address handshake");

        assert (m_axi_awaddr == expected_addr && m_axi_awlen == expected_len)
            else $fatal(1, "AW request changed while stalled");

        @(negedge clk);
        m_axi_awready = 1'b1;
        #1;

        @(posedge clk);
        #1;
        m_axi_awready = 1'b0;

        assert (!m_axi_awvalid)
            else $fatal(1, "AWVALID remained high after handshake");
    endtask

    // Checks and accepts one AXI write-data beat
    task automatic accept_w(
        input logic [DATA_WIDTH-1:0] expected_data,
        input logic                  expected_last
    );
        wait (m_axi_wvalid === 1'b1);
        @(negedge clk);
        #1;

        assert (m_axi_wdata == expected_data)
            else $fatal(1, "Expected WDATA %h, got %h",
                        expected_data, m_axi_wdata);

        assert (m_axi_wlast == expected_last)
            else $fatal(1, "Expected WLAST %b, got %b",
                        expected_last, m_axi_wlast);

        assert (m_axi_wstrb == {DATA_WIDTH/8{1'b1}})
            else $fatal(1, "WSTRB is not all ones: %b", m_axi_wstrb);

        m_axi_wready = 1'b1;
        #1;

        @(posedge clk);
        #1;
        m_axi_wready = 1'b0;
    endtask

    // Returns a write response after a burst finishes
    task automatic send_bresp(input logic [1:0] response);
        wait (m_axi_bready === 1'b1);
        @(negedge clk);
        m_axi_bresp  = response;
        m_axi_bvalid = 1'b1;
        #1;

        assert (m_axi_bready)
            else $fatal(1, "Write master is not ready for BRESP");

        @(posedge clk);
        #1;
        m_axi_bvalid = 1'b0;
        m_axi_bresp  = 2'b00;
    endtask

    initial begin
        rst_n            = 1'b0;
        cmd_dest_addr    = '0;
        cmd_length_bytes = '0;
        cmd_valid        = 1'b0;
        m_axi_awready    = 1'b0;
        m_axi_wready     = 1'b0;
        m_axi_bresp      = 2'b00;
        m_axi_bvalid     = 1'b0;
        fifo_write_data  = '0;
        fifo_write_valid = 1'b0;

        // ========================================================
        // TEST 1: RESET
        // ========================================================
        repeat (2) @(posedge clk);

        @(negedge clk);
        rst_n = 1'b1;
        #1;

        assert (cmd_ready)         else $fatal(1, "Reset: cmd_ready low");
        assert (!busy)             else $fatal(1, "Reset: busy high");
        assert (!done)             else $fatal(1, "Reset: done high");
        assert (!error)            else $fatal(1, "Reset: error high");
        assert (!m_axi_awvalid)    else $fatal(1, "Reset: AWVALID high");
        assert (!m_axi_wvalid)     else $fatal(1, "Reset: WVALID high");
        assert (!m_axi_bready)     else $fatal(1, "Reset: BREADY high");
        assert (!fifo_read_ready)  else $fatal(1, "Reset: FIFO read-ready high");
        assert (fifo_empty)        else $fatal(1, "Reset: FIFO not empty");
        $display("Test 1 passed: reset");

        // ========================================================
        // TEST 2: ONE FOUR-BEAT BURST WITH BACKPRESSURE
        // ========================================================
        push_fifo(32'h11111111);
        push_fifo(32'h22222222);
        push_fifo(32'h33333333);
        push_fifo(32'h44444444);

        assert (fifo_count == 4)
            else $fatal(1, "Single burst: expected FIFO count 4, got %0d",
                        fifo_count);

        start_command(32'h00001000, 32'd16);
        accept_aw(32'h00001000, 8'd3);

        // Stall the first data beat and verify that it remains stable.
        wait (m_axi_wvalid === 1'b1);
        @(negedge clk);
        #1;
        assert (m_axi_wdata == 32'h11111111)
            else $fatal(1, "W backpressure: incorrect first word");
        assert (!m_axi_wlast)
            else $fatal(1, "W backpressure: WLAST asserted on first word");
        assert (fifo_count == 4)
            else $fatal(1, "W backpressure: FIFO changed before handshake");

        @(posedge clk);
        #1;
        assert (m_axi_wvalid && m_axi_wdata == 32'h11111111)
            else $fatal(1, "W backpressure: data did not remain stable");
        assert (fifo_count == 4)
            else $fatal(1, "W backpressure: FIFO word was removed while stalled");

        accept_w(32'h11111111, 1'b0);
        accept_w(32'h22222222, 1'b0);
        accept_w(32'h33333333, 1'b0);
        accept_w(32'h44444444, 1'b1);

        assert (fifo_empty)
            else $fatal(1, "Single burst: FIFO is not empty after four beats");
        assert (!done)
            else $fatal(1, "Single burst: done asserted before BRESP");

        send_bresp(2'b00);

        assert (done)      else $fatal(1, "Single burst: done is low");
        assert (!busy)     else $fatal(1, "Single burst: busy is high");
        assert (cmd_ready) else $fatal(1, "Single burst: cmd_ready is low");
        assert (!error)    else $fatal(1, "Single burst: error is high");
        $display("Test 2 passed: four-beat burst and backpressure");

        @(posedge clk);
        #1;
        assert (!done) else $fatal(1, "done is not a one-cycle pulse");

        // ========================================================
        // TEST 3: MULTIPLE BURSTS
        // 80 bytes = 20 beats = 16 beats followed by 4 beats.
        // ========================================================
        for (i = 0; i < 16; i = i + 1)
            push_fifo(32'h50000000 + i);

        start_command(32'h00002000, 32'd80);
        accept_aw(32'h00002000, 8'd15);

        for (i = 0; i < 16; i = i + 1)
            accept_w(32'h50000000 + i, i == 15);

        send_bresp(2'b00);

        assert (!done)
            else $fatal(1, "Multiple bursts: done asserted after first burst");

        for (i = 0; i < 4; i = i + 1)
            push_fifo(32'h60000000 + i);

        accept_aw(32'h00002040, 8'd3);

        for (i = 0; i < 4; i = i + 1)
            accept_w(32'h60000000 + i, i == 3);

        send_bresp(2'b00);

        assert (done)   else $fatal(1, "Multiple bursts: done is low");
        assert (!error) else $fatal(1, "Multiple bursts: error is high");
        $display("Test 3 passed: multiple bursts");

        // ========================================================
        // TEST 4: 4 KB BOUNDARY SPLITTING
        // 0x0FF0 leaves 16 bytes before 0x1000, so 32 bytes becomes
        // two four-beat bursts.
        // ========================================================
        for (i = 0; i < 8; i = i + 1)
            push_fifo(32'h70000000 + i);

        start_command(32'h00000FF0, 32'd32);
        accept_aw(32'h00000FF0, 8'd3);

        for (i = 0; i < 4; i = i + 1)
            accept_w(32'h70000000 + i, i == 3);

        send_bresp(2'b00);

        assert (!done)
            else $fatal(1, "4 KB boundary: done asserted after first burst");

        accept_aw(32'h00001000, 8'd3);

        for (i = 4; i < 8; i = i + 1)
            accept_w(32'h70000000 + i, i == 7);

        send_bresp(2'b00);

        assert (done)   else $fatal(1, "4 KB boundary: done is low");
        assert (!error) else $fatal(1, "4 KB boundary: error is high");
        $display("Test 4 passed: 4 KB boundary splitting");

        // ========================================================
        // TEST 5: AXI WRITE ERROR RESPONSE
        // ========================================================
        push_fifo(32'hDEADBEEF);
        start_command(32'h00003000, 32'd4);
        accept_aw(32'h00003000, 8'd0);
        accept_w(32'hDEADBEEF, 1'b1);
        send_bresp(2'b10);

        assert (done)  else $fatal(1, "BRESP error: done is low");
        assert (error) else $fatal(1, "BRESP error: error is low");
        $display("Test 5 passed: BRESP error detection");

        // ========================================================
        // TEST 6: MISALIGNED COMMAND
        // ========================================================
        @(negedge clk);
        cmd_dest_addr    = 32'h00004001;
        cmd_length_bytes = 32'd4;
        cmd_valid        = 1'b1;
        #1;

        assert (cmd_ready)
            else $fatal(1, "Misaligned command: cmd_ready is low");

        @(posedge clk);
        #1;
        cmd_valid = 1'b0;

        assert (done)          else $fatal(1, "Misaligned command: done is low");
        assert (error)         else $fatal(1, "Misaligned command: error is low");
        assert (!busy)         else $fatal(1, "Misaligned command: busy is high");
        assert (!m_axi_awvalid)
            else $fatal(1, "Misaligned command issued an AXI request");
        $display("Test 6 passed: misaligned command rejection");

        // ========================================================
        // TEST 7: ZERO-LENGTH COMMAND
        // ========================================================
        @(negedge clk);
        cmd_dest_addr    = 32'h00005000;
        cmd_length_bytes = 32'd0;
        cmd_valid        = 1'b1;
        #1;

        assert (cmd_ready)
            else $fatal(1, "Zero-length command: cmd_ready is low");

        @(posedge clk);
        #1;
        cmd_valid = 1'b0;

        // Command is now in PREPARE_AW; the following edge detects zero beats.
        @(posedge clk);
        #1;

        assert (done)          else $fatal(1, "Zero-length command: done is low");
        assert (!error)        else $fatal(1, "Zero-length command: error is high");
        assert (!busy)         else $fatal(1, "Zero-length command: busy is high");
        assert (!m_axi_awvalid)
            else $fatal(1, "Zero-length command issued an AXI request");
        $display("Test 7 passed: zero-length command");

        $display("All axi_write_master directed tests passed");
        $stop;
    end

endmodule
