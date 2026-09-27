`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 27.08.2026 15:13:57
// Design Name: 
// Module Name: tinyml_top
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


module tinyml_top #(
    parameter int num_inputs = 4,
    parameter int data_width = 16,
    parameter int frac_bits = 8,
    parameter int activation_type = 1, //Relu

    localparam int acc_width = (2*data_width) + $clog2(num_inputs + 1)
    )
    (
    input logic clk, rst_n, valid_in,

    input logic signed [data_width-1:0] inputs [num_inputs-1:0],
    input logic signed [data_width-1:0] weights [num_inputs-1:0],
    input logic signed [data_width-1:0] bias,

    input logic signed [data_width-1:0] target_expected,
    input logic signed [data_width-1:0] threshold,

    output logic valid_out,
    output logic signed [data_width-1:0] neuron_out,
    output logic anomaly_alert
    );

    logic signed [acc_width-1:0] mac_accum_out;
    logic mac_valid_out;

    mac_tree #(
        .num_inputs (num_inputs),
        .data_width (data_width),
        .frac_bits (frac_bits)
    ) u_mac_tree (
        .clk (clk),
        .rst_n (rst_n),
        .valid_in (valid_in),
        .inputs (inputs),
        .weights (weights),
        .bias (bias),

        .valid_out (mac_valid_out),
        .accum_out (mac_accum_out)
    );

    activation_unit #(
        .in_width (acc_width),
        .data_width (data_width),
        .frac_bits (frac_bits),
        .activation_type (activation_type)
    ) u_activation_unit (
        .clk (clk),
        .rst_n (rst_n),

        .valid_in (mac_valid_out),
        .data_in (mac_accum_out),

        .valid_out (valid_out),
        .data_out (neuron_out)
    );

    logic signed [data_width-1:0] target_reg1, target_reg2, target_reg3;
    logic signed [data_width-1:0] threshold_reg1, threshold_reg2, threshold_reg3;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            target_reg1 <= '0;
            target_reg2 <= '0;
            target_reg3 <= '0;
            threshold_reg1 <= '0;
            threshold_reg2 <= '0;
            threshold_reg3 <= '0;
        end else begin
            target_reg1 <= target_expected;
            target_reg2 <= target_reg1;
            target_reg3 <= target_reg2;

            threshold_reg1 <= threshold;
            threshold_reg2 <= threshold_reg1;
            threshold_reg3 <= threshold_reg2;
        end
    end
    
    logic signed [data_width:0] diff;
    logic signed [data_width:0] abs_error;

    always_comb begin
        diff = neuron_out - target_reg3;
        abs_error = (diff < 0) ? -diff : diff;
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            anomaly_alert <= 1'b0;
        end else begin
            if (valid_out) begin
                anomaly_alert <= (abs_error > threshold_reg3);
            end else begin
                anomaly_alert <= 1'b0;
            end
        end
    end
endmodule
