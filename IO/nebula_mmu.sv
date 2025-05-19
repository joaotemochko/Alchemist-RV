module nebula_mmu #(
    parameter int VPN_SIZE = 9,
    parameter int PPN_SIZE = 26,
    parameter int XLEN = 64,
    parameter int PHYS_ADDR_SIZE = 56
) (
    input wire clk,
    input wire rst_n,
    
    // Core interface
    input wire [XLEN-1:0] vaddr,
    input wire req,
    input wire we,
    output logic [PHYS_ADDR_SIZE-1:0] paddr,
    output logic ack,
    output logic page_fault,
    
    // CSR interface
    input wire [XLEN-1:0] satp,
    input wire mxr,
    input wire sum,
    input wire spp,
    
    // Memory interface for page table walks
    output logic mem_req,
    output logic [PHYS_ADDR_SIZE-1:0] mem_addr,
    input wire [XLEN-1:0] mem_rdata,
    input wire mem_ack,
    
    // Performance counters
    output logic [31:0] tlb_misses,
    output logic [31:0] page_faults
);

localparam LEVELS = 3;
localparam PTE_SIZE = 8;

typedef struct packed {
    logic v;    // Valid
    logic r;    // Readable
    logic w;    // Writable
    logic x;    // Executable
    logic u;    // User accessible
    logic g;    // Global mapping
    logic a;    // Accessed
    logic d;    // Dirty
    logic [PPN_SIZE-1:0] ppn; // Physical page number
} pte_t;

// TLB Entry
typedef struct packed {
    logic [VPN_SIZE*LEVELS-1:0] vpn;
    pte_t pte;
    logic valid;
} tlb_entry_t;

localparam TLB_ENTRIES = 32;
tlb_entry_t tlb [0:TLB_ENTRIES-1];
logic [TLB_ENTRIES-1:0] tlb_lru;

// Page table walk state machine
enum logic [2:0] {
    IDLE,
    LEVEL2_WALK,
    LEVEL1_WALK,
    LEVEL0_WALK,
    WAIT_MEM,
    CHECK_PTE,
    FAULT
} state, next_state;

logic [VPN_SIZE*LEVELS-1:0] vpn;
logic [1:0] a_level;
logic [XLEN-1:0] pte;
logic [PHYS_ADDR_SIZE-1:0] root_ppn;

// Extract VPN from virtual address
assign vpn = vaddr[30:12];

// TLB lookup
always_comb begin
    paddr = '0;
    page_fault = 0;
    ack = 0;
    
    for (int i = 0; i < TLB_ENTRIES; i++) begin
        if (tlb[i].valid && tlb[i].vpn == vpn) begin
            // Check permissions
            if ((we && !tlb[i].pte.w) || 
                (!we && !tlb[i].pte.r && !(tlb[i].pte.x && mxr)) ||
                (spp && tlb[i].pte.u) || // Supervisor accessing user page
                (!spp && !tlb[i].pte.u && !sum)) begin // User accessing supervisor page
                page_fault = 1;
            end else begin
                paddr = {tlb[i].pte.ppn, vaddr[11:0]};
                ack = req;
            end
            break;
        end
    end
end

// Page table walker
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state <= IDLE;
        tlb_misses <= 0;
        page_faults <= 0;
        tlb <= '{default:0};
        tlb_lru <= '0;
    end else begin
        state <= next_state;
        
        if (state == IDLE && req && !ack) begin
            tlb_misses <= tlb_misses + 1;
        end
        
        if (state == FAULT) begin
            page_faults <= page_faults + 1;
        end
    end
end

always_comb begin
    next_state = state;
    mem_req = 0;
    mem_addr = '0;
    root_ppn = satp[PHYS_ADDR_SIZE-1:0];
    
    case (state)
        IDLE: begin
            if (req && !ack) begin
                next_state = LEVEL2_WALK;
            end
        end
        
        LEVEL2_WALK: begin
            mem_addr = {root_ppn, vpn[VPN_SIZE*2 +: VPN_SIZE], 3'b000};
            mem_req = 1;
            next_state = WAIT_MEM;
            a_level = 2;
        end
        
        LEVEL1_WALK: begin
            mem_addr = {pte[PPN_SIZE-1:0], vpn[VPN_SIZE*1 +: VPN_SIZE], 3'b000};
            mem_req = 1;
            next_state = WAIT_MEM;
            a_level = 1;
        end
        
        LEVEL0_WALK: begin
            mem_addr = {pte[PPN_SIZE-1:0], vpn[VPN_SIZE*0 +: VPN_SIZE], 3'b000};
            mem_req = 1;
            next_state = WAIT_MEM;
            a_level = 0;
        end
        
        WAIT_MEM: begin
            if (mem_ack) begin
                pte = mem_rdata;
                next_state = CHECK_PTE;
            end
        end
        
        CHECK_PTE: begin
            if (!pte.v || (!pte.r && pte.w)) begin
                next_state = FAULT;
            end else if (pte.r || pte.x) begin
                // Leaf PTE found
                // Update TLB
                next_state = IDLE;
            end else begin
                // Continue walking
                case (a_level)
                    2: next_state = LEVEL1_WALK;
                    1: next_state = LEVEL0_WALK;
                    default: next_state = FAULT;
                endcase
            end
        end
        
        FAULT: begin
            next_state = IDLE;
        end
    endcase
end

// TLB update logic
always_ff @(posedge clk) begin
    if (state == CHECK_PTE && (pte.r || pte.x)) begin
        // Find LRU entry
        automatic int lru_entry = 0;
        for (int i = 0; i < TLB_ENTRIES; i++) begin
            if (tlb_lru[i] < tlb_lru[lru_entry]) begin
                lru_entry = i;
            end
        end
        
        // Update TLB
        tlb[lru_entry].vpn <= vpn;
        tlb[lru_entry].pte <= pte;
        tlb[lru_entry].valid <= 1;
        
        // Update LRU counters
        for (int i = 0; i < TLB_ENTRIES; i++) begin
            if (i == lru_entry) begin
                tlb_lru[i] <= TLB_ENTRIES-1;
            end else if (tlb_lru[i] > 0) begin
                tlb_lru[i] <= tlb_lru[i] - 1;
            end
        end
    end
end

endmodule