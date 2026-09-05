// Directed testbench
`timescale 1ns/1ps

module dma_fifo_tb;

    // ============================================================
    // PARAMETERS
    // ============================================================
    localparam int DATA_WIDTH = 32;
    localparam int FIFO_DEPTH = 4;

    // ============================================================
    // TESTBENCH SIGNALS
    // ============================================================
    logic clk;
    logic rst_n;

    logic [DATA_WIDTH-1:0] write_data;
    logic                  write_valid;
    logic                  write_ready;

    logic [DATA_WIDTH-1:0] read_data;
    logic                  read_valid;
    logic                  read_ready;

    logic                  full;
    logic                  empty;
    logic [$clog2(FIFO_DEPTH+1)-1:0] count;

    integer i;
    logic [DATA_WIDTH-1:0] expected_word;

    // ============================================================
    // DEVICE UNDER TEST
    // ============================================================
    dma_fifo #(
        .DATA_WIDTH(DATA_WIDTH),
        .FIFO_DEPTH(FIFO_DEPTH)
    ) dut (
        .clk         (clk),
        .rst_n       (rst_n),

        .write_data  (write_data),
        .write_valid (write_valid),
        .write_ready (write_ready),

        .read_data   (read_data),
        .read_valid  (read_valid),
        .read_ready  (read_ready),

        .full        (full),
        .empty       (empty),
        .count       (count)
    );

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
        write_data  = '0;
        write_valid = 1'b0;
        read_ready  = 1'b0;


        // ============================================================
        // TEST 1: RESET
        // ============================================================

        // Keep reset asserted across two rising clock edges.
        repeat (2) @(posedge clk);

        // Release reset away from the active clock edge.
        @(negedge clk);
        rst_n = 1'b1;

        // Check the FIFO after reset has been released.
        @(posedge clk);
        #1;

        assert (count == 0)
            else $fatal(1, "Reset failed: count is not zero");

        assert (empty)
            else $fatal(1, "Reset failed: empty is not asserted");

        assert (!full)
            else $fatal(1, "Reset failed: full is asserted");

        assert (!read_valid)
            else $fatal(1, "Reset failed: read_valid is asserted");

        assert (write_ready)
            else $fatal(1, "Reset failed: write_ready is not asserted");

        $display("Reset test passed");

        // ============================================================
        // TEST 2: WRITE ONE WORD
        // ============================================================

        // Apply write inputs before the active clock edge.
        @(negedge clk);
        write_data  = 32'hDEADBEEF;
        write_valid = 1'b1;
        read_ready  = 1'b0;

        // Verify that the FIFO is currently able to accept the word.
        assert (write_ready)
            else $fatal(1, "Single write failed: FIFO was not ready");

        // The write handshake occurs at this rising edge.
        @(posedge clk);
        #1;

        // Stop requesting another write.
        write_valid = 1'b0;

        assert (count == 1)
            else $fatal(1, "Single write failed: count should be 1");

        assert (!empty)
            else $fatal(1, "Single write failed: FIFO is still empty");

        assert (!full)
            else $fatal(1, "Single write failed: FIFO unexpectedly full");

        assert (read_valid)
            else $fatal(1, "Single write failed: read_valid is not asserted");

        assert (read_data == 32'hDEADBEEF)
            else $fatal(1,
                "Single write failed: expected DEADBEEF, received %h",
                read_data
            );

        $display("Single-write test passed");


        // ============================================================
        // TEST 3: READ ONE WORD
        // ============================================================

        // Tell the FIFO that the consumer is ready.
        @(negedge clk);
        read_ready = 1'b1;

        // Before the handshake, verify the offered word.
        assert (read_valid)
            else $fatal(1, "Single read failed: read_valid is not asserted");

        assert (read_data == 32'hDEADBEEF)
            else $fatal(1,
                "Single read failed: expected DEADBEEF, received %h",
                read_data
            );

        // The read handshake occurs at this rising edge.
        @(posedge clk);
        #1;

        // Stop requesting reads.
        read_ready = 1'b0;

        // The word should now be removed.
        assert (count == 0)
            else $fatal(1, "Single read failed: count should be 0");

        assert (empty)
            else $fatal(1, "Single read failed: empty is not asserted");

        assert (!full)
            else $fatal(1, "Single read failed: full is asserted");

        assert (!read_valid)
            else $fatal(1, "Single read failed: read_valid remained asserted");

        assert (write_ready)
            else $fatal(1, "Single read failed: FIFO cannot accept a new word");

        $display("Single-read test passed");


        // ============================================================
        // TEST 4: FILL THE FIFO
        // ============================================================

        for (i = 0; i < FIFO_DEPTH; i = i + 1) begin
            // Present the next word before the rising edge.
            @(negedge clk);
            write_data  = 32'h10000000 + i;
            write_valid = 1'b1;
            read_ready  = 1'b0;

            // There should be room for this word.
            assert (write_ready)
                else $fatal(1,
                    "Fill test failed: write_ready low before write %0d",
                    i
                );

            // Accept the word.
            @(posedge clk);
            #1;

            assert (count == i + 1)
                else $fatal(1,
                    "Fill test failed after write %0d: expected count %0d, got %0d",
                    i, i + 1, count
                );

            assert (!empty)
                else $fatal(1,
                    "Fill test failed: empty asserted after write %0d",
                    i
                );
        end

        // Stop presenting write data.
        @(negedge clk);
        write_valid = 1'b0;
        write_data  = '0;

        // The FIFO should now be completely full.
        assert (count == FIFO_DEPTH)
            else $fatal(1,
                "Full test failed: expected count %0d, got %0d",
                FIFO_DEPTH, count
            );

        assert (full)
            else $fatal(1, "Full test failed: full is not asserted");

        assert (!empty)
            else $fatal(1, "Full test failed: empty is asserted");

        assert (!write_ready)
            else $fatal(1,
                "Full test failed: write_ready asserted without a simultaneous read"
            );

        assert (read_valid)
            else $fatal(1, "Full test failed: read_valid is not asserted");

        assert (read_data == 32'h10000000)
            else $fatal(1,
                "Full test failed: expected first word 10000000, got %h",
                read_data
            );

        $display("FIFO fill test passed");


        // ============================================================
        // TEST 5: ATTEMPT WRITE WHILE FULL
        // ============================================================

        @(negedge clk);
        write_data  = 32'hDEADBEEF;
        write_valid = 1'b1;
        read_ready  = 1'b0;

        // The FIFO must reject the write.
        assert (!write_ready)
            else $fatal(1,
                "Overflow test failed: write_ready asserted while FIFO is full"
            );

        // No write handshake should occur at this rising edge.
        @(posedge clk);
        #1;

        // Stop requesting the rejected write.
        write_valid = 1'b0;
        write_data  = '0;

        // The FIFO occupancy must not change.
        assert (count == FIFO_DEPTH)
            else $fatal(1,
                "Overflow test failed: count changed to %0d",
                count
            );

        assert (full)
            else $fatal(1,
                "Overflow test failed: full was deasserted"
            );

        assert (!write_ready)
            else $fatal(1,
                "Overflow test failed: write_ready became asserted"
            );

        // The rejected word must not overwrite the oldest stored word.
        assert (read_valid)
            else $fatal(1,
                "Overflow test failed: read_valid is not asserted"
            );

        assert (read_data == 32'h10000000)
            else $fatal(1,
                "Overflow test failed: oldest word was corrupted; got %h",
                read_data
            );

        $display("FIFO overflow-protection test passed");


        // ============================================================
        // TEST 6: SIMULTANEOUS READ AND WRITE WHILE FULL
        // ============================================================

        @(negedge clk);

        // Supply a new word while also accepting the oldest word.
        write_data  = 32'hA5A5A5A5;
        write_valid = 1'b1;
        read_ready  = 1'b1;

        // Verify the oldest word before the handshake.
        assert (read_valid)
            else $fatal(1,
                "Simultaneous test failed: read_valid is not asserted"
            );

        assert (read_data == 32'h10000000)
            else $fatal(1,
                "Simultaneous test failed: expected 10000000, got %h",
                read_data
            );

        // Although the FIFO is full, the simultaneous read should allow
        // the new write to be accepted.
        assert (write_ready)
            else $fatal(1,
                "Simultaneous test failed: write_ready is not asserted"
            );

        // Both handshakes occur at this rising edge.
        @(posedge clk);
        #1;

        // Stop requesting additional operations.
        write_valid = 1'b0;
        read_ready  = 1'b0;
        write_data  = '0;

        // One word entered and one word left, so count must not change.
        assert (count == FIFO_DEPTH)
            else $fatal(1,
                "Simultaneous test failed: expected count %0d, got %0d",
                FIFO_DEPTH, count
            );

        assert (full)
            else $fatal(1,
                "Simultaneous test failed: FIFO should remain full"
            );

        assert (!empty)
            else $fatal(1,
                "Simultaneous test failed: FIFO became empty"
            );

        // The second-oldest word should now be at the front.
        assert (read_valid)
            else $fatal(1,
                "Simultaneous test failed: read_valid became low"
            );

        assert (read_data == 32'h10000001)
            else $fatal(1,
                "Simultaneous test failed: expected next word 10000001, got %h",
                read_data
            );

        // Since the FIFO remains full and no read is currently requested,
        // another write must not be accepted.
        assert (!write_ready)
            else $fatal(1,
                "Simultaneous test failed: write_ready remained high"
            );

        $display("Simultaneous full read/write test passed");


        // ============================================================
        // TEST 7: DRAIN FIFO AFTER SIMULTANEOUS READ/WRITE
        // ============================================================

        for (i = 0; i < FIFO_DEPTH; i = i + 1) begin
            @(negedge clk);

            write_valid = 1'b0;
            read_ready  = 1'b1;

            // Determine which word should currently be at the front.
            if (i < FIFO_DEPTH - 1)
                expected_word = 32'h10000001 + i;
            else
                expected_word = 32'hA5A5A5A5;

            // The FIFO must provide a valid word.
            assert (read_valid)
                else $fatal(1,
                    "Drain test failed: read_valid low before read %0d",
                    i
                );

            // Verify the word before consuming it.
            assert (read_data == expected_word)
                else $fatal(1,
                    "Drain test failed at read %0d: expected %h, got %h",
                    i,
                    expected_word,
                    read_data
                );

            // Consume the current word.
            @(posedge clk);
            #1;

            assert (count == FIFO_DEPTH - i - 1)
                else $fatal(1,
                    "Drain test failed after read %0d: expected count %0d, got %0d",
                    i,
                    FIFO_DEPTH - i - 1,
                    count
                );
        end

        // Stop requesting reads after consuming the final word.
        read_ready = 1'b0;

        // Verify the final empty state.
        assert (count == 0)
            else $fatal(1,
                "Drain test failed: final count is %0d",
                count
            );

        assert (empty)
            else $fatal(1,
                "Drain test failed: empty is not asserted"
            );

        assert (!full)
            else $fatal(1,
                "Drain test failed: full is asserted"
            );

        assert (!read_valid)
            else $fatal(1,
                "Drain test failed: read_valid is asserted while empty"
            );

        assert (write_ready)
            else $fatal(1,
                "Drain test failed: write_ready is not asserted"
            );

        $display("FIFO drain and ordering test passed");


        // ============================================================
        // TEST 8: ATTEMPT READ WHILE EMPTY
        // ============================================================

        @(negedge clk);
        write_valid = 1'b0;
        read_ready  = 1'b1;

        // The FIFO must not claim that it has valid data.
        assert (!read_valid)
            else $fatal(1,
                "Underflow test failed: read_valid asserted while empty"
            );

        assert (empty)
            else $fatal(1,
                "Underflow test failed: empty is not asserted"
            );

        // Attempt the read for one clock cycle.
        @(posedge clk);
        #1;

        // Stop requesting the read.
        read_ready = 1'b0;

        // Nothing should have changed.
        assert (count == 0)
            else $fatal(1,
                "Underflow test failed: count changed to %0d",
                count
            );

        assert (empty)
            else $fatal(1,
                "Underflow test failed: empty was deasserted"
            );

        assert (!full)
            else $fatal(1,
                "Underflow test failed: full is asserted"
            );

        assert (!read_valid)
            else $fatal(1,
                "Underflow test failed: read_valid became asserted"
            );

        assert (write_ready)
            else $fatal(1,
                "Underflow test failed: FIFO cannot accept a write"
            );

        $display("FIFO underflow-protection test passed");

        $finish;
    end

endmodule