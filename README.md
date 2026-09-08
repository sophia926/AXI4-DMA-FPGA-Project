# Project: Memory-to-memory AXI4 DMA Engine

**Overview**: This is a parameterized SystemVerilog DMA engine that moves a contiguous block of data from a source memory address to a destination memory address over AXI4. The design issues AXI read bursts, buffers returned data in a synchronous FIFO, and issues AXI write bursts to the destination.

## Architecture

DMA command
↓
DMA top level
↓
AXI ready master
↓
(asks source memory for data)
↓
Source memory
↓
(AXI R data)
↓
Synchronous FIFO
↓
(buffered data)
↓
AXI write master
↓
(AXI W data)
↓
Destination memory
↓
(AXI B response)
↓
AXI write master


More simply,
Source region in external RAM
↓
AXI read engine
↓
DMA FIFO
↓
AXI write engine
↓
Destination region in external RAM

## axi_dma_top_level.sv
**Summary**: Accepts the DMA command, coordinates both engines, and combines completion/error status
- Coordinates the three data-path modules
- Captures one external command, sends the source address & length to the read master, and sends the destination address and same length to the write master
- The read master retrieves words from memory and puts them into the FIFO; the write master removes those words and writes them tot eh destination
- Top level tracks the two different modules using two pending bits and two done_seen bits, which prevents another command while a transfer is active, combiens errors from both masters, and asserts overall done only after both sides have completed.


## axi_read_master.sv
**Summary**: Generates AXI read-address bursts and forwards accepted read data into the FIFO
- Receives a DMA read command containing a source address and transfer length
- Converts that command into 1 or more AXI4 burst-read transactions
- For each burst, it places the current source address on ARADDR, specifies the # of beats using ARLEN, asserts ARVALID, and waits for the memory system to assert ARREADY
- If the complete transfer is larger than the configured maximum burst size, the read master divides the transfer into multiple legal bursts
- After a read-address request is accepted, the memory returns words through the AXI R channel
- The read master transfers each accepted word into dma_fifo, using the FIFO's write_valid and write_ready handshake
- If the FIFO is full, the read master deasserts RREADY, causing the AXI memory to hold the current read word until space becomes available
- It counts the received beats, checks RRESP for errors, verifies that RLAST arrives on the expected final beat, and then issues another burst or asserts done once every requested word has been received

## dma_fifo.sv
**Summary**: Buffers read data and propogates backpressure between the AXI read and write sides
- Single-clock synchronous FIFO that decouples the AXI read-data path from the AXI write-data path. Read master writes each accepted AXI R beat into the FIFO through a ready/valid interface, while the write master removes FIFO words through an independent ready/valid interface.
- Keeps read/write pointers and counter to generate full, empty, count status.
- FIFO propogates backpressure upstream by deasserting write_ready when it cannot accept more data, which causes the read master to deassert RREADY. It also permits a read and write in the same cycle when full.


## axi_write_master.sv
**Summary**: Waits for a complete burst in the FIFO, then generates AXI write-address, data, and response transactions
- Receives a destination address and transfer length from the top-level controller, removes buffered data from dma_fifo, and writes that data to the AXI destination memory.
- Divides the transfer into legal bursts that are limited by the configured maximum burst length and the next 4 KB address boundary.
- Before issuing a write-address transaction, it waits until the FIFO contains every beat required for that burst; this guarantees that once AW is accepted, the module can complete all associated W transfers without running out of data
- It drives WLAST on the final beat, waits for the AXI B response, records response errors, then either prepares the next burst or asserts done when the full requested transfer is complete

## Information about transfers:
- A **beat** is one individual data transfer during a single clock handshake. With DATA_WIDTH=32, one beat carries 4 bytes.
- A **burst** is a group of consecutive beats requested using one AXI address transaction. For example, one 16-beat burst on a 32-bit bus transfers 16*4=64 bytes.
- bytes_remaining -> beats_remaining (divide by BYTES_PER_BEAT, which is calculated with DATA_WIDTH/8). 2^(AXI_SIZE) = bytes per beat
- MAX_BURST_LEN=16 means our design allows no more than 16 beats per burst. AXIA burst cannot cross a 4KB address boundary. So, next_burst_beats = smallest of total remaining beats, configured 16-beat maximum, and # of beats possible before the next 4KB boundary.
    - The lower 12 bits (2^12 = 4096) represent the offset inside a 4KB page. The upper address bits (ex: address[31:12]) must stay in the same from the start of the burst to the end of the burst.
- Once calculated, next_burst_beats is stored in burst_beats, representing the expected size of the current burst. beat_count then tracks # of beats from that burst that have actually been received. When the current burst finishes, the module either prepares another burst or asserts done if the entire DMA read command has been completed.

1) A command supplies source_addr, dest_addr, and length_bytes to the top level
2) Read master calculates next legal burst length, sends an AR request, and transfers each accepted R beat into the FIFO
3) Once the FIFO contains the complete planned burst, the write master sends the corresponding AW request
4) The write master removes FIFO words, presents them on the W channel, asserts WLAST on the final beat, and waits for B response
5) Both engines repeat as needed until the requested byte count has transferred. The top level asserts done after both sides complete


## Key Design Features
- Parameterized address width, data width, transfer length width, FIFO depth, and maximum burst length.
- Full-width, aligned 32-bit transfers (4 bytes/beat) in the default configuration
- INCR bursts split so that no burst exceeds the configured maximum length or crosses a 4KB address boundary
- AXI VALID/READY handshakes used on every channel; the FIFO naturally backpressures the read-data channel when full
- FIFO supports a simultaneous read and write when full, preventing an unnecessary bubble when the write side consumes a word
- Read master checks RRESP and validates RLAST; write master checks BRESP before completing each burst
- Write master waits until the FIFO contains an entire planned burst before issuing its write address. This prevents underflow during a write burst

## Verification
- Directed SystemVerilog testbenches were used for the FIFO, read master, write master, and integrated DMA design. The integrated testbench includes a behavioral AXI memory model.
- Tests include:
    - Reset and command-acceptance behavior.
    - Single-word and single-burst memory-to-memory transfers.
    - Multi-burst transfers exceeding the configured maximum burst length.
    - Transfers requiring a split at a 4 KB boundary.
    - AXI address/data-channel stalls and FIFO backpressure.
    - FIFO fill/drain ordering and simultaneous read/write behavior.
    - Zero-length commands and AXI read/write error responses.

## FPGA Implementation Results
Complete design was synthesized and implemented in Vivado with a 100MHz clock constraint.

| Metric | Result |
| -------- | -------- |
| Worst Negative Setup Slack (WNS) | 1.789 ns   |
| Worst Hold Slack (WHS) | 0.088 ns |
| Slice LUTs | 397 |
| Slice Registers | 278 |
| Occupied Slices | 149 |
| LUTs used as logic | 375 |
| LUTs used as memory | 22 |
| Block RAM | 0 |

## Tools
- SystemVerilog RTL, directed testbenches
- ModelSim for simulation
- Xilinx Vivado for linting, synthesis, implementation, utilization reporting, and static timing analysis

## Possible Extensions
- Constrained Random Verification
- Support unaligned transfers and byte strobes
- Permit read and write engines to overlap more aggressively with burst-level credit control
    - Current design: while write master sends one burst from the FIFO, the read master can keep accepting more data whenever the FIFO has more space. But within each write burst, we intentionally chose a simpler, safer policy: axi_write_master stays in WAIT_DATA until fifo_count >= burst_beats. Only then does it issue AW and begin W transfers. So, for a 16-beat burst, it waits until all 16 words are buffered befoer even writing the first one. That prevents FIFO underflow, but it adds latency and means the read and write sides don't stream the same burst through the FIFO at the same time.
    - Burst-level credit control would mean the design would track how many FIFO netires are free and reserver enough capacity before issugina  read burst; it could then issue the destination AW request early and start sending W data as soon as the first FIFO word arrives. It would need explicit accounting to guarantee the FIFO cannot underflow during the write burst or overflow while accepting read data. 