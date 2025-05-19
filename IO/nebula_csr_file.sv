module nebula_csr_file #(
    parameter int HART_ID = 0,
    parameter int XLEN = 64
) (
    input wire clk,
    input wire rst_n,
    
    // Core interface
    input wire [11:0] csr_addr,
    input wire csr_we,
    input wire [XLEN-1:0] csr_wdata,
    input wire [1:0] csr_op,
    output logic [XLEN-1:0] csr_rdata,
    
    // Trap interface
    input wire trap,
    input wire [XLEN-1:0] trap_cause,
    input wire [XLEN-1:0] trap_pc,
    input wire [XLEN-1:0] trap_value,
    output logic [XLEN-1:0] mtvec,
    output logic [XLEN-1:0] mepc,
    output logic [XLEN-1:0] mscratch,
    
    // Interrupt interface
    output logic mie,
    input wire [XLEN-1:0] mip,
    
    // Privilege mode
    output logic [1:0] privilege_mode,
    
    // Debug interface
    input wire debug_mode,
    output logic [XLEN-1:0] dpc,
    output logic [XLEN-1:0] dscratch
);

// Machine Information Registers
logic [XLEN-1:0] mvendorid = '0;  // Implementation-defined vendor ID
logic [XLEN-1:0] marchid = '0;    // Architecture ID
logic [XLEN-1:0] mimpid = '0;     // Implementation ID
logic [XLEN-1:0] mhartid = HART_ID;

// Machine Trap Setup
logic [XLEN-1:0] mstatus;
logic [XLEN-1:0] misa;
logic [XLEN-1:0] medeleg = '0;    // Exception delegation
logic [XLEN-1:0] mideleg = '0;    // Interrupt delegation

// Machine Trap Handling
logic [XLEN-1:0] mip_reg;
logic [XLEN-1:0] mie_reg;
logic [XLEN-1:0] mtvec_reg;
logic [XLEN-1:0] mscratch_reg;
logic [XLEN-1:0] mepc_reg;
logic [XLEN-1:0] mcause;
logic [XLEN-1:0] mtval;
logic [XLEN-1:0] mcounteren = '0;

// Machine Configuration
logic [XLEN-1:0] menvcfg = '0;

// Machine Counters/Timers
logic [XLEN-1:0] mcycle;
logic [XLEN-1:0] minstret;
logic [XLEN-1:0] mhpmcounter[3:0]; // Up to 4 hardware performance counters

// Debug/Trace Registers
logic [XLEN-1:0] tselect = '0;
logic [XLEN-1:0] tdata1 = '0;
logic [XLEN-1:0] tdata2 = '0;
logic [XLEN-1:0] tdata3 = '0;
logic [XLEN-1:0] dcsr;
logic [XLEN-1:0] dpc_reg;
logic [XLEN-1:0] dscratch_reg;

// CSR read/write logic
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        // Initialize CSRs
        mstatus <= '0;
        misa <= (1 << ('M' - 'A')) | (1 << ('I' - 'A')) | (1 << ('S' - 'A')) | (1 << ('U' - 'A'));
        mtvec_reg <= 'h1000_0000;
        mie_reg <= '0;
        mscratch_reg <= '0;
        privilege_mode <= 2'b11; // Start in Machine mode
        
        // Debug CSRs
        dcsr <= '0;
        dpc_reg <= '0;
        dscratch_reg <= '0;
    end else begin
        // CSR write operations
        if (csr_we && !debug_mode) begin
            case (csr_addr)
                // Machine Trap Setup
                12'h300: mstatus <= csr_wdata;
                12'h301: misa <= csr_wdata;
                12'h302: medeleg <= csr_wdata;
                12'h303: mideleg <= csr_wdata;
                12'h304: mie_reg <= csr_wdata;
                12'h305: mtvec_reg <= {csr_wdata[XLEN-1:2], 2'b00};
                12'h306: mcounteren <= csr_wdata;
                
                // Machine Trap Handling
                12'h340: mscratch_reg <= csr_wdata;
                12'h341: mepc_reg <= {csr_wdata[XLEN-1:1], 1'b0};
                12'h342: mcause <= csr_wdata;
                12'h343: mtval <= csr_wdata;
                
                // Machine Configuration
                12'h30A: menvcfg <= csr_wdata;
                
                // Debug/Trace
                12'h7A0: dcsr <= csr_wdata;
                12'h7A1: dpc_reg <= {csr_wdata[XLEN-1:1], 1'b0};
                12'h7A2: dscratch_reg <= csr_wdata;
            endcase
        end
        
        // Handle traps
        if (trap && !debug_mode) begin
            mstatus[7] <= mstatus[3]; // MPIE = MIE
            mstatus[3] <= 0;          // MIE = 0
            mstatus[12:11] <= privilege_mode; // MPP
            
            mepc_reg <= trap_pc;
            mcause <= trap_cause;
            mtval <= trap_value;
            
            privilege_mode <= 2'b11; // Enter Machine mode
        end
        
        // Handle debug entry
        if (debug_mode) begin
            dcsr[31:28] <= 4'h4; // Debug cause
            dpc_reg <= trap_pc;
            privilege_mode <= 2'b11; // Enter Machine mode
        end
        
        // Update counters
        mcycle <= mcycle + 1;
    end
end

// CSR read operations
always_comb begin
    csr_rdata = '0;
    
    if (debug_mode) begin
        case (csr_addr)
            12'h7A0: csr_rdata = dcsr;
            12'h7A1: csr_rdata = dpc_reg;
            12'h7A2: csr_rdata = dscratch_reg;
            default: csr_rdata = '0;
        endcase
    end else begin
        case (csr_addr)
            // Machine Information Registers
            12'hF11: csr_rdata = mvendorid;
            12'hF12: csr_rdata = marchid;
            12'hF13: csr_rdata = mimpid;
            12'hF14: csr_rdata = mhartid;
            
            // Machine Trap Setup
            12'h300: csr_rdata = mstatus;
            12'h301: csr_rdata = misa;
            12'h302: csr_rdata = medeleg;
            12'h303: csr_rdata = mideleg;
            12'h304: csr_rdata = mie_reg;
            12'h305: csr_rdata = mtvec_reg;
            12'h306: csr_rdata = mcounteren;
            
            // Machine Trap Handling
            12'h340: csr_rdata = mscratch_reg;
            12'h341: csr_rdata = mepc_reg;
            12'h342: csr_rdata = mcause;
            12'h343: csr_rdata = mtval;
            
            // Machine Configuration
            12'h30A: csr_rdata = menvcfg;
            
            // Machine Counters/Timers
            12'hB00: csr_rdata = mcycle[XLEN-1:0];
            12'hB02: csr_rdata = minstret[XLEN-1:0];
            12'hB03, 12'hB04, 12'hB05, 12'hB06: 
                csr_rdata = mhpmcounter[csr_addr[3:0] - 12'hB03][XLEN-1:0];
            
            // Debug/Trace
            12'h7A0: csr_rdata = dcsr;
            12'h7A1: csr_rdata = dpc_reg;
            12'h7A2: csr_rdata = dscratch_reg;
            
            default: csr_rdata = '0;
        endcase
    end
end

// Output assignments
assign mtvec = mtvec_reg;
assign mepc = mepc_reg;
assign mscratch = mscratch_reg;
assign mie = mstatus[3]; // MIE bit
assign dpc = dpc_reg;
assign dscratch = dscratch_reg;

endmodule