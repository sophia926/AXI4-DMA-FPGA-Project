Project: Memory-to-memory AXI4 DMA Engine

Source region in external RAM
↓
AXI read engine
↓
DMA FIFO
↓
AXI write engine
↓
Destination region in external RAM

Additional tests:
- Reset while nonempty for dma_fifo
- Random testing dma_fifo with queue


# axi_read_master.sv
- Receives a DMA read command containing a source address and transfer length
- Converts that command into 1 or more AXI4 burst-read transactions
- For each burst, it places the current source address on ARADDR, specifies the # of beats using ARLEN, asserts ARVALID, and waits for the memory system to assert ARREADY
- If the complete transfer is larger than the configured maximum burst size, the read master divides the transfer into multiple legal bursts
- After a read-address request is accepted, the memory returns words through the AXI R channel
- The read master transfers each accepted word into dma_fifo, using the FIFO's write_valid and write_ready handshake
- If the FIFO is full, the read master deasserts RREADY, causing the AXI memory to hold the current read word until space becomes available
- It counts the received beats, checks RRESP for errors, verifies that RLAST arrives on the expected final beat, and then issues another burst or asserts done once every requested word has been received


Information about transfers:
- A **beat** is one individual data transfer during a single clock handshake. With DATA_WIDTH=32, one beat carries 4 bytes.
- A **burst** is a group of consecutive beats requested using one AXI address transaction. For example, one 16-beat burst on a 32-bit bus transfers 16*4=64 bytes.
- bytes_remaining -> beats_remaining (divide by BYTES_PER_BEAT, which is calculated with DATA_WIDTH/8). 2^(AXI_SIZE) = bytes per beat
- MAX_BURST_LEN=16 means our design allows no more than 16 beats per burst. AXIA burst cannot cross a 4KB address boundary. So, next_burst_beats = smallest of total remaining beats, configured 16-beat maximum, and # of beats possible before the next 4KB boundary.
    - The lower 12 bits (2^12 = 4096) represent the offset inside a 4KB page. The upper address bits (ex: address[31:12]) must stay in the same from the start of the burst to the end of the burst.
- Once calculated, next_burst_beats is stored in burst_beats, representing the expected size of the current burst. beat_count then tracks # of beats from that burst that have actually been received. When the current burst finishes, the module either prepares another burst or asserts done if the entire DMA read command has been completed.

# axi_dma_top_level.sv
- Coordinates the three data-path modules
- Captures one external command, sends the source address & length to the read master, and sends the destination address and same length to the write master
- The read master retrieves words from memory and puts them into the FIFO; the write master removes those words and writes them tot eh destination
- Top level tracks the two different modules using two pending bits and two done_seen bits, which prevents another command while a transfer is active, combiens errors from both masters, and asserts overall done only after both sides have completed.