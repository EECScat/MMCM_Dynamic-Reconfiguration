`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2019/07/04 19:31:08
// Design Name: 
// Module Name: global_clock_reset
// Project Name: 
// Target Devices: 
// Tool Versions: 
// Description: 
//      This module encapsulates the main clock generation and its proepr resetting.
//      It also provides a global reset signal output upon stable clock's pll lock.
// Dependencies: 
// 
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
// 
//////////////////////////////////////////////////////////////////////////////////


module global_clock_reset(
    input SYS_CLK_P,
    input SYS_CLK_N,
    input FORCE_RST,
    output GLOBAL_RST,
    output SYS_CLK,
    output CLK_OUT1,
    output CLK_OUT2,
    output CLK_OUT3,
    output CLK_OUT4
    );
    
wire sys_clk_i;
wire dcm_reset;
wire dcm_locked;

IBUFDS #(
    .DIFF_TERM("FALSE"),
    .IBUF_LOW_PWR("FALSE"),
    .IOSTANDARD("DEFAULT")
    )
    IBUFDS_inst
    (
    .O(sys_clk_i),
    .I(SYS_CLK_P),
    .IB(SYS_CLK_N)
    );

BUFG BUFG_inst(
    .I(sys_clk_i),
    .O(SYS_CLK)
    );

clk_wiz_0 clk_wiz_0_inst(
    // Clock out ports
    .clk_out1(CLK_OUT1),     // output clk_out1
    .clk_out2(CLK_OUT2),     // output clk_out2
    .clk_out3(CLK_OUT3),     // output clk_out3
    .clk_out4(CLK_OUT4),     // output clk_out4
    // Status and control signals
    .reset(dcm_reset),       // input reset
    .locked(dcm_locked),     // output locked
    // Clock in ports
    .clk_in1(sys_clk_i)      // input clk_in1
    );    

global_resetter global_resetter_inst(
    .FORCE_RST(FORCE_RST),
    .CLK(sys_clk_i),    // system clock
    .DCM_LOCKED(dcm_locked),
    .DCM_RST(dcm_reset),
    .GLOBAL_RST(GLOBAL_RST)
    ); 
 
endmodule
