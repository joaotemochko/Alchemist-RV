module power_management_unit #(
    parameter int NUM_DOMAINS = 8,
    parameter int NUM_SENSORS = 16,
    parameter int VOLTAGE_LEVELS = 8
) (
    input wire clk,
    input wire rst_n,
    
    // Power domains control
    output logic [NUM_DOMAINS-1:0] domain_en,
    
    // Voltage control
    output logic [VOLTAGE_LEVELS-1:0] voltage_level [0:NUM_DOMAINS-1],
    
    // Clock control
    output logic [NUM_DOMAINS-1:0] clk_en,
    output logic [3:0] clk_div [0:NUM_DOMAINS-1],
    
    // Thermal sensors
    input wire [15:0] temp_sense [0:NUM_SENSORS-1],
    
    // Power gates
    output logic [NUM_DOMAINS-1:0] power_gate,
    
    // APB interface
    input wire psel,
    input wire penable,
    input wire pwrite,
    input wire [31:0] paddr,
    input wire [31:0] pwdata,
    output logic [31:0] prdata,
    output logic pready,
    output logic pslverr
);

// Power states
typedef enum logic [1:0] {
    POWER_OFF,
    POWER_ON,
    POWER_LOW,
    POWER_HIGH
} power_state_t;

power_state_t pstate [0:NUM_DOMAINS-1];

// DVFS control
logic [2:0] perf_level [0:NUM_DOMAINS-1];
logic [NUM_DOMAINS-1:0] dvfs_req;
logic [NUM_DOMAINS-1:0] dvfs_ack;

// Thermal monitoring
logic [15:0] max_temp;
logic thermal_alert;

// APB register file
typedef struct packed {
    logic [NUM_DOMAINS-1:0] domain_enable;
    logic [NUM_DOMAINS-1:0] power_gate;
    logic [NUM_DOMAINS-1:0] clk_enable;
    logic [3:0] clk_div [0:NUM_DOMAINS-1];
    logic [2:0] voltage_level [0:NUM_DOMAINS-1];
    logic [2:0] perf_level [0:NUM_DOMAINS-1];
    logic [15:0] temp_threshold;
} pmu_regs_t;

pmu_regs_t regs;

// Thermal monitoring
always_comb begin
    max_temp = 0;
    thermal_alert = 0;
    
    for (int i = 0; i < NUM_SENSORS; i++) begin
        if (temp_sense[i] > max_temp) begin
            max_temp = temp_sense[i];
        end
    end
    
    if (max_temp > regs.temp_threshold) begin
        thermal_alert = 1;
    end
end

// DVFS controller
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        for (int i = 0; i < NUM_DOMAINS; i++) begin
            pstate[i] <= POWER_ON;
            perf_level[i] <= 3'b100;
            voltage_level[i] <= 3'b100;
            clk_div[i] <= 0;
        end
    end else begin
        for (int i = 0; i < NUM_DOMAINS; i++) begin
            case (pstate[i])
                POWER_OFF: begin
                    domain_en[i] <= 0;
                    power_gate[i] <= 1;
                    clk_en[i] <= 0;
                end
                
                POWER_ON: begin
                    domain_en[i] <= 1;
                    power_gate[i] <= 0;
                    clk_en[i] <= 1;
                    clk_div[i] <= 0;
                    voltage_level[i] <= 3'b100;
                end
                
                POWER_LOW: begin
                    domain_en[i] <= 1;
                    power_gate[i] <= 0;
                    clk_en[i] <= 1;
                    clk_div[i] <= 2;
                    voltage_level[i] <= 3'b010;
                end
                
                POWER_HIGH: begin
                    domain_en[i] <= 1;
                    power_gate[i] <= 0;
                    clk_en[i] <= 1;
                    clk_div[i] <= 0;
                    voltage_level[i] <= 3'b110;
                end
            endcase
            
            // Handle DVFS requests
            if (dvfs_req[i] && !dvfs_ack[i]) begin
                case (perf_level[i])
                    3'b000: pstate[i] <= POWER_OFF;
                    3'b001: pstate[i] <= POWER_LOW;
                    3'b010: pstate[i] <= POWER_ON;
                    3'b100: pstate[i] <= POWER_HIGH;
                    default: pstate[i] <= POWER_ON;
                endcase
                dvfs_ack[i] <= 1;
            end else begin
                dvfs_ack[i] <= 0;
            end
        end
    end
end

// APB interface
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        regs <= '{
            domain_enable: '1,
            power_gate: '0,
            clk_enable: '1,
            clk_div: '{default:0},
            voltage_level: '{default:3'b100},
            perf_level: '{default:3'b010},
            temp_threshold: 16'h8000
        };
        prdata <= 0;
        pready <= 0;
        pslverr <= 0;
    end else begin
        pready <= 0;
        
        if (psel && !penable && !pready) begin
            pready <= 1;
            
            if (pwrite) begin
                case (paddr[7:0])
                    8'h00: regs.domain_enable <= pwdata[NUM_DOMAINS-1:0];
                    8'h04: regs.power_gate <= pwdata[NUM_DOMAINS-1:0];
                    8'h08: regs.clk_enable <= pwdata[NUM_DOMAINS-1:0];
                    8'h0C: begin
                        for (int i = 0; i < NUM_DOMAINS; i++) begin
                            if (pwdata[i*4 +: 4] <= 10) begin
                                regs.clk_div[i] <= pwdata[i*4 +: 4];
                            end
                        end
                    end
                    8'h10: begin
                        for (int i = 0; i < NUM_DOMAINS; i++) begin
                            if (pwdata[i*3 +: 3] < VOLTAGE_LEVELS) begin
                                regs.voltage_level[i] <= pwdata[i*3 +: 3];
                            end
                        end
                    end
                    8'h14: begin
                        for (int i = 0; i < NUM_DOMAINS; i++) begin
                            regs.perf_level[i] <= pwdata[i*3 +: 3];
                            dvfs_req[i] <= 1;
                        end
                    end
                    8'h18: regs.temp_threshold <= pwdata[15:0];
                endcase
            end else begin
                case (paddr[7:0])
                    8'h00: prdata <= regs.domain_enable;
                    8'h04: prdata <= regs.power_gate;
                    8'h08: prdata <= regs.clk_enable;
                    8'h0C: begin
                        for (int i = 0; i < NUM_DOMAINS; i++) begin
                            prdata[i*4 +: 4] <= regs.clk_div[i];
                        end
                    end
                    8'h10: begin
                        for (int i = 0; i < NUM_DOMAINS; i++) begin
                            prdata[i*3 +: 3] <= regs.voltage_level[i];
                        end
                    end
                    8'h14: begin
                        for (int i = 0; i < NUM_DOMAINS; i++) begin
                            prdata[i*3 +: 3] <= regs.perf_level[i];
                        end
                    end
                    8'h18: prdata <= regs.temp_threshold;
                    8'h1C: prdata <= max_temp;
                    default: prdata <= 0;
                endcase
            end
        end
    end
end

endmodule