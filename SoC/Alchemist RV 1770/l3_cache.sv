module l3_cache #(
    parameter int SIZE = 12 * 1024 * 1024, // 12MB
    parameter int LINE_SIZE = 128, // 16 bytes
    parameter int ASSOCIATIVITY = 16,
    parameter int ADDR_WIDTH = 56
) (
    input wire clk,
    input wire rst_n,
    
    // CPU interface
    input wire cpu_req,
    input wire cpu_we,
    input wire [ADDR_WIDTH-1:0] cpu_addr,
    input wire [LINE_SIZE-1:0] cpu_wdata,
    output logic cpu_ack,
    output logic [LINE_SIZE-1:0] cpu_rdata,
    
    // DRAM interface
    output logic dram_req,
    output logic dram_we,
    output logic [ADDR_WIDTH-1:0] dram_addr,
    output logic [LINE_SIZE-1:0] dram_wdata,
    input wire [LINE_SIZE-1:0] dram_rdata,
    input wire dram_ack,
    
    // Performance counters
    output logic [31:0] hit_count,
    output logic [31:0] miss_count,
    output logic [31:0] writebacks
);

localparam OFFSET_BITS = $clog2(LINE_SIZE);
localparam INDEX_BITS = $clog2(SIZE/(ASSOCIATIVITY*LINE_SIZE));
localparam TAG_BITS = ADDR_WIDTH - OFFSET_BITS - INDEX_BITS;

// Cache memory
typedef struct packed {
    logic valid;
    logic dirty;
    logic [TAG_BITS-1:0] tag;
    logic [LINE_SIZE-1:0] data;
    logic [ASSOCIATIVITY-1:0] lru;
} cache_line_t;

cache_line_t cache [0:ASSOCIATIVITY-1][0:(1<<INDEX_BITS)-1];

// Cache controller state machine
enum logic [2:0] {
    IDLE,
    TAG_CHECK,
    READ_HIT,
    WRITE_HIT,
    ALLOCATE,
    WRITE_BACK,
    WAIT_DRAM
} state;

// Saved request
logic [ADDR_WIDTH-1:0] saved_addr;
logic [LINE_SIZE-1:0] saved_wdata;
logic saved_we;

// Cache access results
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
        for (int i = 0; i < ASSOCIATIVITY; i++) begin
            for (int j = 0; j < (1<<INDEX_BITS); j++) begin
                cache[i][j] <= '0;
            end
        end
    end else begin
        case (state)
            IDLE: begin
                if (cpu_req) begin
                    saved_addr <= cpu_addr;
                    saved_wdata <= cpu_wdata;
                    saved_we <= cpu_we;
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
                cpu_rdata <= cache[hit_way][saved_addr[OFFSET_BITS +: INDEX_BITS]].data;
                cpu_ack <= 1;
                hit_count <= hit_count + 1;
                state <= IDLE;
            end
            
            WRITE_HIT: begin
                cache[hit_way][saved_addr[OFFSET_BITS +: INDEX_BITS]].data <= saved_wdata;
                cache[hit_way][saved_addr[OFFSET_BITS +: INDEX_BITS]].dirty <= 1;
                cpu_ack <= 1;
                hit_count <= hit_count + 1;
                state <= IDLE;
            end
            
            ALLOCATE: begin
                if (cache[replace_way][saved_addr[OFFSET_BITS +: INDEX_BITS]].dirty) begin
                    state <= WRITE_BACK;
                end else begin
                    dram_req <= 1;
                    dram_we <= 0;
                    dram_addr <= {saved_addr[ADDR_WIDTH-1:OFFSET_BITS], {OFFSET_BITS{1'b0}}};
                    state <= WAIT_DRAM;
                end
            end
            
            WRITE_BACK: begin
                dram_req <= 1;
                dram_we <= 1;
                dram_addr <= {cache[replace_way][saved_addr[OFFSET_BITS +: INDEX_BITS]].tag, 
                             saved_addr[OFFSET_BITS +: INDEX_BITS], {OFFSET_BITS{1'b0}}};
                dram_wdata <= cache[replace_way][saved_addr[OFFSET_BITS +: INDEX_BITS]].data;
                writebacks <= writebacks + 1;
                state <= WAIT_DRAM;
            end
            
            WAIT_DRAM: begin
                if (dram_ack) begin
                    dram_req <= 0;
                    if (!dram_we) begin
                        // Allocate new line
                        cache[replace_way][saved_addr[OFFSET_BITS +: INDEX_BITS]].valid <= 1;
                        cache[replace_way][saved_addr[OFFSET_BITS +: INDEX_BITS]].dirty <= 0;
                        cache[replace_way][saved_addr[OFFSET_BITS +: INDEX_BITS]].tag <= 
                            saved_addr[ADDR_WIDTH-1:OFFSET_BITS + INDEX_BITS];
                        cache[replace_way][saved_addr[OFFSET_BITS +: INDEX_BITS]].data <= dram_rdata;
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
        if (cache[i][index].valid && cache[i][index].tag == tag) begin
            cache_hit = 1;
            hit_way = 1 << i;
            line_dirty = cache[i][index].dirty;
        end
    end
    
    // LRU replacement policy
    replace_way = 1;
    for (int i = 0; i < ASSOCIATIVITY; i++) begin
        if (cache[i][index].lru == 0) begin
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
            if (cache[i][saved_addr[OFFSET_BITS +: INDEX_BITS]].lru > 
                cache[way_idx][saved_addr[OFFSET_BITS +: INDEX_BITS]].lru) begin
                cache[i][saved_addr[OFFSET_BITS +: INDEX_BITS]].lru <= 
                    cache[i][saved_addr[OFFSET_BITS +: INDEX_BITS]].lru - 1;
            end
        end
        
        cache[way_idx][saved_addr[OFFSET_BITS +: INDEX_BITS]].lru <= ASSOCIATIVITY-1;
    end
end

endmodule