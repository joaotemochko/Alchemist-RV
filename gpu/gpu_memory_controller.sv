module gpu_memory_controller #(
    parameter int NUM_CHANNELS = 4,
    parameter int CHANNEL_WIDTH = 128,
    parameter int ADDR_WIDTH = 40,
    parameter int BURST_LEN = 8
) (
    input wire clk,
    input wire rst_n,
    
    // GPU core interface
    input wire core_req,
    input wire core_we,
    input wire [ADDR_WIDTH-1:0] core_addr,
    input wire [NUM_CHANNELS*CHANNEL_WIDTH-1:0] core_wdata,
    output logic [NUM_CHANNELS*CHANNEL_WIDTH-1:0] core_rdata,
    output logic core_ack,
    
    // External memory interface
    output logic mem_req,
    output logic mem_we,
    output logic [ADDR_WIDTH-1:0] mem_addr,
    output logic [NUM_CHANNELS*CHANNEL_WIDTH-1:0] mem_wdata,
    input wire [NUM_CHANNELS*CHANNEL_WIDTH-1:0] mem_rdata,
    input wire mem_ack,
    
    // Performance counters
    output logic [31:0] read_count,
    output logic [31:0] write_count,
    output logic [31:0] stall_cycles
);

// Memory channels
typedef enum logic [1:0] {
    CHANNEL_READ,
    CHANNEL_WRITE,
    CHANNEL_IDLE
} channel_state_t;

channel_state_t channel_state [0:NUM_CHANNELS-1];
logic [ADDR_WIDTH-1:0] channel_addr [0:NUM_CHANNELS-1];
logic [CHANNEL_WIDTH-1:0] channel_wdata [0:NUM_CHANNELS-1];
logic [CHANNEL_WIDTH-1:0] channel_rdata [0:NUM_CHANNELS-1];
logic channel_ack [0:NUM_CHANNELS-1];

// Arbitration
logic [NUM_CHANNELS-1:0] channel_grant;
logic [NUM_CHANNELS-1:0] channel_req;

// Memory controller state machine
enum logic [2:0] {
    IDLE,
    ARBITRATE,
    READ,
    WRITE,
    WAIT_ACK
} state;

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state <= IDLE;
        mem_req <= 0;
        mem_we <= 0;
        read_count <= 0;
        write_count <= 0;
        stall_cycles <= 0;
        
        for (int i = 0; i < NUM_CHANNELS; i++) begin
            channel_state[i] <= CHANNEL_IDLE;
        end
    end else begin
        case (state)
            IDLE: begin
                if (|channel_req) begin
                    state <= ARBITRATE;
                end
            end
            
            ARBITRATE: begin
                // Simple round-robin arbitration
                channel_grant <= {channel_req[NUM_CHANNELS-2:0], channel_req[NUM_CHANNELS-1]} & ~channel_req;
                
                if (|channel_grant) begin
                    for (int i = 0; i < NUM_CHANNELS; i++) begin
                        if (channel_grant[i]) begin
                            mem_addr <= channel_addr[i];
                            mem_wdata <= channel_wdata[i];
                            mem_we <= (channel_state[i] == CHANNEL_WRITE);
                            mem_req <= 1;
                            state <= (channel_state[i] == CHANNEL_WRITE) ? WRITE : READ;
                        end
                    end
                end
            end
            
            READ, WRITE: begin
                if (mem_ack) begin
                    if (state == READ) begin
                        read_count <= read_count + 1;
                        for (int i = 0; i < NUM_CHANNELS; i++) begin
                            if (channel_grant[i]) begin
                                channel_rdata[i] <= mem_rdata[i*CHANNEL_WIDTH +: CHANNEL_WIDTH];
                                channel_ack[i] <= 1;
                            end
                        end
                    end else begin
                        write_count <= write_count + 1;
                    end
                    
                    mem_req <= 0;
                    state <= WAIT_ACK;
                end
            end
            
            WAIT_ACK: begin
                // Wait for channel to acknowledge
                if (&channel_ack) begin
                    state <= IDLE;
                    for (int i = 0; i < NUM_CHANNELS; i++) begin
                        channel_state[i] <= CHANNEL_IDLE;
                        channel_ack[i] <= 0;
                    end
                end
            end
        endcase
        
        // Track stall cycles
        if (state != IDLE && !mem_ack) begin
            stall_cycles <= stall_cycles + 1;
        end
    end
end

// Channel interfaces
generate
    for (genvar i = 0; i < NUM_CHANNELS; i++) begin : channels
        always_ff @(posedge clk) begin
            channel_req[i] <= (channel_state[i] != CHANNEL_IDLE);
            
            if (core_req && core_addr[2+:3] == i) begin
                channel_state[i] <= core_we ? CHANNEL_WRITE : CHANNEL_READ;
                channel_addr[i] <= core_addr;
                channel_wdata[i] <= core_wdata[i*CHANNEL_WIDTH +: CHANNEL_WIDTH];
            end
            
            if (channel_ack[i]) begin
                core_rdata[i*CHANNEL_WIDTH +: CHANNEL_WIDTH] <= channel_rdata[i];
            end
        end
    end
endgenerate

assign core_ack = &channel_ack;

endmodule