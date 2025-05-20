module supernova_vpu #(
    parameter int VLEN = 256,
    parameter int XLEN = 64
) (
    input wire clk,
    input wire rst_n,
    
    // Instruction interface
    input wire vpu_req,
    input wire [31:0] vpu_instr,
    input wire [XLEN-1:0] rs1_val,
    input wire [XLEN-1:0] rs2_val,
    input wire [VLEN-1:0] vs1_val,
    input wire [VLEN-1:0] vs2_val,
    input wire [VLEN-1:0] vs3_val,
    input wire [6:0] vtype,
    input wire [XLEN-1:0] vl,
    output logic vpu_ack,
    output logic [VLEN-1:0] vpu_result,
    
    // Memory interface
    output logic vmem_req,
    output logic vmem_we,
    output logic [XLEN-1:0] vmem_addr,
    output logic [VLEN-1:0] vmem_wdata,
    input wire [VLEN-1:0] vmem_rdata,
    input wire vmem_ack,
    
    // Performance counters
    output logic [63:0] vec_ops
);

// Vector register
logic [VLEN-1:0] vreg [0:31];

// Execution pipeline
enum logic [2:0] {
    IDLE,
    DECODE,
    EXECUTE,
    MEMORY,
    WRITEBACK
} state;

// Vector length
logic [XLEN-1:0] current_vl;

// Element width
logic [2:0] ewidth;

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state <= IDLE;
        vpu_ack <= 0;
        vec_ops <= 0;
    end else begin
        case (state)
            IDLE: begin
                if (vpu_req) begin
                    current_vl <= vl;
                    ewidth <= vtype[2:0];
                    state <= DECODE;
                end
            end
            
            DECODE: begin
                state <= EXECUTE;
            end
            
            EXECUTE: begin
                case (vpu_instr[6:0])
                    7'b1010111: begin // Vector OP
                        case (vpu_instr[31:26])
                            6'b000000: begin // VADD
                                for (int i = 0; i < VLEN/64; i++) begin
                                    vpu_result[i*64 +: 64] <= vs1_val[i*64 +: 64] + vs2_val[i*64 +: 64];
                                end
                                vec_ops <= vec_ops + (current_vl * (1 << ewidth) / 8);
                            end
                            6'b000110: begin // VMUL
                                for (int i = 0; i < VLEN/64; i++) begin
                                    vpu_result[i*64 +: 64] <= vs1_val[i*64 +: 64] * vs2_val[i*64 +: 64];
                                end
                                vec_ops <= vec_ops + (current_vl * (1 << ewidth) / 8);
                            end
                            // ... other vector ops
                        endcase
                        state <= WRITEBACK;
                    end
                    7'b0000111, 7'b0100111: begin // Vector load/store
                        vmem_addr <= rs1_val;
                        vmem_we <= vpu_instr[5];
                        if (vpu_instr[5]) begin
                            vmem_wdata <= vs3_val; // Vector store
                        end
                        state <= MEMORY;
                    end
                endcase
            end
            
            MEMORY: begin
                if (vmem_ack) begin
                    if (!vmem_we) begin
                        vpu_result <= vmem_rdata; // Vector load
                    end
                    state <= WRITEBACK;
                end
            end
            
            WRITEBACK: begin
                vpu_ack <= 1;
                state <= IDLE;
            end
        endcase
    end
end

endmodule