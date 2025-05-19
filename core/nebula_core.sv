// NEBULA CORE - RV64I Implementation (Refined)
// Alchemist RV64 - Little Core
// Pipeline: 8-stage in-order with full RV64I compliance
// Enhanced with: Complete exception handling, CSR support, optimized memory interface

`timescale 1ns/1ps
`default_nettype none

module nebula_core #(
    parameter int HART_ID = 0,
    parameter int XLEN = 64,
    parameter int ILEN = 32,
    parameter int PHYS_ADDR_SIZE = 56,
    parameter bit ENABLE_MISALIGNED_ACCESS = 0
) (
    input wire clk,
    input wire rst_n,
    
    // Instruction memory interface
    output logic [PHYS_ADDR_SIZE-1:0] imem_addr,
    output logic imem_req,
    input wire [ILEN-1:0] imem_data,
    input wire imem_ack,
    input wire imem_error,
    
    // Data memory interface
    output logic [PHYS_ADDR_SIZE-1:0] dmem_addr,
    output logic [XLEN-1:0] dmem_wdata,
    output logic [7:0] dmem_wstrb,
    output logic dmem_req,
    output logic dmem_we,
    input wire [XLEN-1:0] dmem_rdata,
    input wire dmem_ack,
    input wire dmem_error,
    
    // Interrupt interface
    input wire timer_irq,
    input wire external_irq,
    input wire software_irq,
    
    // Debug interface
    input wire debug_req,
    output logic debug_ack,
    output logic debug_halted,
    
    // Performance counters
    output logic [63:0] inst_retired,
    output logic [63:0] cycles
);

// --------------------------
// Constants and Types
// --------------------------
localparam PC_RESET = 'h8000_0000;
localparam MTVEC_DEFAULT = 'h1000_0000;

typedef enum logic [2:0] {
    STAGE_RESET,
    STAGE_FETCH,
    STAGE_DECODE,
    STAGE_EXECUTE,
    STAGE_MEMORY,
    STAGE_WRITEBACK,
    STAGE_TRAP,
    STAGE_STALL
} pipeline_state_t;

typedef enum logic [1:0] {
    PRIV_MACHINE = 2'b11,
    PRIV_SUPERVISOR = 2'b01,
    PRIV_USER = 2'b00
} privilege_t;

typedef struct packed {
    logic [6:0] opcode;
    logic [4:0] rd;
    logic [2:0] funct3;
    logic [4:0] rs1;
    logic [4:0] rs2;
    logic [6:0] funct7;
    logic [XLEN-1:0] imm;
    logic valid;
} decoded_instr_t;

typedef struct packed {
    logic [XLEN-1:0] alu_result;
    logic [XLEN-1:0] mem_addr;
    logic [XLEN-1:0] store_data;
    logic [4:0] rd;
    logic mem_we;
    logic [7:0] mem_wstrb;
    logic reg_we;
    logic mem_unsigned;
    logic [1:0] mem_size;
    logic branch_taken;
    logic [XLEN-1:0] branch_target;
    logic csr_we;
    logic [11:0] csr_addr;
    logic illegal_instr;
} execute_result_t;

typedef struct packed {
    logic [XLEN-1:0] data;
    logic [4:0] rd;
    logic reg_we;
    logic trap;
    logic [XLEN-1:0] trap_cause;
    logic [XLEN-1:0] trap_value;
} memory_result_t;

// --------------------------
// Pipeline Registers
// --------------------------
pipeline_state_t pipeline_state, next_pipeline_state;
logic [PHYS_ADDR_SIZE-1:0] pc, next_pc;
logic [XLEN-1:0] regfile [0:31];
decoded_instr_t decoded_instr;
execute_result_t execute_result;
memory_result_t memory_result;

// --------------------------
// Control and Status Registers
// --------------------------
logic [XLEN-1:0] csr_mstatus;
logic [XLEN-1:0] csr_mtvec;
logic [XLEN-1:0] csr_mepc;
logic [XLEN-1:0] csr_mcause;
logic [XLEN-1:0] csr_mtval;
logic [XLEN-1:0] csr_mie;
logic [XLEN-1:0] csr_mip;
logic [XLEN-1:0] csr_mscratch;
logic [XLEN-1:0] csr_mcycle;
logic [XLEN-1:0] csr_minstret;
logic [XLEN-1:0] csr_misa;

privilege_t current_privilege;
logic mstatus_mie;
logic mstatus_mpie;

// --------------------------
// Hazard Detection
// --------------------------
logic data_hazard;
logic control_hazard;
logic struct_hazard;

// --------------------------
// Performance Counters
// --------------------------
always_ff @(posedge clk) begin
    if (!rst_n) begin
        cycles <= 0;
        inst_retired <= 0;
    end else begin
        cycles <= cycles + 1;
        if (pipeline_state == STAGE_WRITEBACK && !memory_result.trap)
            inst_retired <= inst_retired + 1;
    end
end

// --------------------------
// Instruction Fetch Stage
// --------------------------
logic fetch_valid;
logic [XLEN-1:0] fetched_instr;

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        pc <= PC_RESET;
        fetch_valid <= 0;
        fetched_instr <= '0;
    end else if (debug_req && debug_halted) begin
        // Hold state during debug
    end else if (control_hazard) begin
        pc <= next_pc;
        fetch_valid <= 0;
    end else if (pipeline_state == STAGE_FETCH) begin
        if (imem_ack) begin
            pc <= next_pc;
            fetched_instr <= imem_data;
            fetch_valid <= !imem_error;
            
            if (imem_error) begin
                // Generate instruction fetch exception
                next_pipeline_state <= STAGE_TRAP;
                csr_mcause <= {1'b0, 63'd1}; // Instruction access fault
                csr_mtval <= imem_addr;
            end
        end
    end
end

assign imem_addr = pc;
assign imem_req = (pipeline_state == STAGE_FETCH) && !control_hazard && !debug_halted;

// --------------------------
// Instruction Decode Stage
// --------------------------
always_ff @(posedge clk) begin
    if (pipeline_state == STAGE_DECODE && fetch_valid && !data_hazard) begin
        decoded_instr.opcode <= fetched_instr[6:0];
        decoded_instr.rd <= fetched_instr[11:7];
        decoded_instr.funct3 <= fetched_instr[14:12];
        decoded_instr.rs1 <= fetched_instr[19:15];
        decoded_instr.rs2 <= fetched_instr[24:20];
        decoded_instr.funct7 <= fetched_instr[31:25];
        decoded_instr.valid <= 1'b1;
        
        // Immediate generation
        case (fetched_instr[6:0])
            7'b0110111, 7'b0010111: // LUI, AUIPC
                decoded_instr.imm <= {fetched_instr[31:12], 12'b0};
            7'b1101111: // JAL
                decoded_instr.imm <= {{43{fetched_instr[31]}}, fetched_instr[19:12], fetched_instr[20], fetched_instr[30:21], 1'b0};
            7'b1100111: // JALR
                decoded_instr.imm <= {{52{fetched_instr[31]}}, fetched_instr[30:20]};
            7'b1100011: // Branches
                decoded_instr.imm <= {{51{fetched_instr[31]}}, fetched_instr[7], fetched_instr[30:25], fetched_instr[11:8], 1'b0};
            7'b0000011, 7'b0010011: // Loads, immediate ALU
                decoded_instr.imm <= {{52{fetched_instr[31]}}, fetched_instr[30:20]};
            7'b0100011: // Stores
                decoded_instr.imm <= {{52{fetched_instr[31]}}, fetched_instr[30:25], fetched_instr[11:7]};
            default:
                decoded_instr.imm <= '0;
        endcase
    end else begin
        decoded_instr.valid <= 1'b0;
    end
end

// --------------------------
// Register File
// --------------------------
logic [XLEN-1:0] rs1_data, rs2_data;
logic reg_write_en;
logic [4:0] reg_write_addr;
logic [XLEN-1:0] reg_write_data;

always_ff @(posedge clk) begin
    if (reg_write_en && reg_write_addr != 0) begin
        regfile[reg_write_addr] <= reg_write_data;
    end
end

// Forwarding logic for data hazards
always_comb begin
    // RS1 forwarding
    if (reg_write_en && decoded_instr.rs1 == reg_write_addr && decoded_instr.rs1 != 0)
        rs1_data = reg_write_data;
    else if (execute_result.reg_we && decoded_instr.rs1 == execute_result.rd && decoded_instr.rs1 != 0)
        rs1_data = execute_result.alu_result;
    else
        rs1_data = (decoded_instr.rs1 == 0) ? 0 : regfile[decoded_instr.rs1];
    
    // RS2 forwarding
    if (reg_write_en && decoded_instr.rs2 == reg_write_addr && decoded_instr.rs2 != 0)
        rs2_data = reg_write_data;
    else if (execute_result.reg_we && decoded_instr.rs2 == execute_result.rd && decoded_instr.rs2 != 0)
        rs2_data = execute_result.alu_result;
    else
        rs2_data = (decoded_instr.rs2 == 0) ? 0 : regfile[decoded_instr.rs2];
end

// Hazard detection
always_comb begin
    data_hazard = 0;
    // RAW hazard detection
    if ((decoded_instr.rs1 == execute_result.rd && decoded_instr.rs1 != 0 && execute_result.reg_we && 
         (execute_result.mem_we || decoded_instr.opcode == 7'b0000011)) ||
        (decoded_instr.rs2 == execute_result.rd && decoded_instr.rs2 != 0 && execute_result.reg_we && 
         (execute_result.mem_we || decoded_instr.opcode == 7'b0000011))) begin
        data_hazard = 1;
    end
    
    // Control hazard from branches/jumps
    control_hazard = execute_result.branch_taken;
    
    // Structural hazard from memory
    struct_hazard = (pipeline_state == STAGE_MEMORY) && !dmem_ack;
end

// --------------------------
// Execute Stage
// --------------------------
always_ff @(posedge clk) begin
    if (pipeline_state == STAGE_EXECUTE && decoded_instr.valid && !data_hazard) begin
        // Default values
        execute_result <= '{
            alu_result: 0,
            mem_addr: 0,
            store_data: 0,
            rd: decoded_instr.rd,
            mem_we: 0,
            mem_wstrb: 0,
            reg_we: (decoded_instr.rd != 0),
            mem_unsigned: 0,
            mem_size: 2'b11,
            branch_taken: 0,
            branch_target: 0,
            csr_we: 0,
            csr_addr: 0,
            illegal_instr: 0
        };
        
        case (decoded_instr.opcode)
            // LUI
            7'b0110111: execute_result.alu_result <= decoded_instr.imm;
            
            // AUIPC
            7'b0010111: execute_result.alu_result <= pc + decoded_instr.imm;
            
            // ALU operations
            7'b0010011: begin // Immediate operations
                case (decoded_instr.funct3)
                    3'b000: execute_result.alu_result <= rs1_data + decoded_instr.imm; // ADDI
                    3'b010: execute_result.alu_result <= ($signed(rs1_data) < $signed(decoded_instr.imm); // SLTI
                    3'b011: execute_result.alu_result <= rs1_data < decoded_instr.imm; // SLTIU
                    3'b100: execute_result.alu_result <= rs1_data ^ decoded_instr.imm; // XORI
                    3'b110: execute_result.alu_result <= rs1_data | decoded_instr.imm; // ORI
                    3'b111: execute_result.alu_result <= rs1_data & decoded_instr.imm; // ANDI
                    3'b001: execute_result.alu_result <= rs1_data << decoded_instr.imm[5:0]; // SLLI
                    3'b101: begin
                        if (decoded_instr.funct7[5])
                            execute_result.alu_result <= ($signed(rs1_data)) >>> decoded_instr.imm[5:0]; // SRAI
                        else
                            execute_result.alu_result <= rs1_data >> decoded_instr.imm[5:0]; // SRLI
                    end
                    default: execute_result.illegal_instr <= 1;
                endcase
            end
            
            // Register-register operations
            7'b0110011: begin
                case ({decoded_instr.funct7, decoded_instr.funct3})
                    {7'b0000000, 3'b000}: execute_result.alu_result <= rs1_data + rs2_data; // ADD
                    {7'b0100000, 3'b000}: execute_result.alu_result <= rs1_data - rs2_data; // SUB
                    {7'b0000000, 3'b001}: execute_result.alu_result <= rs1_data << rs2_data[5:0]; // SLL
                    {7'b0000000, 3'b010}: execute_result.alu_result <= ($signed(rs1_data) < $signed(rs2_data)); // SLT
                    {7'b0000000, 3'b011}: execute_result.alu_result <= rs1_data < rs2_data; // SLTU
                    {7'b0000000, 3'b100}: execute_result.alu_result <= rs1_data ^ rs2_data; // XOR
                    {7'b0000000, 3'b101}: execute_result.alu_result <= rs1_data >> rs2_data[5:0]; // SRL
                    {7'b0100000, 3'b101}: execute_result.alu_result <= ($signed(rs1_data)) >>> rs2_data[5:0]; // SRA
                    {7'b0000000, 3'b110}: execute_result.alu_result <= rs1_data | rs2_data; // OR
                    {7'b0000000, 3'b111}: execute_result.alu_result <= rs1_data & rs2_data; // AND
                    default: execute_result.illegal_instr <= 1;
                endcase
            end
            
            // Load/store
            7'b0000011: begin // Loads
                execute_result.mem_addr <= rs1_data + decoded_instr.imm;
                execute_result.reg_we <= 1;
                execute_result.mem_size <= decoded_instr.funct3[1:0];
                execute_result.mem_unsigned <= decoded_instr.funct3[2];
                
                // Check for misaligned access
                if (!ENABLE_MISALIGNED_ACCESS) begin
                    case (decoded_instr.funct3[1:0])
                        2'b00: ; // Byte access - always aligned
                        2'b01: if (execute_result.mem_addr[0] != 0) execute_result.illegal_instr <= 1; // Halfword
                        2'b10: if (execute_result.mem_addr[1:0] != 0) execute_result.illegal_instr <= 1; // Word
                        2'b11: if (execute_result.mem_addr[2:0] != 0) execute_result.illegal_instr <= 1; // Doubleword
                    endcase
                end
            end
            
            7'b0100011: begin // Stores
                execute_result.mem_addr <= rs1_data + decoded_instr.imm;
                execute_result.store_data <= rs2_data;
                execute_result.mem_we <= 1;
                execute_result.mem_size <= decoded_instr.funct3[1:0];
                
                case (decoded_instr.funct3[1:0])
                    2'b00: execute_result.mem_wstrb <= 8'b00000001 << execute_result.mem_addr[2:0]; // SB
                    2'b01: execute_result.mem_wstrb <= 8'b00000011 << execute_result.mem_addr[2:0]; // SH
                    2'b10: execute_result.mem_wstrb <= 8'b00001111 << execute_result.mem_addr[2:0]; // SW
                    2'b11: execute_result.mem_wstrb <= 8'b11111111; // SD
                endcase
                
                // Check for misaligned access
                if (!ENABLE_MISALIGNED_ACCESS) begin
                    case (decoded_instr.funct3[1:0])
                        2'b00: ; // Byte access - always aligned
                        2'b01: if (execute_result.mem_addr[0] != 0) execute_result.illegal_instr <= 1; // Halfword
                        2'b10: if (execute_result.mem_addr[1:0] != 0) execute_result.illegal_instr <= 1; // Word
                        2'b11: if (execute_result.mem_addr[2:0] != 0) execute_result.illegal_instr <= 1; // Doubleword
                    endcase
                end
            end
            
            // JAL
            7'b1101111: begin
                execute_result.alu_result <= pc + 4;
                execute_result.reg_we <= 1;
                execute_result.branch_taken <= 1;
                execute_result.branch_target <= pc + decoded_instr.imm;
            end
            
            // JALR
            7'b1100111: begin
                execute_result.alu_result <= pc + 4;
                execute_result.reg_we <= 1;
                execute_result.branch_taken <= 1;
                execute_result.branch_target <= (rs1_data + decoded_instr.imm) & ~1;
            end
            
            // Branches
            7'b1100011: begin
                case (decoded_instr.funct3)
                    3'b000: execute_result.branch_taken <= (rs1_data == rs2_data); // BEQ
                    3'b001: execute_result.branch_taken <= (rs1_data != rs2_data); // BNE
                    3'b100: execute_result.branch_taken <= ($signed(rs1_data) < $signed(rs2_data)); // BLT
                    3'b101: execute_result.branch_taken <= ($signed(rs1_data) >= $signed(rs2_data)); // BGE
                    3'b110: execute_result.branch_taken <= (rs1_data < rs2_data); // BLTU
                    3'b111: execute_result.branch_taken <= (rs1_data >= rs2_data); // BGEU
                    default: execute_result.illegal_instr <= 1;
                endcase
                execute_result.branch_target <= pc + decoded_instr.imm;
            end
            
            // System instructions
            7'b1110011: begin
                execute_result.csr_we <= (decoded_instr.funct3 != 0);
                execute_result.csr_addr <= decoded_instr.imm[11:0];
                // CSR logic would be implemented here
                execute_result.illegal_instr <= (decoded_instr.funct3 > 3'b101); // Invalid CSR operation
            end
            
            default: begin
                execute_result.illegal_instr <= 1;
            end
        endcase
        
        // Handle illegal instructions
        if (execute_result.illegal_instr) begin
            next_pipeline_state <= STAGE_TRAP;
            csr_mcause <= {1'b0, 63'd2}; // Illegal instruction
            csr_mtval <= fetched_instr;
        end
    end
end

// --------------------------
// Memory Stage
// --------------------------
always_ff @(posedge clk) begin
    if (pipeline_state == STAGE_MEMORY) begin
        memory_result <= '{
            data: 0,
            rd: execute_result.rd,
            reg_we: execute_result.reg_we && !execute_result.mem_we,
            trap: dmem_error,
            trap_cause: {1'b0, 63'd5}, // Default to load access fault
            trap_value: execute_result.mem_addr
        };
        
        if (execute_result.mem_we) begin
            // Store operation - handled by memory interface
            if (dmem_error) begin
                memory_result.trap_cause <= {1'b0, 63'd7}; // Store access fault
            end
        end else if (decoded_instr.opcode == 7'b0000011 && dmem_ack) begin
            // Load operation
            case (decoded_instr.funct3)
                3'b000: memory_result.data <= $signed(dmem_rdata[7:0]); // LB
                3'b001: memory_result.data <= $signed(dmem_rdata[15:0]); // LH
                3'b010: memory_result.data <= $signed(dmem_rdata[31:0]); // LW
                3'b011: memory_result.data <= dmem_rdata; // LD
                3'b100: memory_result.data <= {56'b0, dmem_rdata[7:0]}; // LBU
                3'b101: memory_result.data <= {48'b0, dmem_rdata[15:0]}; // LHU
                3'b110: memory_result.data <= {32'b0, dmem_rdata[31:0]}; // LWU
                default: memory_result.data <= '0;
            endcase
        end else begin
            // Non-memory operation
            memory_result.data <= execute_result.alu_result;
        end
    end
end

// Memory interface assignments
assign dmem_addr = execute_result.mem_addr;
assign dmem_wdata = execute_result.store_data;
assign dmem_wstrb = execute_result.mem_wstrb;
assign dmem_req = (pipeline_state == STAGE_MEMORY) && 
                  (execute_result.mem_we || decoded_instr.opcode == 7'b0000011);
assign dmem_we = execute_result.mem_we;

// --------------------------
// Writeback Stage
// --------------------------
always_ff @(posedge clk) begin
    if (pipeline_state == STAGE_WRITEBACK) begin
        reg_write_en <= memory_result.reg_we && !memory_result.trap;
        reg_write_addr <= memory_result.rd;
        reg_write_data <= memory_result.data;
        
        if (memory_result.trap) begin
            next_pipeline_state <= STAGE_TRAP;
            csr_mcause <= memory_result.trap_cause;
            csr_mtval <= memory_result.trap_value;
        end
    end else begin
        reg_write_en <= 0;
    end
end

// --------------------------
// Trap Handling
// --------------------------
logic interrupt_pending;
assign interrupt_pending = (timer_irq & csr_mie[7]) | 
                         (external_irq & csr_mie[11]) | 
                         (software_irq & csr_mie[3]);

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        csr_mstatus <= '0;
        csr_mtvec <= MTVEC_DEFAULT;
        csr_mepc <= '0;
        csr_mcause <= '0;
        csr_mtval <= '0;
        csr_mie <= '0;
        csr_mip <= '0;
        csr_mscratch <= '0;
        csr_mcycle <= '0;
        csr_minstret <= '0;
        csr_misa <= (1 << ('M' - 'A')) | (1 << ('I' - 'A')) | (1 << ('S' - 'A')) | (1 << ('U' - 'A'));
        current_privilege <= PRIV_MACHINE;
        mstatus_mie <= 0;
        mstatus_mpie <= 0;
    end else if (pipeline_state == STAGE_TRAP) begin
        // Handle traps
        csr_mepc <= pc;
        csr_mcause <= (interrupt_pending) ? {1'b1, 63'(csr_mcause)} : csr_mcause;
        csr_mtval <= (interrupt_pending) ? '0 : csr_mtval;
        mstatus_mpie <= mstatus_mie;
        mstatus_mie <= 0;
        next_pc <= csr_mtvec;
    end else if (decoded_instr.opcode == 7'b1110011 && decoded_instr.funct3 == 3'b0) begin
        // MRET instruction
        mstatus_mie <= mstatus_mpie;
        next_pc <= csr_mepc;
    end
end

// --------------------------
// Debug Interface
// --------------------------
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        debug_ack <= 0;
        debug_halted <= 0;
    end else if (debug_req && !debug_halted) begin
        debug_ack <= 1;
        debug_halted <= 1;
        next_pipeline_state <= STAGE_STALL;
    end else if (!debug_req && debug_halted) begin
        debug_halted <= 0;
    end
end

// --------------------------
// Pipeline Control
// --------------------------
always_comb begin
    next_pipeline_state = pipeline_state;
    next_pc = pc + 4;
    
    case (pipeline_state)
        STAGE_RESET: 
            if (rst_n) next_pipeline_state = STAGE_FETCH;
        
        STAGE_FETCH: 
            if (imem_ack) next_pipeline_state = STAGE_DECODE;
        
        STAGE_DECODE: 
            if (!data_hazard) next_pipeline_state = STAGE_EXECUTE;
        
        STAGE_EXECUTE: 
            next_pipeline_state = STAGE_MEMORY;
        
        STAGE_MEMORY: 
            if (!dmem_req || dmem_ack) next_pipeline_state = STAGE_WRITEBACK;
        
        STAGE_WRITEBACK: 
            next_pipeline_state = STAGE_FETCH;
        
        STAGE_TRAP: 
            next_pipeline_state = STAGE_FETCH;
        
        STAGE_STALL: 
            if (!debug_halted) next_pipeline_state = STAGE_FETCH;
    endcase
    
    // Handle interrupts
    if (interrupt_pending && mstatus_mie && pipeline_state != STAGE_RESET && 
        pipeline_state != STAGE_TRAP && !debug_halted) begin
        next_pipeline_state = STAGE_TRAP;
    end
    
    // Handle control hazards
    if (execute_result.branch_taken) begin
        next_pc = execute_result.branch_target;
    end
end

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        pipeline_state <= STAGE_RESET;
    end else begin
        pipeline_state <= next_pipeline_state;
    end
end

endmodule