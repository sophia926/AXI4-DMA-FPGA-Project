module dma_fifo #(
    parameter int DATA_WIDTH = 32,
    parameter int FIFO_DEPTH = 16
) (
    input  logic clk,
    input  logic rst_n,

    // ============================================================
    // WRITE INTERFACE — driven by AXI read engine
    // ============================================================
    input  logic [DATA_WIDTH-1:0] write_data,
    input  logic                  write_valid,
    output logic                  write_ready,

    // ============================================================
    // READ INTERFACE — consumed by AXI write engine
    // ============================================================
    output logic [DATA_WIDTH-1:0] read_data,
    output logic                  read_valid,
    input  logic                  read_ready,

    // ============================================================
    // FIFO STATUS
    // ============================================================
    output logic                  full,
    output logic                  empty,
    output logic [$clog2(FIFO_DEPTH+1)-1:0] count
);

    // ============================================================
    // DERIVED PARAMETERS
    // ============================================================
    localparam int PTR_WIDTH =
        (FIFO_DEPTH <= 1) ? 1 : $clog2(FIFO_DEPTH);

    // ============================================================
    // INTERNAL STORAGE
    // ============================================================
    logic [DATA_WIDTH-1:0] mem [0:FIFO_DEPTH-1];

    // ============================================================
    // READ AND WRITE POINTERS
    // ============================================================
    logic [PTR_WIDTH-1:0] write_ptr;
    logic [PTR_WIDTH-1:0] read_ptr;

    // ============================================================
    // INTERNAL HANDSHAKE SIGNALS
    // ============================================================
    logic write_fire;
    logic read_fire;

    // ============================================================
    // STATUS AND HANDSHAKE LOGIC
    // ============================================================
    always_comb begin
        // Determine the current FIFO state
        empty = (count == 0);
        full = (count == FIFO_DEPTH);

        // read interface
        // Advertise the oldest stored word to the consumer
        read_valid = !empty;
        read_data = mem[read_ptr]; // Presenting a word doesn't mean it has been removed.

        // A read only happens when: FIFO has valid data (read_valid==1) and consumer is ready for it (read_ready==1)
        read_fire = read_valid && read_ready;

        // write interface
        // Accepts writes when space exists or when a simultaneous read will free a location
        write_ready = !full || read_fire;
        
        // Write is accepted when both sides agree                                 
        write_fire = write_valid && write_ready;

    end

    // ============================================================
    // FIFO STORAGE AND CONTROL
    // ============================================================
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            // Reset pointers and count
            write_ptr <= '0;
            read_ptr <= '0;
            count <= '0;
            // Don't need to reset memory because any old bits inside memory are considered invalid by resetting the count
            // It also makes it easier for synthesis tools to infer FPGA memory resources
        end
        else begin

            if (write_fire) begin
                mem[write_ptr] <= write_data;
                
                if (write_ptr == FIFO_DEPTH-1) write_ptr <= '0;
                else write_ptr <= write_ptr + 1'b1;
            end

            if (read_fire) begin // consumer accepted the word currently presented on read_data
                if (read_ptr == FIFO_DEPTH-1) read_ptr <= '0;
                else read_ptr <= read_ptr + 1'b1;
            end

            case ({write_fire, read_fire})
                2'b10: count <= count + 1'b1; // write but no read
                2'b01: count <= count - 1'b1; // read but no write
                default: count <= count; // write and read also result in no change in count
            endcase

        end
    end

endmodule