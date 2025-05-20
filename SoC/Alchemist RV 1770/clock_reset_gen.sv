module clock_reset_gen (
    input wire clk_in,
    input wire rst_in_n,
    
    output logic clk_cpu_out,
    output logic clk_gpu_out,
    output logic clk_mem_out,
    output logic clk_periph_out,
    output logic rst_out_n
);

// PLL configurations
logic pll_locked;

// CPU PLL (3.5 GHz max)
pll #(
    .MULT(35),
    .DIV(10)
) cpu_pll (
    .clk_in(clk_in),
    .clk_out(clk_cpu_out),
    .locked(pll_locked)
);

// GPU PLL (1.3 GHz)
pll #(
    .MULT(13),
    .DIV(10)
) gpu_pll (
    .clk_in(clk_in),
    .clk_out(clk_gpu_out),
    .locked()
);

// Memory PLL (1.6 GHz)
pll #(
    .MULT(16),
    .DIV(10)
) mem_pll (
    .clk_in(clk_in),
    .clk_out(clk_mem_out),
    .locked()
);

// Peripheral PLL (200 MHz)
pll #(
    .MULT(2),
    .DIV(10)
) periph_pll (
    .clk_in(clk_in),
    .clk_out(clk_periph_out),
    .locked()
);

// Reset synchronizer
reset_sync rst_sync (
    .clk(clk_cpu_out),
    .rst_in_n(rst_in_n & pll_locked),
    .rst_out_n(rst_out_n)
);

endmodule