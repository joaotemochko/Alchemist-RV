module peripheral_subsystem #(
    parameter int GPIO_WIDTH = 32,
    parameter int UART_FIFO_DEPTH = 16,
    parameter int SPI_FIFO_DEPTH = 8,
    parameter int I2C_FIFO_DEPTH = 8,
    parameter int ETH_MTU = 1500
) (
    input wire clk,
    input wire rst_n,
    
    // NoC interface
    input wire noc_req,
    input wire noc_we,
    input wire [55:0] noc_addr,
    input wire [127:0] noc_wdata,
    output logic noc_ack,
    output logic [127:0] noc_rdata,
    
    // GPIO
    input wire [GPIO_WIDTH-1:0] gpio_in,
    output logic [GPIO_WIDTH-1:0] gpio_out,
    output logic [GPIO_WIDTH-1:0] gpio_dir,
    
    // UART
    input wire uart_rx,
    output logic uart_tx,
    
    // SPI
    output logic spi0_sclk,
    output logic spi0_mosi,
    input wire spi0_miso,
    output logic spi0_ss,
    
    // I2C
    output logic i2c_scl,
    inout wire i2c_sda,
    
    // Ethernet
    output logic eth_tx_en,
    output logic [3:0] eth_txd,
    input wire eth_rx_dv,
    input wire [3:0] eth_rxd,
    input wire eth_crs,
    input wire eth_col,
    output logic eth_ref_clk,
    
    // Interrupt controller
    output logic [15:0] irq_out,
    input wire [15:0] irq_in
);

// Address map
localparam GPIO_BASE = 56'h4000_0000;
localparam UART_BASE = 56'h4000_1000;
localparam SPI_BASE = 56'h4000_2000;
localparam I2C_BASE = 56'h4000_3000;
localparam ETH_BASE = 56'h4000_4000;
localparam IRQ_BASE = 56'h4000_5000;

// Register file
typedef struct packed {
    logic [GPIO_WIDTH-1:0] gpio_out_reg;
    logic [GPIO_WIDTH-1:0] gpio_dir_reg;
    logic [7:0] uart_tx_data;
    logic uart_tx_valid;
    logic uart_tx_ready;
    logic [7:0] uart_rx_data;
    logic uart_rx_valid;
    logic [15:0] irq_mask;
    logic [15:0] irq_status;
} periph_regs_t;

periph_regs_t regs;

// UART FIFOs
logic [7:0] uart_tx_fifo [0:UART_FIFO_DEPTH-1];
logic [3:0] uart_tx_wptr, uart_tx_rptr;
logic [7:0] uart_rx_fifo [0:UART_FIFO_DEPTH-1];
logic [3:0] uart_rx_wptr, uart_rx_rptr;

// UART transmitter
uart_tx tx (
    .clk(clk),
    .rst_n(rst_n),
    .data(uart_tx_fifo[uart_tx_rptr]),
    .valid(uart_tx_rptr != uart_tx_wptr),
    .ready(regs.uart_tx_ready),
    .tx(uart_tx)
);

// UART receiver
uart_rx rx (
    .clk(clk),
    .rst_n(rst_n),
    .rx(uart_rx),
    .data(uart_rx_fifo[uart_rx_wptr]),
    .valid(/* rx_valid signal */),
    .ready(/* rx_ready signal */)
);

// SPI controller
spi_master #(
    .FIFO_DEPTH(SPI_FIFO_DEPTH)
) spi (
    .clk(clk),
    .rst_n(rst_n),
    .sclk(spi0_sclk),
    .mosi(spi0_mosi),
    .miso(spi0_miso),
    .ss(spi0_ss),
    .addr(noc_addr[3:0]),
    .wdata(noc_wdata[7:0]),
    .we(noc_we && (noc_addr[15:0] >= SPI_BASE[15:0]) && 
        (noc_addr[15:0] < SPI_BASE[15:0] + 16'h1000)),
    .rdata(/* spi_rdata */),
    .req(noc_req && (noc_addr[15:0] >= SPI_BASE[15:0]) && 
        (noc_addr[15:0] < SPI_BASE[15:0] + 16'h1000)),
    .ack(/* spi_ack */)
);

// I2C controller
i2c_master #(
    .FIFO_DEPTH(I2C_FIFO_DEPTH)
) i2c (
    .clk(clk),
    .rst_n(rst_n),
    .scl(i2c_scl),
    .sda(i2c_sda),
    .addr(noc_addr[3:0]),
    .wdata(noc_wdata[7:0]),
    .we(noc_we && (noc_addr[15:0] >= I2C_BASE[15:0]) && 
        (noc_addr[15:0] < I2C_BASE[15:0] + 16'h1000)),
    .rdata(/* i2c_rdata */),
    .req(noc_req && (noc_addr[15:0] >= I2C_BASE[15:0]) && 
        (noc_addr[15:0] < I2C_BASE[15:0] + 16'h1000)),
    .ack(/* i2c_ack */)
);

// Ethernet MAC
eth_mac #(
    .MTU(ETH_MTU)
) eth (
    .clk(clk),
    .rst_n(rst_n),
    .tx_en(eth_tx_en),
    .txd(eth_txd),
    .rx_dv(eth_rx_dv),
    .rxd(eth_rxd),
    .crs(eth_crs),
    .col(eth_col),
    .ref_clk(eth_ref_clk),
    .addr(noc_addr[7:0]),
    .wdata(noc_wdata[31:0]),
    .we(noc_we && (noc_addr[15:0] >= ETH_BASE[15:0]) && 
        (noc_addr[15:0] < ETH_BASE[15:0] + 16'h1000)),
    .rdata(/* eth_rdata */),
    .req(noc_req && (noc_addr[15:0] >= ETH_BASE[15:0]) && 
        (noc_addr[15:0] < ETH_BASE[15:0] + 16'h1000)),
    .ack(/* eth_ack */)
);

// Interrupt controller
interrupt_controller #(
    .NUM_IRQS(16)
) irq_ctrl (
    .clk(clk),
    .rst_n(rst_n),
    .irq_in(irq_in),
    .irq_out(irq_out),
    .irq_mask(regs.irq_mask),
    .irq_status(regs.irq_status),
    .addr(noc_addr[3:0]),
    .wdata(noc_wdata[15:0]),
    .we(noc_we && (noc_addr[15:0] >= IRQ_BASE[15:0]) && 
        (noc_addr[15:0] < IRQ_BASE[15:0] + 16'h1000)),
    .rdata(/* irq_rdata */),
    .req(noc_req && (noc_addr[15:0] >= IRQ_BASE[15:0]) && 
        (noc_addr[15:0] < IRQ_BASE[15:0] + 16'h1000)),
    .ack(/* irq_ack */)
);

// Register access
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        regs <= '{
            gpio_out_reg: 0,
            gpio_dir_reg: 0,
            uart_tx_data: 0,
            uart_tx_valid: 0,
            uart_rx_data: 0,
            uart_rx_valid: 0,
            irq_mask: 0,
            irq_status: 0
        };
        noc_ack <= 0;
        noc_rdata <= 0;
    end else begin
        noc_ack <= 0;
        
        if (noc_req && !noc_ack) begin
            noc_ack <= 1;
            
            case (noc_addr[15:0])
                // GPIO
                GPIO_BASE[15:0] + 0: begin
                    if (noc_we) regs.gpio_out_reg <= noc_wdata[GPIO_WIDTH-1:0];
                    noc_rdata <= regs.gpio_out_reg;
                end
                GPIO_BASE[15:0] + 8: begin
                    if (noc_we) regs.gpio_dir_reg <= noc_wdata[GPIO_WIDTH-1:0];
                    noc_rdata <= regs.gpio_dir_reg;
                end
                GPIO_BASE[15:0] + 16: begin
                    noc_rdata <= gpio_in;
                end
                
                // UART
                UART_BASE[15:0] + 0: begin
                    if (noc_we && uart_tx_wptr + 1 != uart_tx_rptr) begin
                        uart_tx_fifo[uart_tx_wptr] <= noc_wdata[7:0];
                        uart_tx_wptr <= uart_tx_wptr + 1;
                    end
                    noc_rdata <= {24'b0, uart_tx_fifo[uart_tx_rptr]};
                end
                UART_BASE[15:0] + 8: begin
                    noc_rdata <= {31'b0, uart_tx_wptr != uart_tx_rptr};
                end
                UART_BASE[15:0] + 16: begin
                    if (uart_rx_rptr != uart_rx_wptr) begin
                        noc_rdata <= {24'b0, uart_rx_fifo[uart_rx_rptr]};
                        uart_rx_rptr <= uart_rx_rptr + 1;
                    end else begin
                        noc_rdata <= 0;
                    end
                end
                
                // Interrupt controller
                IRQ_BASE[15:0] + 0: begin
                    if (noc_we) regs.irq_mask <= noc_wdata[15:0];
                    noc_rdata <= regs.irq_mask;
                end
                IRQ_BASE[15:0] + 8: begin
                    noc_rdata <= regs.irq_status;
                end
                
                default: begin
                    noc_rdata <= 0;
                end
            endcase
        end
        
        // GPIO output
        gpio_out <= regs.gpio_out_reg;
        gpio_dir <= regs.gpio_dir_reg;
        
        // Interrupt status update
        regs.irq_status <= irq_in & regs.irq_mask;
    end
end

endmodule