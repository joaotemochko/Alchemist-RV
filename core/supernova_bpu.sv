module supernova_bpu #(
    parameter int BTB_ENTRIES = 8192,
    parameter int RAS_DEPTH = 16,
    parameter int XLEN = 64
) (
    input wire clk,
    input wire rst_n,
    
    // Prediction interface
    input wire [XLEN-1:0] pc,
    output logic [XLEN-1:0] predicted_pc,
    output logic predicted_taken,
    
    // Update interface
    input wire update_en,
    input wire [XLEN-1:0] update_pc,
    input wire [XLEN-1:0] update_target,
    input wire update_taken,
    input wire is_call,
    input wire is_ret,
    input wire [XLEN-1:0] ret_addr
);

// Branch Target Buffer (BTB)
typedef struct packed {
    logic valid;
    logic [XLEN-1:0] tag;
    logic [XLEN-1:0] target;
    logic [1:0] history;
} btb_entry_t;

btb_entry_t btb [0:BTB_ENTRIES-1];

// Return Address Stack (RAS)
logic [XLEN-1:0] ras [0:RAS_DEPTH-1];
logic [3:0] ras_ptr;

// Global History Register
logic [15:0] ghr;

// Prediction
always_comb begin
    automatic btb_entry_t entry = btb[pc[14:3]];
    if (entry.valid && entry.tag == pc[XLEN-1:3]) begin
        predicted_taken = (entry.history != 2'b00);
        predicted_pc = predicted_taken ? entry.target : pc + 4;
    end else begin
        predicted_taken = 0;
        predicted_pc = pc + 4;
    end
end

// Update
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        for (int i = 0; i < BTB_ENTRIES; i++) begin
            btb[i].valid <= 0;
        end
        ras_ptr <= 0;
        ghr <= 0;
    end else if (update_en) begin
        // Update BTB
        automatic btb_entry_t new_entry;
        new_entry.valid = 1;
        new_entry.tag = update_pc[XLEN-1:3];
        new_entry.target = update_target;
        
        // Update history (2-bit saturating counter)
        if (update_taken) begin
            new_entry.history = (btb[update_pc[14:3]].history == 2'b11) ? 
                               2'b11 : btb[update_pc[14:3]].history + 1;
        end else begin
            new_entry.history = (btb[update_pc[14:3]].history == 2'b00) ? 
                               2'b00 : btb[update_pc[14:3]].history - 1;
        end
        
        btb[update_pc[14:3]] <= new_entry;
        
        // Update RAS
        if (is_call) begin
            ras[ras_ptr] <= update_pc + 4;
            ras_ptr <= ras_ptr + 1;
        end else if (is_ret) begin
            ras_ptr <= ras_ptr - 1;
        end
        
        // Update GHR
        ghr <= {ghr[14:0], update_taken};
    end
end

endmodule