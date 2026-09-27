`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 14.08.2026 15:08:30
// Design Name: 
// Module Name: mac_tree
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


module mac_tree #(
    parameter int num_inputs = 4, //Valores por defeito
    parameter int data_width = 16,
    parameter int frac_bits = 8,
    
    localparam int product_width = 2*data_width,
    localparam int guard_bits = $clog2(num_inputs+1),
    localparam int acc_width = product_width + guard_bits
    )
    (
    input logic clk, rst_n, valid_in,
    input logic signed [data_width-1:0] inputs [num_inputs-1:0],
    input logic signed [data_width-1:0] weights [num_inputs-1:0],
    input logic signed [data_width-1:0] bias,
    output logic valid_out,
    output logic signed [acc_width-1:0] accum_out
    );
    
    logic signed [product_width-1:0] mult_reg [num_inputs-1:0];
    logic signed [product_width-1:0] bias_reg;
    logic valid_stage1;
    
    logic signed [acc_width-1:0] sum_comb;
    
    always_comb begin   
        sum_comb = $signed(bias_reg);
        for (int i = 0; i < num_inputs; i++) begin
            sum_comb = sum_comb + mult_reg[i];
        end
    end
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid_stage1 <= 1'b0;
            valid_out <= 1'b0;
            accum_out <= '0;
            bias_reg <= '0;
            for (int i = 0; i < num_inputs; i++) begin  
                mult_reg[i] <= '0;
            end
            
        end else begin
            if (valid_in) begin
                for (int i = 0; i < num_inputs; i++) begin
                    mult_reg[i] <= inputs[i] * weights[i];
                end
                bias_reg <= $signed(bias) <<< frac_bits;
            end
            valid_stage1 <= valid_in;
            if (valid_stage1) begin
                accum_out <= sum_comb;
            end
            valid_out <= valid_stage1;
        end
    end 
    
endmodule
