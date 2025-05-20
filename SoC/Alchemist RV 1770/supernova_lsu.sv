module supernova_lsu #(
    parameter int LQ_ENTRIES = 32,
    parameter int SQ_ENTRIES = 32,
    parameter int XLEN = 64,
    parameter int PHYS_ADDR_SIZE = 56
) (
    input wire clk,
    input wire rst_n,
    
    // Core interface
    input wire lsu_req,
    input wire lsu_we,
    input wire [XLEN-1:0] lsu_addr,
    input wire [XLEN-1:0] lsu_wdata,
    input wire [7:0] lsu_wstrb,
    input wire [4:0] lsu_rd,
    input wire [7:0] lsu_rob_idx,
    output logic lsu_ack,
    output logic [XLEN-1:0] lsu_rdata,
    
    // Memory interface
    output logic mem_req,
    output logic mem_we,
    output logic [PHYS_ADDR_SIZE-1:0] mem_addr,
    output logic [XLEN-1:0] mem_wdata,
    output logic [7:0] mem_wstrb,
    input wire [XLEN-1:0] mem_rdata,
    input wire mem_ack,
    
    // Performance counters
    output logic [63:0] load_count,
    output logic [63:0] store_count,
    output logic [63:0] mem_stall_cycles
);

// Load Queue
typedef struct packed {
    logic valid;
    logic [XLEN-1:0] addr;
    logic [4:0] rd;
    logic [7:0] rob_idx;
} lq_entry_t;

lq_entry_t lq [0:LQ_ENTRIES-1];
logic [4:0] lq_head = 0;
logic [4:0] lq_tail = 0;

// Store Queue
typedef struct packed {
    logic valid;
    logic [XLEN-1:0] addr;
    logic [XLEN-1:0] data;
    logic [7:0] wstrb;
    logic [7:0] rob_idx;
} sq_entry_t;

sq_entry_t sq [0:SQ_ENTRIES-1];
logic [4:0] sq_head = 0;
logic [4:0] sq_tail = 0;

// Memory access state machine
enum logic [1:0] {
    IDLE,
    SEND_ADDR,
    WAIT_DATA,
    COMPLETE
} state;

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state <= IDLE;
        lq <= '{default:0};
        sq <= '{default:0};
        lq_head <= 0;
        lq_tail <= 0;
        sq_head <= 0;
        sq_tail <= 0;
        load_count <= 0;
        store_count <= 0;
        mem_stall_cycles <= 0;
    end else begin
        case (state)
            IDLE: begin
                if (lq[lq_head].valid) begin
                    // Process load
                    mem_req <= 1;
                    mem_we <= 0;
                    mem_addr <= lq[lq_head].addr;
                    state <= SEND_ADDR;
                end else if (sq[sq_head].valid && sq[sq_head].rob_idx < lq[lq_head].rob_idx) begin
                    // Process store (only if older than oldest load)
                    mem_req <= 1;
                    mem_we <= 1;
                    mem_addr <= sq[sq_head].addr;
                    mem_wdata <= sq[sq_head].data;
                    mem_wstrb <= sq[sq_head].wstrb;
                    state <= SEND_ADDR;
                end
            end
            
            SEND_ADDR: begin
                if (mem_ack) begin
                    mem_req <= 0;
                    if (mem_we) begin
                        store_count <= store_count + 1;
                        state <= COMPLETE;
                    end else begin
                        state <= WAIT_DATA;
                    end
                end else begin
                    mem_stall_cycles <= mem_stall_cycles + 1;
                end
            end
            
            WAIT_DATA: begin
                lsu_rdata <= mem_rdata;
                lsu_ack <= 1;
                load_count <= load_count + 1;
                state <= COMPLETE;
            end
            
            COMPLETE: begin
                lsu_ack <= 0;
                if (mem_we) begin
                    sq[sq_head].valid <= 0;
                    sq_head <= sq_head + 1;
                end else begin
                    lq[lq_head].valid <= 0;
                    lq_head <= lq_head + 1;
                end
                state <= IDLE;
            end
        endcase
        
        // Allocate new entries
        if (lsu_req && !lsu_we && lq_tail + 1 != lq_head) begin // Load
            lq[lq_tail].valid <= 1;
            lq[lq_tail].addr <= lsu_addr;
            lq[lq_tail].rd <= lsu_rd;
            lq[lq_tail].rob_idx <= lsu_rob_idx;
            lq_tail <= lq_tail + 1;
        end else if (lsu_req && lsu_we && sq_tail + 1 != sq_head) begin // Store
            sq[sq_tail].valid <= 1;
            sq[sq_tail].addr <= lsu_addr;
            sq[sq_tail].data <= lsu_wdata;
            sq[sq_tail].wstrb <= lsu_wstrb;
            sq[sq_tail].rob_idx <= lsu_rob_idx;
            sq_tail <= sq_tail + 1;
        end
    end
end

endmodule