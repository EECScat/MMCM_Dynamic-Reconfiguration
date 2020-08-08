`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: CCNU
// Engineer: Shen
// 
// Create Date: 2019/07/12 11:27:17
// Design Name: 
// Module Name: mmcm
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


module mmcm(
    input   sys_clk_i,
    input   FORCE_RESET,
    input[48*12-1:0]RCREG,
    input   RCEN, 
    output  RCRDY,
    output  GLOBAL_RST,
    output  CLK_OUT0,
    output  CLK_OUT1,
    output  CLK_OUT2,
    output  CLK_OUT3,
    output  CLK_OUT4,
    output  CLK_OUT5,
    output  CLK_OUT6
    );

wire dcm_reset;
wire mmcm_reset;
wire mmcm_locked;
// wire for drp
wire dclk;
wire den;
wire dwe;
wire [6:0]daddr;
wire [15:0] di;
wire [15:0] do;
wire drdy;

wire mmcm_drp_rst;

mmcm_resetter mmcm_resetter_inst(
    .FORCE_RST(FORCE_RESET), 
    .CLK(sys_clk_i), 
    .DCM_LOCKED(mmcm_locked), 
    .DCM_RST(dcm_reset), 
    .GLOBAL_RST(GLOBAL_RST) 
    );

assign mmcm_reset = FORCE_RESET ? 1'b1 : mmcm_drp_rst;
mmcm_wiz mmcm_wiz_inst(
    .RST(mmcm_reset),
    .CLKIN(sys_clk_i),
    .CLKOUT0(CLK_OUT0),
    .CLKOUT1(CLK_OUT1),
    .CLKOUT2(CLK_OUT2),
    .CLKOUT3(CLK_OUT3),
    .CLKOUT4(CLK_OUT4),
    .CLKOUT5(CLK_OUT5),
    .CLKOUT6(CLK_OUT6),  
    .DCLK(dclk),
    .DEN(den),
    .DWE(dwe),
    .DADDR(daddr), // 5 bits
    .DI(di), // 16 bits
    .DO(do), // (16-bits)
    .DRDY(drdy),
    .LOCKED(mmcm_locked)
    );
    
mmcm_drp mmcm_drp_inst(
    .CLK(sys_clk_i), 
    .RST(1'b0), 
    .RCREG(RCREG), 
    .RCEN(RCEN), 
    .RCRDY(RCRDY), 
    .DO(do),
    .DRDY(drdy),
    .LOCKED(mmcm_locked),
    .DWE(dwe),
    .DEN(den),
    .DADDR(daddr),
    .DI(di),
    .DCLK(dclk),
    .MMCM_DRP_RST(mmcm_drp_rst)
    );

endmodule
