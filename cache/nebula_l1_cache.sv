module nebula_l1_cache #(
    parameter int SIZE = 32768,
    parameter int LINE_SIZE = 64,
    parameter int ASSOCIATIVITY = 4,
    parameter int XLEN = 64,
    parameter int PHYS_ADDR_SIZE = 56
) (
    input wire clk,
    input wire rst_n,
    
    // Core interface
    input wire [PHYS_ADDR_SIZE-1:0] addr,
    input wire req,
    input wire we,
    input wire [7:0] wstrb,
    input wire [XLEN-1:0] wdata,
    output logic [XLEN-1:0] rdata,
    output logic ack,
    output logic error,
    
    // L2 interface
    output logic l2_req,
    output logic [PHYS_ADDR_SIZE-1:0] l2_addr,
    input wire [LINE_SIZE-1:0] l2_rdata,
    output logic [LINE_SIZE-1:0] l2_wdata,
    input wire l2_ack,
    input wire l2_error,
    
    // Performance counters
    output logic [31:0] hit_count,
    output logic [31:0] miss_count
);

localparam OFFSET_BITS = $clog2(LINE_SIZE);
localparam INDEX_BITS = $clog2(SIZE/(ASSOCIATIVITY*LINE_SIZE));
localparam TAG_BITS = PHYS_ADDR_SIZE - OFFSET_BITS - INDEX_BITS;

typedef struct packed {
    logic valid;
    logic dirty;
    logic [TAG_BITS-1:0] tag;
    logic [LINE_SIZE-1:0] data;
} cache_line_t;

cache_line_t cache_mem [0:ASSOCIATIVITY-1][0:(1<<INDEX_BITS)-1];
logic [ASSOCIATIVITY-1:0] lru_table [0:(1<<INDEX_BITS)-1];

logic [PHYS_ADDR_SIZE-1:0] saved_addr;
logic [XLEN-1:0] saved_wdata;
logic [7:0] saved_wstrb;
logic saved_we;
logic cache_hit;
logic [ASSOCIATIVITY-1:0] hit_way;
logic [ASSOCIATIVITY-1:0] replace_way;
logic line_dirty;
logic [LINE_SIZE-1:0] line_to_write;

enum logic [2:0] {
    IDLE,
    TAG_CHECK,
    READ_HIT,
    WRITE_HIT,
    ALLOCATE,
    WRITE_BACK,
    WAIT_L2
} state, next_state;

// Cache access logic
always_comb begin
    automatic logic [INDEX_BITS-1:0] index = addr[OFFSET_BITS +: INDEX_BITS];
    automatic logic [TAG_BITS-1:0] tag = addr[OFFSET_BITS + INDEX_BITS +: TAG_BITS];
    
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
        if (lru_table[index][i] == 0) begin
            replace_way = 1 << i;
            break;
        end
    end
end

// State machine
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state <= IDLE;
        hit_count <= 0;
        miss_count <= 0;
    end else begin
        state <= next_state;
        
        if (state == READ_HIT || state == WRITE_HIT)
            hit_count <= hit_count + 1;
        else if (state == ALLOCATE)
            miss_count <= miss_count + 1;
    end
end

always_comb begin
    next_state = state;
    ack = 0;
    error = 0;
    l2_req = 0;
    rdata = '0;
    
    case (state)
        IDLE: begin
            if (req) begin
                saved_addr = addr;
                saved_wdata = wdata;
                saved_wstrb = wstrb;
                saved_we = we;
                next_state = TAG_CHECK;
            end
        end
        
        TAG_CHECK: begin
            if (cache_hit) begin
                if (saved_we)
                    next_state = WRITE_HIT;
                else
                    next_state = READ_HIT;
            end else begin
                next_state = ALLOCATE;
            end
        end
        
        READ_HIT: begin
            automatic logic [INDEX_BITS-1:0] index = saved_addr[OFFSET_BITS +: INDEX_BITS];
            automatic logic [OFFSET_BITS-1:0] offset = saved_addr[0 +: OFFSET_BITS];
            
            for (int i = 0; i < ASSOCIATIVITY; i++) begin
                if (hit_way[i]) begin
                    rdata = cache_mem[i][index].data[offset*8 +: 64];
                    break;
                end
            end
            
            ack = 1;
            next_state = IDLE;
        end
        
        WRITE_HIT: begin
            automatic logic [INDEX_BITS-1:0] index = saved_addr[OFFSET_BITS +: INDEX_BITS];
            automatic logic [OFFSET_BITS-1:0] offset = saved_addr[0 +: OFFSET_BITS];
            
            for (int i = 0; i < ASSOCIATIVITY; i++) begin
                if (hit_way[i]) begin
                    // Update appropriate bytes based on wstrb
                    for (int b = 0; b < 8; b++) begin
                        if (saved_wstrb[b]) begin
                            cache_mem[i][index].data[offset*8 + b*8 +: 8] = saved_wdata[b*8 +: 8];
                        end
                    end
                    cache_mem[i][index].dirty = 1;
                    break;
                end
            end
            
            ack = 1;
            next_state = IDLE;
        end
        
        ALLOCATE: begin
            automatic logic [INDEX_BITS-1:0] index = saved_addr[OFFSET_BITS +: INDEX_BITS];
            
            // Check if we need to write back
            for (int i = 0; i < ASSOCIATIVITY; i++) begin
                if (replace_way[i] && cache_mem[i][index].dirty) begin
                    next_state = WRITE_BACK;
                    break;
                end
            end
            
            if (next_state == ALLOCATE) begin
                l2_req = 1;
                l2_addr = {saved_addr[PHYS_ADDR_SIZE-1:OFFSET_BITS], {OFFSET_BITS{1'b0}}};
                next_state = WAIT_L2;
            end
        end
        
        WRITE_BACK: begin
            automatic logic [INDEX_BITS-1:0] index = saved_addr[OFFSET_BITS +: INDEX_BITS];
            
            for (int i = 0; i < ASSOCIATIVITY; i++) begin
                if (replace_way[i]) begin
                    line_to_write = cache_mem[i][index].data;
                    break;
                end
            end
            
            l2_req = 1;
            l2_wdata = line_to_write;
            l2_addr = {cache_mem[i][index].tag, index, {OFFSET_BITS{1'b0}}};
            next_state = WAIT_L2;
        end
        
        WAIT_L2: begin
            if (l2_ack) begin
                if (l2_error) begin
                    error = 1;
                    next_state = IDLE;
                end else begin
                    // Allocate new line
                    automatic logic [INDEX_BITS-1:0] index = saved_addr[OFFSET_BITS +: INDEX_BITS];
                    automatic logic [TAG_BITS-1:0] tag = saved_addr[OFFSET_BITS + INDEX_BITS +: TAG_BITS];
                    
                    for (int i = 0; i < ASSOCIATIVITY; i++) begin
                        if (replace_way[i]) begin
                            cache_mem[i][index].valid = 1;
                            cache_mem[i][index].dirty = 0;
                            cache_mem[i][index].tag = tag;
                            if (state == ALLOCATE)
                                cache_mem[i][index].data = l2_rdata;
                            break;
                        end
                    end
                    
                    next_state = TAG_CHECK;
                end
            end
        end
    endcase
end

// Update LRU information
always_ff @(posedge clk) begin
    if (state == READ_HIT || state == WRITE_HIT) begin
        automatic logic [INDEX_BITS-1:0] index = saved_addr[OFFSET_BITS +: INDEX_BITS];
        automatic int way_idx;
        
        for (way_idx = 0; way_idx < ASSOCIATIVITY; way_idx++) begin
            if (hit_way[way_idx]) break;
        end
        
        for (int i = 0; i < ASSOCIATIVITY; i++) begin
            if (lru_table[index][i] > lru_table[index][way_idx])
                lru_table[index][i] <= lru_table[index][i] - 1;
        end
        
        lru_table[index][way_idx] <= ASSOCIATIVITY-1;
    end
end

endmodule