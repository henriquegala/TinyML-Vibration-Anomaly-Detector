`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 24.08.2026 15:55:35
// Design Name: 
// Module Name: activation_unit
// Project Name: 
// Target Devices: 
// Tool Versions: 
// Description: 
// 
// Dependencies: 
// 
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
// 
//////////////////////////////////////////////////////////////////////////////////


module activation_unit #(
    parameter int in_width = 35,
    parameter int data_width = 16,
    parameter int frac_bits = 8,
    parameter int activation_type = 1
    )
    (
    input logic clk, rst_n, valid_in,
    input logic signed [in_width-1:0] data_in,
    output logic valid_out,
    output logic signed [data_width-1:0] data_out
    );
    
    logic signed[15:0] q88_clamped;
    logic overflow;
    logic signed[15:0] act_comb;
    
    logic signed[15:0] v_clamp;
    logic signed[31:0] p1;
    logic signed[47:0] p2;
    
    logic [7:0] addr;
    logic signed [data_width-1:0] sigmoid_lut [0:255];
    
    initial begin 
        $readmemh("sigmoid_values.mem", sigmoid_lut);
    end
    
    always_comb begin
        if (data_in > $signed(in_width'(32767 <<< frac_bits))) begin
            q88_clamped = 16'sh7FFF;
        end else if (data_in < $signed(in_width'(-32768 <<< frac_bits))) begin
            q88_clamped = 16'sh8000;
        end else begin 
            q88_clamped = data_in[23:8];
        end
    end
    
    always_comb begin
        //Valores por defeito
        v_clamp  = '0;
        p1       = '0;
        p2       = '0;
        addr     = '0;
        act_comb = q88_clamped;
        case (activation_type)
            0 : act_comb = q88_clamped; //Linear/Bypass
            1 : act_comb = (q88_clamped < 0) ? 0 : q88_clamped; //ReLU
            2 : act_comb = (q88_clamped < 0)? (q88_clamped >>> 3) : q88_clamped; //LeakyReLU alfa=0.125
            3 : begin //Hard-Swish
                v_clamp = (q88_clamped <= -768) ? 0 : ((q88_clamped >= 768) ? 1536 : q88_clamped + 768);
                p1 = q88_clamped * v_clamp;
                p2 = p1 * 10923;
                act_comb = p2 >>> 24;
            end
            4: begin //Sigmoide
                if (q88_clamped > 16'sd1024)
                    addr = 8'd255;
                else if (q88_clamped < -16'sd1024)
                    addr = 8'd0;
                else
                    addr = 8'((q88_clamped + 16'sd1024) >>> 3);
                act_comb = sigmoid_lut[addr];
            end
            default : act_comb = q88_clamped;
        endcase
    end
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            data_out <= '0;
            valid_out <= 1'b0;
        end else begin
            valid_out <= valid_in;
            data_out <= act_comb;
        end
    end
    
endmodule
