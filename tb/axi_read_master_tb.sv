// Directed testbench
`timescale 1ns/1ps

module axi_read_master_tb;

    // ============================================================
    // PARAMETERS
    // ============================================================
    localparam int ADDR_WIDTH    = 32;
    localparam int DATA_WIDTH    = 32;
    localparam int LENGTH_WIDTH  = 32;
    localparam int MAX_BURST_LEN = 16;

    // ============================================================
    // TESTBENCH SIGNALS
    // ============================================================
    logic clk;
    logic rst_n;

    logic [ADDR_WIDTH-1:0]   cmd_source_addr;
    logic [LENGTH_WIDTH-1:0] cmd_length_bytes;
    logic                    cmd_valid;
    logic                    cmd_ready;

    logic busy;
    logic done;
    logic error;

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

    logic [DATA_WIDTH-1:0] fifo_write_data;
    logic                  fifo_write_valid;
    logic                  fifo_write_ready;

    integer i;


    // ============================================================
    // DEVICE UNDER TEST
    // ============================================================
    axi_read_master #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .DATA_WIDTH(DATA_WIDTH),
        .LENGTH_WIDTH(LENGTH_WIDTH),
        .MAX_BURST_LEN(MAX_BURST_LEN)
    ) dut (
        .clk         (clk),
        .rst_n       (rst_n),

        .cmd_source_addr(cmd_source_addr),
        .cmd_length_bytes(cmd_length_bytes),
        .cmd_valid(cmd_valid),
        .cmd_ready(cmd_ready),

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

        .fifo_write_data(fifo_write_data),
        .fifo_write_valid(fifo_write_valid),
        .fifo_write_ready(fifo_write_ready)

    );


    task automatic accept_ar(
        input logic [ADDR_WIDTH-1:0] expected_addr,
        input logic [7:0]            expected_len
    );
        @(negedge clk);
        m_axi_arready = 1'b1;
        #1;

        assert (m_axi_arvalid)
            else $fatal(1, "AR handshake failed: ARVALID is low");

        assert (m_axi_araddr == expected_addr)
            else $fatal(1, "Expected ARADDR %h, got %h",
                        expected_addr, m_axi_araddr);

        assert (m_axi_arlen == expected_len)
            else $fatal(1, "Expected ARLEN %0d, got %0d",
                        expected_len, m_axi_arlen);

        @(posedge clk);
        #1;
        m_axi_arready = 1'b0;

        assert (!m_axi_arvalid)
            else $fatal(1, "ARVALID remained high after handshake");
    endtask


    task automatic send_read_beat(
        input logic [DATA_WIDTH-1:0] data,
        input logic                  last,
        input logic [1:0]            response
    );
        @(negedge clk);
        m_axi_rdata  = data;
        m_axi_rlast  = last;
        m_axi_rresp  = response;
        m_axi_rvalid = 1'b1;
        #1;

        assert (m_axi_rready)
            else $fatal(1, "Read master is not ready for data");

        assert (fifo_write_valid)
            else $fatal(1, "FIFO write-valid is not asserted");

        assert (fifo_write_data == data)
            else $fatal(1, "Expected FIFO data %h, got %h",
                        data, fifo_write_data);

        @(posedge clk);
        #1;

        m_axi_rvalid = 1'b0;
        m_axi_rlast  = 1'b0;
        m_axi_rresp  = 2'b00;
    endtask


    task automatic start_command(
        input logic [ADDR_WIDTH-1:0]   address,
        input logic [LENGTH_WIDTH-1:0] length
    );
        @(negedge clk);
        cmd_source_addr = address;
        cmd_length_bytes = length;
        cmd_valid = 1'b1;
        #1;

        assert (cmd_ready)
            else $fatal(1, "Read master did not accept command");

        @(posedge clk);
        #1;
        cmd_valid = 1'b0;

        // Allow PREPARE_AR to register the burst.
        @(posedge clk);
        #1;

        assert (m_axi_arvalid)
            else $fatal(1, "ARVALID not asserted after command");
    endtask

    // ============================================================
    // CLOCK GENERATION
    // ============================================================
    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    // ============================================================
    // TEST SEQUENCE
    // ============================================================
    initial begin
        // Initialize all testbench-driven signals.
        rst_n       = 1'b0;
        cmd_source_addr = '0;
        cmd_length_bytes = '0;
        cmd_valid = 1'b0;
        m_axi_arready = 1'b0;
        m_axi_rdata = '0;
        m_axi_rresp = 2'b00;
        m_axi_rlast = 1'b0;
        m_axi_rvalid = 1'b0;
        fifo_write_ready = 1'b1;
        

        
        // ============================================================
        // TEST 1: RESET
        // ============================================================
        repeat (2) @(posedge clk);

        // Release reset on falling edge
        @(negedge clk);
        rst_n = 1'b1;
        #1;

        // Verify the idle state after reset.
        assert (cmd_ready)
            else $fatal(1, "Reset test failed: cmd_ready is not asserted");

        assert (!busy)
            else $fatal(1, "Reset test failed: busy is asserted");

        assert (!done)
            else $fatal(1, "Reset test failed: done is asserted");

        assert (!error)
            else $fatal(1, "Reset test failed: error is asserted");

        assert (!m_axi_arvalid)
            else $fatal(1, "Reset test failed: m_axi_arvalid is asserted");

        assert (!m_axi_rready)
            else $fatal(1, "Reset test failed: m_axi_rready is asserted");

        assert (!fifo_write_valid)
            else $fatal(1, "Reset test failed: fifo_write_valid is asserted");

        $display("Reset test passed");

        // ============================================================
        // TEST 2: Command acceptance
        // ============================================================
        @(negedge clk);
        cmd_source_addr = 32'h00001000;
        cmd_length_bytes = 32'd16;
        cmd_valid = 1'b1;
        #1;

        assert (cmd_ready)
            else $fatal(1, "Command test failed: cmd_ready is not asserted");

        @(posedge clk);
        #1;
        cmd_valid = 1'b0;

        assert (busy)
            else $fatal(1, "Command test failed: busy is not asserted");

        assert (!cmd_ready)
            else $fatal(1, "Command test failed: cmd_ready is asserted");

        assert (!m_axi_arvalid)
            else $fatal(1, "Command test failed: m_axi_arvalid is asserted");

        assert (!done)
            else $fatal(1, "Command test failed: done is asserted");

        assert (!error)
            else $fatal(1, "Command test failed: error is asserted");

        // ============================================================
        // TEST 3: PREPARE AND PRESENT AXI READ ADDRESS
        // ============================================================

        // Prevent the AXI slave from accepting the address yet.
        m_axi_arready = 1'b0;

        // PREPARE_AR registers the burst size at this rising edge.
        @(posedge clk);
        #1;

        // The module should now be in SEND_AR and presenting the request.
        assert (busy)
            else $fatal(1, "AR test failed: busy is not asserted");

        assert (!cmd_ready)
            else $fatal(1, "AR test failed: cmd_ready is asserted");

        assert (m_axi_arvalid)
            else $fatal(1, "AR test failed: m_axi_arvalid is not asserted");

        assert (m_axi_araddr == 32'h00001000)
            else $fatal(1,
                "AR test failed: expected address 00001000, got %h",
                m_axi_araddr
            );

        assert (m_axi_arlen == 8'd3)
            else $fatal(1,
                "AR test failed: expected ARLEN 3, got %0d",
                m_axi_arlen
            );

        assert (m_axi_arsize == 3'd2)
            else $fatal(1,
                "AR test failed: expected ARSIZE 2, got %0d",
                m_axi_arsize
            );

        assert (m_axi_arburst == 2'b01)
            else $fatal(1,
                "AR test failed: expected INCR burst, got %b",
                m_axi_arburst
            );

        assert (!done)
            else $fatal(1, "AR test failed: done is asserted");

        assert (!error)
            else $fatal(1, "AR test failed: error is asserted");

        $display("AXI read-address presentation test passed");



        // ============================================================
        // TEST 4: COMPLETE SINGLE-BURST READ
        // ============================================================

        accept_ar(32'h00001000, 8'd3);

        send_read_beat(32'h11111111, 1'b0, 2'b00);
        send_read_beat(32'h22222222, 1'b0, 2'b00);
        send_read_beat(32'h33333333, 1'b0, 2'b00);
        send_read_beat(32'h44444444, 1'b1, 2'b00);

        assert (done)
            else $fatal(1, "Single-burst test failed: done is low");

        assert (!busy)
            else $fatal(1, "Single-burst test failed: busy is high");

        assert (cmd_ready)
            else $fatal(1, "Single-burst test failed: cmd_ready is low");

        assert (!error)
            else $fatal(1, "Single-burst test failed: error is high");

        $display("Single-burst read test passed");

        // Verify that done is a one-cycle pulse.
        @(posedge clk);
        #1;

        assert (!done)
            else $fatal(1, "done remained asserted for multiple cycles");


        // ============================================================
        // TEST 5: MULTIPLE BURSTS
        // 80 bytes = 20 beats = 16-beat burst + 4-beat burst
        // ============================================================

        start_command(32'h00002000, 32'd80);

        accept_ar(32'h00002000, 8'd15);

        for (i = 0; i < 16; i = i + 1) begin
            send_read_beat(
                32'h50000000 + i,
                (i == 15),
                2'b00
            );
        end

        assert (!done)
            else $fatal(1, "Multiple-burst test finished after first burst");

        // PREPARE_AR prepares the second burst.
        @(posedge clk);
        #1;

        assert (m_axi_arvalid)
            else $fatal(1, "Second burst was not presented");

        accept_ar(32'h00002040, 8'd3);

        for (i = 0; i < 4; i = i + 1) begin
            send_read_beat(
                32'h60000000 + i,
                (i == 3),
                2'b00
            );
        end

        assert (done)
            else $fatal(1, "Multiple-burst test failed: done is low");

        assert (!error)
            else $fatal(1, "Multiple-burst test failed: error is high");

        $display("Multiple-burst test passed");


        // ============================================================
        // TEST 6: 4 KB BOUNDARY SPLITTING
        // Address 0x0FF0 has only 16 bytes before 0x1000.
        // A 32-byte transfer must be divided into two 4-beat bursts.
        // ============================================================

        start_command(32'h00000FF0, 32'd32);

        accept_ar(32'h00000FF0, 8'd3);

        for (i = 0; i < 4; i = i + 1) begin
            send_read_beat(
                32'h70000000 + i,
                (i == 3),
                2'b00
            );
        end

        assert (!done)
            else $fatal(1, "4 KB test finished after first burst");

        @(posedge clk);
        #1;

        assert (m_axi_arvalid)
            else $fatal(1, "4 KB test did not present second burst");

        accept_ar(32'h00001000, 8'd3);

        for (i = 0; i < 4; i = i + 1) begin
            send_read_beat(
                32'h71000000 + i,
                (i == 3),
                2'b00
            );
        end

        assert (done)
            else $fatal(1, "4 KB boundary test failed: done is low");

        assert (!error)
            else $fatal(1, "4 KB boundary test failed: error is high");

        $display("4 KB boundary test passed");


        // ============================================================
        // TEST 7: FIFO BACKPRESSURE
        // ============================================================

        start_command(32'h00003000, 32'd4);
        accept_ar(32'h00003000, 8'd0);

        @(negedge clk);
        fifo_write_ready = 1'b0;
        m_axi_rdata      = 32'hCAFEBABE;
        m_axi_rresp      = 2'b00;
        m_axi_rlast      = 1'b1;
        m_axi_rvalid     = 1'b1;
        #1;

        assert (!m_axi_rready)
            else $fatal(1, "Backpressure test failed: RREADY is high");

        assert (fifo_write_valid)
            else $fatal(1, "Backpressure test failed: FIFO valid is low");

        // Wait one clock; the beat must not be accepted.
        @(posedge clk);
        #1;

        assert (!done)
            else $fatal(1, "Backpressure test completed while FIFO was full");

        // Release the backpressure.
        @(negedge clk);
        fifo_write_ready = 1'b1;
        #1;

        assert (m_axi_rready)
            else $fatal(1, "Backpressure test failed: RREADY stayed low");

        @(posedge clk);
        #1;

        m_axi_rvalid = 1'b0;
        m_axi_rlast  = 1'b0;

        assert (done)
            else $fatal(1, "Backpressure test failed: transfer did not complete");

        assert (!error)
            else $fatal(1, "Backpressure test failed: error is high");

        $display("FIFO backpressure test passed");


        // ============================================================
        // TEST 8: AXI READ ERROR RESPONSE
        // ============================================================

        start_command(32'h00004000, 32'd4);
        accept_ar(32'h00004000, 8'd0);

        send_read_beat(32'hDEADBEEF, 1'b1, 2'b10); // SLVERR

        assert (done)
            else $fatal(1, "Response-error test failed: done is low");

        assert (error)
            else $fatal(1, "Response-error test failed: error is low");

        $display("AXI response-error test passed");


        // ============================================================
        // TEST 9: MISALIGNED COMMAND
        // ============================================================

        @(negedge clk);
        cmd_source_addr  = 32'h00005001;
        cmd_length_bytes = 32'd4;
        cmd_valid        = 1'b1;
        #1;

        assert (cmd_ready)
            else $fatal(1, "Misalignment test: command interface not ready");

        @(posedge clk);
        #1;
        cmd_valid = 1'b0;

        assert (done)
            else $fatal(1, "Misalignment test failed: done is low");

        assert (error)
            else $fatal(1, "Misalignment test failed: error is low");

        assert (!m_axi_arvalid)
            else $fatal(1, "Misaligned command issued an AXI request");

        $display("Misaligned-command test passed");


        // ============================================================
        // TEST 10: ZERO-LENGTH COMMAND
        // ============================================================

        @(negedge clk);
        cmd_source_addr  = 32'h00006000;
        cmd_length_bytes = 32'd0;
        cmd_valid        = 1'b1;
        #1;

        assert (cmd_ready)
            else $fatal(1, "Zero-length test: command interface not ready");

        @(posedge clk);
        #1;
        cmd_valid = 1'b0;

        // The command first enters PREPARE_AR.
        assert (busy)
            else $fatal(1, "Zero-length test failed: busy is low too early");

        @(posedge clk);
        #1;

        // PREPARE_AR should detect that there are no beats.
        assert (done)
            else $fatal(1, "Zero-length test failed: done is low");

        assert (!busy)
            else $fatal(1, "Zero-length test failed: busy is high");

        assert (!error)
            else $fatal(1, "Zero-length test failed: error is high");

        assert (!m_axi_arvalid)
            else $fatal(1, "Zero-length command issued an AXI request");

        $display("Zero-length command test passed");

        $display("All axi_read_master directed tests passed");
        $stop;



    end

endmodule