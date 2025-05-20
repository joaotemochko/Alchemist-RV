module noc_router #(
    parameter int NUM_PORTS = 13,
    parameter int DATA_WIDTH = 128,
    parameter int ADDR_WIDTH = 56,
    parameter int QOS_LEVELS = 4
) (
    input wire clk,
    input wire rst_n,
    
    // Request interfaces from initiators
    input wire [NUM_PORTS-1:0] req_in,
    input wire [NUM_PORTS-1:0] we_in,
    input wire [NUM_PORTS-1:0][ADDR_WIDTH-1:0] addr_in,
    input wire [NUM_PORTS-1:0][DATA_WIDTH-1:0] wdata_in,
    input wire [NUM_PORTS-1:0][DATA_WIDTH/8-1:0] wstrb_in,
    input wire [NUM_PORTS-1:0][QOS_LEVELS-1:0] qos_in,
    
    // Response interfaces to initiators
    output logic [NUM_PORTS-1:0] ack_out,
    output logic [NUM_PORTS-1:0][DATA_WIDTH-1:0] rdata_out,
    output logic [NUM_PORTS-1:0] error_out,
    
    // Memory interface
    output logic mem_req_out,
    output logic mem_we_out,
    output logic [ADDR_WIDTH-1:0] mem_addr_out,
    output logic [DATA_WIDTH-1:0] mem_wdata_out,
    input wire [DATA_WIDTH-1:0] mem_rdata_in,
    input wire mem_ack_in,
    input wire mem_error_in,
    
    // Peripheral interface
    output logic periph_req_out,
    output logic periph_we_out,
    output logic [ADDR_WIDTH-1:0] periph_addr_out,
    output logic [DATA_WIDTH-1:0] periph_wdata_out,
    input wire [DATA_WIDTH-1:0] periph_rdata_in,
    input wire periph_ack_in,
    input wire periph_error_in
);

// Address decoding
localparam MEM_BASE = 56'h0000_0000_0000_0000;
localparam MEM_SIZE = 56'h4000_0000; // 1GB
localparam PERIPH_BASE = 56'h4000_0000;
localparam PERIPH_SIZE = 56'h1000_0000; // 256MB

// Arbitration
typedef struct packed {
    logic [NUM_PORTS-1:0] request;
    logic [NUM_PORTS-1:0] grant;
    logic [QOS_LEVELS-1:0] priority;
} arbiter_state_t;

arbiter_state_t arb_state;

// Virtual channels
typedef struct packed {
    logic valid;
    logic [ADDR_WIDTH-1:0] addr;
    logic [DATA_WIDTH-1:0] data;
    logic [DATA_WIDTH/8-1:0] wstrb;
    logic [3:0] source;
    logic [QOS_LEVELS-1:0] qos;
} vc_packet_t;

vc_packet_t [3:0] vc_fifo [0:NUM_PORTS-1];
logic [3:0][1:0] vc_credits [0:NUM_PORTS-1];

// Routing logic
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        arb_state <= '0;
        mem_req_out <= 0;
        periph_req_out <= 0;
        for (int i = 0; i < NUM_PORTS; i++) begin
            vc_fifo[i] <= '0;
            vc_credits[i] <= '{default:2};
        end
    end else begin
        // Request arbitration
        for (int i = 0; i < NUM_PORTS; i++) begin
            if (req_in[i] && !ack_out[i]) begin
                arb_state.request[i] <= 1;
                arb_state.priority[i] <= qos_in[i];
            end else begin
                arb_state.request[i] <= 0;
            end
        end
        
        // QoS-based arbitration
        for (int p = QOS_LEVELS-1; p >= 0; p--) begin
            for (int i = 0; i < NUM_PORTS; i++) begin
                if (arb_state.request[i] && (qos_in[i] == p) && 
                    vc_credits[i][p] > 0) begin
                    arb_state.grant[i] <= 1;
                    vc_credits[i][p] <= vc_credits[i][p] - 1;
                    
                    // Store in VC FIFO
                    vc_fifo[i][p].valid <= 1;
                    vc_fifo[i][p].addr <= addr_in[i];
                    vc_fifo[i][p].data <= wdata_in[i];
                    vc_fifo[i][p].wstrb <= wstrb_in[i];
                    vc_fifo[i][p].source <= i;
                    vc_fifo[i][p].qos <= qos_in[i];
                    break;
                end
            end
        end
        
        // Route packets to destinations
        for (int p = QOS_LEVELS-1; p >= 0; p--) begin
            for (int i = 0; i < NUM_PORTS; i++) begin
                if (vc_fifo[i][p].valid) begin
                    // Address decoding
                    if (vc_fifo[i][p].addr >= MEM_BASE && 
                        vc_fifo[i][p].addr < MEM_BASE + MEM_SIZE) begin
                        // Memory access
                        mem_req_out <= 1;
                        mem_we_out <= we_in[i];
                        mem_addr_out <= vc_fifo[i][p].addr;
                        mem_wdata_out <= vc_fifo[i][p].data;
                        
                        if (mem_ack_in) begin
                            vc_fifo[i][p].valid <= 0;
                            rdata_out[i] <= mem_rdata_in;
                            ack_out[i] <= 1;
                            error_out[i] <= mem_error_in;
                            vc_credits[i][p] <= vc_credits[i][p] + 1;
                        end
                    end else if (vc_fifo[i][p].addr >= PERIPH_BASE && 
                               vc_fifo[i][p].addr < PERIPH_BASE + PERIPH_SIZE) {
                        // Peripheral access
                        periph_req_out <= 1;
                        periph_we_out <= we_in[i];
                        periph_addr_out <= vc_fifo[i][p].addr;
                        periph_wdata_out <= vc_fifo[i][p].data;
                        
                        if (periph_ack_in) begin
                            vc_fifo[i][p].valid <= 0;
                            rdata_out[i] <= periph_rdata_in;
                            ack_out[i] <= 1;
                            error_out[i] <= periph_error_in;
                            vc_credits[i][p] <= vc_credits[i][p] + 1;
                        end
                    end
                end
            end
        end
    end
end

endmodule