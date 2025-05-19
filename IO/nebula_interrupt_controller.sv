module nebula_interrupt_controller #(
    parameter int NUM_SOURCES = 64,
    parameter int NUM_HARTS = 4,
    parameter int XLEN = 64
) (
    input wire clk,
    input wire rst_n,
    
    // Interrupt sources
    input wire [NUM_SOURCES-1:0] irq_sources,
    input wire [NUM_SOURCES-1:0] irq_enable,
    
    // Core interface
    output logic [NUM_HARTS-1:0] irq_pending,
    output logic [NUM_HARTS-1:0][XLEN-1:0] irq_cause,
    input wire [NUM_HARTS-1:0] irq_ack,
    input wire [NUM_HARTS-1:0][XLEN-1:0] irq_id,
    
    // Configuration interface
    input wire [NUM_SOURCES-1:0][$clog2(NUM_HARTS)-1:0] irq_target,
    input wire [NUM_SOURCES-1:0][XLEN-1:0] irq_priority,
    input wire [NUM_SOURCES-1:0][XLEN-1:0] irq_threshold
);

logic [NUM_SOURCES-1:0] irq_active;
logic [NUM_HARTS-1:0][NUM_SOURCES-1:0] hart_irq_pending;
logic [NUM_HARTS-1:0][XLEN-1:0] highest_priority_cause;
logic [NUM_HARTS-1:0][$clog2(NUM_SOURCES)-1:0] highest_priority_irq;

// Detect active interrupts (enabled and asserted)
always_comb begin
    irq_active = irq_sources & irq_enable;
end

// Assign interrupts to harts based on target mapping
always_comb begin
    hart_irq_pending = '0;
    for (int i = 0; i < NUM_SOURCES; i++) begin
        if (irq_active[i]) begin
            hart_irq_pending[irq_target[i]][i] = 1;
        end
    end
end

// Priority encoder for each hart
generate
    for (genvar hart = 0; hart < NUM_HARTS; hart++) begin : priority_encoder
        always_comb begin
            highest_priority_cause[hart] = '0;
            highest_priority_irq[hart] = '0;
            irq_pending[hart] = 0;
            
            // Find highest priority pending interrupt
            for (int i = 0; i < NUM_SOURCES; i++) begin
                if (hart_irq_pending[hart][i] && 
                    (irq_priority[i] > irq_priority[highest_priority_irq[hart]] || 
                     !irq_pending[hart]) &&
                    irq_priority[i] > irq_threshold[i]) begin
                    highest_priority_irq[hart] = i;
                    highest_priority_cause[hart] = {1'b1, 63'(i)};
                    irq_pending[hart] = 1;
                end
            end
            
            // If an interrupt is being acknowledged, use that ID
            if (irq_ack[hart]) begin
                irq_cause[hart] = irq_id[hart];
            end else begin
                irq_cause[hart] = highest_priority_cause[hart];
            end
        end
    end
endgenerate

// Interrupt claim/completion tracking
logic [NUM_SOURCES-1:0] claimed_irqs;

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        claimed_irqs <= '0;
    end else begin
        for (int hart = 0; hart < NUM_HARTS; hart++) begin
            if (irq_ack[hart]) begin
                claimed_irqs[irq_id[hart][$clog2(NUM_SOURCES)-1:0]] <= 1;
            end
        end
        
        // Clear claimed interrupts when source goes inactive
        for (int i = 0; i < NUM_SOURCES; i++) begin
            if (!irq_active[i]) begin
                claimed_irqs[i] <= 0;
            end
        end
    end
end

endmodule