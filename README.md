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