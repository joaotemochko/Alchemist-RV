module supernova_l1_cache #(
    parameter int SIZE = 65536,
    parameter int LINE_SIZE = 64,
    parameter int ASSOCIATIVITY = 8,
    parameter int PHYS_ADDR_SIZE = 56
) (
    input wire clk,
    input wire rst_n,
    
    // Core interface
    input wire core_req,
    input wire core_we,
    input wire [PHYS_ADDR_SIZE-1:0] core_addr,
    input wire [LINE_SIZE-1:0] core_wdata,
    input wire [(LINE_SIZE/8)-1:0] core_wstrb,
    output logic core_ack,
    output logic [LINE_SIZE-1:0] core_rdata,
    
    // Memory interface
    output logic mem_req,
    output logic mem_we,
    output logic [PHYS_ADDR_SIZE-1:0] mem_addr,
    output logic [LINE_SIZE-1:0] mem_wdata,
    input wire [LINE_SIZE-1:0] mem_rdata,
    input wire mem_ack,
    
    // Performance counters
    output logic [31:0] hit_count,
    output logic [31:0] miss_count,
    output logic [31:0] writebacks
);

localparam OFFSET_BITS = $clog2(LINE_SIZE);
localparam INDEX_BITS = $clog2(SIZE/(ASSOCIATIVITY*LINE_SIZE));
localparam TAG_BITS = PHYS_ADDR_SIZE - OFFSET_BITS - INDEX_BITS;

typedef struct packed {
    logic valid;
    logic dirty;
    logic [TAG_BITS-1:0] tag;
    logic [LINE_SIZE-1:0] data;
    logic [ASSOCIATIVITY-1:0] lru;
} cache_line_t;

cache_line_t cache_mem [0:ASSOCIATIVITY-1][0:(1<<INDEX_BITS)-1];

// Cache controller state machine
enum logic [2:0] {
    IDLE,
    TAG_CHECK,
    READ_HIT,
    WRITE_HIT,
    ALLOCATE,
    WRITE_BACK,
    WAIT_MEM
} state;

logic [PHYS_ADDR_SIZE-1:0] saved_addr;
logic [LINE_SIZE-1:0] saved_wdata;
logic [(LINE_SIZE/8)-1:0] saved_wstrb;
logic saved_we;
logic cache_hit;
logic [ASSOCIATIVITY-1:0] hit_way;
logic [ASSOCIATIVITY-1:0] replace_way;
logic line_dirty;
logic [LINE_SIZE-1:0] line_to_write;

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state <= IDLE;
        hit_count <= 0;
        miss_count <= 0;
        writebacks <= 0;
    end else begin
        case (state)
            IDLE: begin
                if (core_req) begin
                    saved_addr <= core_addr;
                    saved_wdata <= core_wdata;
                    saved_wstrb <= core_wstrb;
                    saved_we <= core_we;
                    state <= TAG_CHECK;
                end
            end
            
            TAG_CHECK: begin
                if (cache_hit) begin
                    if (saved_we)
                        state <= WRITE_HIT;
                    else
                        state <= READ_HIT;
                end else begin
                    state <= ALLOCATE;
                end
            end
            
            READ_HIT: begin
                core_rdata <= cache_mem[hit_way][saved_addr[OFFSET_BITS +: INDEX_BITS]].data;
                core_ack <= 1;
                hit_count <= hit_count + 1;
                state <= IDLE;
            end
            
            WRITE_HIT: begin
                // Update appropriate bytes based on wstrb
                for (int b = 0; b < LINE_SIZE/8; b++) begin
                    if (saved_wstrb[b]) begin
                        cache_mem[hit_way][saved_addr[OFFSET_BITS +: INDEX_BITS]].data[b*8 +: 8] <= 
                            saved_wdata[b*8 +: 8];
                    end
                end
                cache_mem[hit_way][saved_addr[OFFSET_BITS +: INDEX_BITS]].dirty <= 1;
                core_ack <= 1;
                hit_count <= hit_count + 1;
                state <= IDLE;
            end
            
            ALLOCATE: begin
                // Check if we need to write back
                if (cache_mem[replace_way][saved_addr[OFFSET_BITS +: INDEX_BITS]].dirty) begin
                    state <= WRITE_BACK;
                end else begin
                    mem_req <= 1;
                    mem_addr <= {saved_addr[PHYS_ADDR_SIZE-1:OFFSET_BITS], {OFFSET_BITS{1'b0}}};
                    state <= WAIT_MEM;
                end
            end
            
            WRITE_BACK: begin
                mem_req <= 1;
                mem_we <= 1;
                mem_addr <= {cache_mem[replace_way][saved_addr[OFFSET_BITS +: INDEX_BITS]].tag, 
                            saved_addr[OFFSET_BITS +: INDEX_BITS], {OFFSET_BITS{1'b0}}};
                mem_wdata <= cache_mem[replace_way][saved_addr[OFFSET_BITS +: INDEX_BITS]].data;
                writebacks <= writebacks + 1;
                state <= WAIT_MEM;
            end
            
            WAIT_MEM: begin
                if (mem_ack) begin
                    mem_req <= 0;
                    if (!mem_we) begin
                        // Allocate new line
                        cache_mem[replace_way][saved_addr[OFFSET_BITS +: INDEX_BITS]].valid <= 1;
                        cache_mem[replace_way][saved_addr[OFFSET_BITS +: INDEX_BITS]].dirty <= 0;
                        cache_mem[replace_way][saved_addr[OFFSET_BITS +: INDEX_BITS]].tag <= 
                            saved_addr[PHYS_ADDR_SIZE-1:OFFSET_BITS + INDEX_BITS];
                        cache_mem[replace_way][saved_addr[OFFSET_BITS +: INDEX_BITS]].data <= mem_rdata;
                    end
                    miss_count <= miss_count + 1;
                    state <= TAG_CHECK;
                end
            end
        endcase
    end
end

// Cache access logic
always_comb begin
    automatic logic [INDEX_BITS-1:0] index = saved_addr[OFFSET_BITS +: INDEX_BITS];
    automatic logic [TAG_BITS-1:0] tag = saved_addr[OFFSET_BITS + INDEX_BITS +: TAG_BITS];
    
    cache_hit = 0;
    hit_way = 0;
    line_dirty = 0;
    
    for (int i = 0; i < ASSOCIATIVITY; i++) begin
        if (cache_mem[i][index].valid && cache_mem[i][index].tag == tag) begin
            cache_hit = 1;
            hit_way = 1 << i;
            line_dirty = cache_mem[i][index].dirty;
        end
    end
    
    // LRU replacement policy
    replace_way = 1;
    for (int i = 0; i < ASSOCIATIVITY; i++) begin
        if (cache_mem[i][index].lru == 0) begin
            replace_way = 1 << i;
            break;
        end
    end
end

// Update LRU information
always_ff @(posedge clk) begin
    if (state == READ_HIT || state == WRITE_HIT) begin
        automatic int way_idx;
        
        for (way_idx = 0; way_idx < ASSOCIATIVITY; way_idx++) begin
            if (hit_way[way_idx]) break;
        end
        
        for (int i = 0; i < ASSOCIATIVITY; i++) begin
            if (cache_mem[i][saved_addr[OFFSET_BITS +: INDEX_BITS]].lru > 
                cache_mem[way_idx][saved_addr[OFFSET_BITS +: INDEX_BITS]].lru) begin
                cache_mem[i][saved_addr[OFFSET_BITS +: INDEX_BITS]].lru <= 
                    cache_mem[i][saved_addr[OFFSET_BITS +: INDEX_BITS]].lru - 1;
            end
        end
        
        cache_mem[way_idx][saved_addr[OFFSET_BITS +: INDEX_BITS]].lru <= ASSOCIATIVITY-1;
    end
end

endmodule