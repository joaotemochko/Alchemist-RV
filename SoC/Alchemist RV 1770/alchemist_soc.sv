// Alchemist SoC - Complete RISC-V Heterogeneous System
// Integrates:
// - 4x Supernova RV64GCBV cores
// - 6x Nebula RV64I cores
// - Krypton GPU
// - Memory subsystem
// - Interconnect
// - Peripherals

`timescale 1ns/1ps
`default_nettype none

module alchemist_soc #(
    parameter int NUM_BIG_CORES = 4,
    parameter int NUM_LITTLE_CORES = 6,
    parameter int NUM_GPU_CORES = 10,
    parameter int XLEN = 64,
    parameter int PHYS_ADDR_SIZE = 56,
    parameter int MEM_SIZE = 0x40000000, // 1GB
    parameter int GPIO_WIDTH = 32
) (
    input wire clk,
    input wire rst_n,
    
    // External memory interface
    output logic mem_req,
    output logic mem_we,
    output logic [PHYS_ADDR_SIZE-1:0] mem_addr,
    output logic [127:0] mem_wdata,
    input wire [127:0] mem_rdata,
    input wire mem_ack,
    
    // Peripheral interfaces
    input wire [GPIO_WIDTH-1:0] gpio_in,
    output logic [GPIO_WIDTH-1:0] gpio_out,
    output logic [GPIO_WIDTH-1:0] gpio_dir,
    
    // UART interface
    input wire uart_rx,
    output logic uart_tx,
    
    // SPI interfaces
    output logic spi0_sclk,
    output logic spi0_mosi,
    input wire spi0_miso,
    output logic spi0_ss,
    
    // I2C interface
    output logic i2c_scl,
    inout wire i2c_sda,
    
    // Ethernet interface
    output logic eth_tx_en,
    output logic [3:0] eth_txd,
    input wire eth_rx_dv,
    input wire [3:0] eth_rxd,
    input wire eth_crs,
    input wire eth_col,
    output logic eth_ref_clk,
    
    // Display interface
    output logic hsync,
    output logic vsync,
    output logic [23:0] rgb,
    output logic display_en,
    
    // Interrupt inputs
    input wire [15:0] ext_irq
);

// --------------------------
// Clock and Reset Generation
// --------------------------
logic clk_cpu;
logic clk_gpu;
logic clk_mem;
logic clk_periph;
logic rst_sync_n;

clock_reset_gen clkgen (
    .clk_in(clk),
    .rst_in_n(rst_n),
    .clk_cpu_out(clk_cpu),
    .clk_gpu_out(clk_gpu),
    .clk_mem_out(clk_mem),
    .clk_periph_out(clk_periph),
    .rst_out_n(rst_sync_n)
);

// --------------------------
// Interconnect
// --------------------------
// Network-on-Chip (NoC) parameters
localparam NOC_NODES = NUM_BIG_CORES + NUM_LITTLE_CORES + 1; // +1 for GPU
localparam NOC_DATA_WIDTH = 128;
localparam NOC_ADDR_WIDTH = PHYS_ADDR_SIZE;

// NoC interfaces
typedef struct packed {
    logic req;
    logic we;
    logic [NOC_ADDR_WIDTH-1:0] addr;
    logic [NOC_DATA_WIDTH-1:0] wdata;
    logic [15:0] wstrb;
    logic [3:0] qos;
    logic [7:0] user;
} noc_request_t;

typedef struct packed {
    logic ack;
    logic [NOC_DATA_WIDTH-1:0] rdata;
    logic error;
} noc_response_t;

noc_request_t [NOC_NODES-1:0] noc_req;
noc_response_t [NOC_NODES-1:0] noc_resp;

// Address map
localparam BIG_CORE_OFFSET = 0;
localparam LITTLE_CORE_OFFSET = NUM_BIG_CORES;
localparam GPU_OFFSET = NUM_BIG_CORES + NUM_LITTLE_CORES;

// --------------------------
// Processor Cores
// --------------------------
// Supernova (Big) Cores
for (genvar i = 0; i < NUM_BIG_CORES; i++) begin : supernova_cores
    supernova_core #(
        .HART_ID(i),
        .XLEN(XLEN),
        .PHYS_ADDR_SIZE(PHYS_ADDR_SIZE),
        .BTB_ENTRIES(8192),
        .ROB_ENTRIES(128)
    ) core (
        .clk(clk_cpu),
        .rst_n(rst_sync_n),
        
        // NoC interface
        .imem_addr(noc_req[BIG_CORE_OFFSET+i].addr),
        .imem_req(noc_req[BIG_CORE_OFFSET+i].req),
        .imem_data(noc_resp[BIG_CORE_OFFSET+i].rdata[31:0]),
        .imem_ack(noc_resp[BIG_CORE_OFFSET+i].ack),
        .imem_error(noc_resp[BIG_CORE_OFFSET+i].error),
        
        .dmem_addr(noc_req[BIG_CORE_OFFSET+i].addr),
        .dmem_wdata(noc_req[BIG_CORE_OFFSET+i].wdata[XLEN-1:0]),
        .dmem_wstrb(noc_req[BIG_CORE_OFFSET+i].wstrb[7:0]),
        .dmem_req(noc_req[BIG_CORE_OFFSET+i].req),
        .dmem_we(noc_req[BIG_CORE_OFFSET+i].we),
        .dmem_rdata(noc_resp[BIG_CORE_OFFSET+i].rdata[XLEN-1:0]),
        .dmem_ack(noc_resp[BIG_CORE_OFFSET+i].ack),
        
        // Vector memory interface
        .vmem_addr(), // Connected to dedicated vector NoC
        .vmem_req(),
        .vmem_we(),
        .vmem_wdata(),
        .vmem_rdata(),
        .vmem_ack(),
        
        // Interrupts
        .timer_irq(),
        .external_irq(),
        .software_irq(),
        
        // Debug
        .debug_req(),
        .debug_ack(),
        .debug_halted(),
        
        // Performance counters
        .inst_retired(),
        .cycles(),
        .branches(),
        .branch_mispredicts()
    );
end

// Nebula (Little) Cores
for (genvar i = 0; i < NUM_LITTLE_CORES; i++) begin : nebula_cores
    nebula_core #(
        .HART_ID(NUM_BIG_CORES + i),
        .XLEN(XLEN),
        .PHYS_ADDR_SIZE(PHYS_ADDR_SIZE)
    ) core (
        .clk(clk_cpu),
        .rst_n(rst_sync_n),
        
        // NoC interface
        .imem_addr(noc_req[LITTLE_CORE_OFFSET+i].addr),
        .imem_req(noc_req[LITTLE_CORE_OFFSET+i].req),
        .imem_data(noc_resp[LITTLE_CORE_OFFSET+i].rdata[31:0]),
        .imem_ack(noc_resp[LITTLE_CORE_OFFSET+i].ack),
        .imem_error(noc_resp[LITTLE_CORE_OFFSET+i].error),
        
        .dmem_addr(noc_req[LITTLE_CORE_OFFSET+i].addr),
        .dmem_wdata(noc_req[LITTLE_CORE_OFFSET+i].wdata[XLEN-1:0]),
        .dmem_wstrb(noc_req[LITTLE_CORE_OFFSET+i].wstrb[7:0]),
        .dmem_req(noc_req[LITTLE_CORE_OFFSET+i].req),
        .dmem_we(noc_req[LITTLE_CORE_OFFSET+i].we),
        .dmem_rdata(noc_resp[LITTLE_CORE_OFFSET+i].rdata[XLEN-1:0]),
        .dmem_ack(noc_resp[LITTLE_CORE_OFFSET+i].ack),
        
        // Interrupts
        .timer_irq(),
        .external_irq(),
        .software_irq(),
        
        // Debug
        .debug_req(),
        .debug_ack(),
        
        // Performance counters
        .inst_retired(),
        .cycles()
    );
end

// --------------------------
// GPU Krypton
// --------------------------
gpu_krypton #(
    .NUM_CU(NUM_GPU_CORES),
    .MEM_DATA_WIDTH(128),
    .MEM_ADDR_WIDTH(PHYS_ADDR_SIZE)
) gpu (
    .clk_core(clk_gpu),
    .clk_mem(clk_mem),
    .rst_n(rst_sync_n),
    
    // NoC interface
    .host_req(noc_req[GPU_OFFSET].req),
    .host_we(noc_req[GPU_OFFSET].we),
    .host_addr(noc_req[GPU_OFFSET].addr),
    .host_wdata(noc_req[GPU_OFFSET].wdata),
    .host_rdata(noc_resp[GPU_OFFSET].rdata),
    .host_ack(noc_resp[GPU_OFFSET].ack),
    
    // Display output
    .hsync(hsync),
    .vsync(vsync),
    .rgb(rgb),
    .display_en(display_en),
    
    // Interrupts
    .irq_frame(),
    .irq_compute(),
    
    // Performance counters
    .gpu_cycles(),
    .shader_ops(),
    .tex_ops(),
    .pixels_rendered()
);

// --------------------------
// Network-on-Chip (NoC)
// --------------------------
noc_router #(
    .NUM_PORTS(NOC_NODES + 3), // Cores + GPU + Memory + Peripherals + Debug
    .DATA_WIDTH(NOC_DATA_WIDTH),
    .ADDR_WIDTH(NOC_ADDR_WIDTH)
) router (
    .clk(clk_cpu),
    .rst_n(rst_sync_n),
    
    // Core interfaces
    .req_in(noc_req),
    .resp_out(noc_resp),
    
    // Memory interface
    .req_out(mem_req),
    .we_out(mem_we),
    .addr_out(mem_addr),
    .wdata_out(mem_wdata),
    .rdata_in(mem_rdata),
    .ack_in(mem_ack),
    
    // Peripheral interface
    .periph_req_out(),
    .periph_we_out(),
    .periph_addr_out(),
    .periph_wdata_out(),
    .periph_rdata_in(),
    .periph_ack_in(),
    
    // Debug interface
    .debug_req_in(),
    .debug_we_in(),
    .debug_addr_in(),
    .debug_wdata_in(),
    .debug_rdata_out(),
    .debug_ack_out()
);

// --------------------------
// Memory Subsystem
// --------------------------
// Shared L3 Cache
l3_cache #(
    .SIZE(12 * 1024 * 1024),
    .LINE_SIZE(128),
    .ASSOCIATIVITY(16),
    .ADDR_WIDTH(PHYS_ADDR_SIZE)
) l3_cache (
    .clk(clk_mem),
    .rst_n(rst_sync_n),
    
    // NoC interface
    .cpu_req(mem_req),
    .cpu_we(mem_we),
    .cpu_addr(mem_addr),
    .cpu_wdata(mem_wdata),
    .cpu_rdata(mem_rdata),
    .cpu_ack(mem_ack),
    
    // DRAM interface
    .dram_req(),
    .dram_we(),
    .dram_addr(),
    .dram_wdata(),
    .dram_rdata(),
    .dram_ack(1'b1),
    
    // Performance counters
    .hit_count(),
    .miss_count(),
    .writebacks()
);

// --------------------------
// Peripheral Subsystem
// --------------------------
peripheral_subsystem #(
    .GPIO_WIDTH(GPIO_WIDTH),
    .UART_FIFO_DEPTH(16),
    .SPI_FIFO_DEPTH(8),
    .I2C_FIFO_DEPTH(8),
    .ETH_MTU(1500)
) periphs (
    .clk(clk_periph),
    .rst_n(rst_sync_n),
    
    // NoC interface
    .noc_req(),
    .noc_resp(),
    
    // GPIO
    .gpio_in(gpio_in),
    .gpio_out(gpio_out),
    .gpio_dir(gpio_dir),
    
    // UART
    .uart_rx(uart_rx),
    .uart_tx(uart_tx),
    
    // SPI
    .spi0_sclk(spi0_sclk),
    .spi0_mosi(spi0_mosi),
    .spi0_miso(spi0_miso),
    .spi0_ss(spi0_ss),
    
    // I2C
    .i2c_scl(i2c_scl),
    .i2c_sda(i2c_sda),
    
    // Ethernet
    .eth_tx_en(eth_tx_en),
    .eth_txd(eth_txd),
    .eth_rx_dv(eth_rx_dv),
    .eth_rxd(eth_rxd),
    .eth_crs(eth_crs),
    .eth_col(eth_col),
    .eth_ref_clk(eth_ref_clk),
    
    // Interrupt controller
    .irq_out(),
    .irq_in(ext_irq)
);

// --------------------------
// Power Management Unit
// --------------------------
power_management_unit #(
    .NUM_DOMAINS(8)
) pmu (
    .clk(clk),
    .rst_n(rst_sync_n),
    
    // Power domains
    .domain_en(),
    
    // Voltage control
    .voltage_level(),
    
    // Clock control
    .clk_en(),
    .clk_div(),
    
    // Thermal sensors
    .temp_sense(),
    
    // Power gates
    .power_gate()
);

// --------------------------
// Debug Module
// --------------------------
debug_module #(
    .NUM_CORES(NUM_BIG_CORES + NUM_LITTLE_CORES)
) dbg (
    .clk(clk),
    .rst_n(rst_sync_n),
    
    // JTAG interface
    .tck(),
    .tms(),
    .tdi(),
    .tdo(),
    
    // Core debug interfaces
    .core_debug_req(),
    .core_debug_ack(),
    .core_debug_halted(),
    
    // Memory access
    .mem_req(),
    .mem_we(),
    .mem_addr(),
    .mem_wdata(),
    .mem_rdata(),
    .mem_ack()
);

endmodule