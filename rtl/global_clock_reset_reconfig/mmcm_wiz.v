`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: CCNU
// Engineer: Shen
// 
// Create Date: 2019/07/12 11:07:58
// Design Name: 
// Module Name: mmcm_wiz
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


module mmcm_wiz(
    input RST,
    input CLKIN,
    // Clock outputs
    output CLKOUT0,
    output CLKOUT1,
    output CLKOUT2,
    output CLKOUT3,
    output CLKOUT4,
    output CLKOUT5,
    output CLKOUT6,  
    // DRP Ports
    input DCLK,
    input DEN,
    input DWE,
    input[6:0] DADDR, // 7 bits
    input[15:0] DI, // 16 bits
    output[15:0] DO, // (16-bits)
    output DRDY,
    // LOCKED
    output LOCKED
    );

// These signals are used for the BUFG's necessary for the design.
wire CLKFBOUTB_unused;
wire CLKFBSTOPPED_unused;
wire CLKINSTOPPED_unused;
wire CLKOUT0B_unused;
wire CLKOUT1B_unused;
wire CLKOUT2B_unused;
wire CLKOUT3B_unused;
wire PSDONE_unused;


wire clkfb_bufgout;
wire clkfb_bufgin;

wire clk0_bufgin;
wire clk1_bufgin;
wire clk2_bufgin;
wire clk3_bufgin;
wire clk4_bufgin;
wire clk5_bufgin;
wire clk6_bufgin;




BUFG BUFG_FB (
  .O(clkfb_bufgout),
  .I(clkfb_bufgin)
);

BUFG BUFG_CLK0 (
  .O(CLKOUT0),
  .I(clk0_bufgin)
);
BUFG BUFG_CLK1 (
  .O(CLKOUT1),
  .I(clk1_bufgin)
);
BUFG BUFG_CLK2 (
  .O(CLKOUT2),
  .I(clk2_bufgin)
);
BUFG BUFG_CLK3 (
  .O(CLKOUT3),
  .I(clk3_bufgin)
);
BUFG BUFG_CLK4 (
  .O(CLKOUT4),
  .I(clk4_bufgin)
);
BUFG BUFG_CLK5 (
  .O(CLKOUT5),
  .I(clk5_bufgin)
);
BUFG BUFG_CLK6 (
  .O(CLKOUT6),
  .I(clk6_bufgin)
);


// MMCM_ADV that reconfiguration will take place on
MMCME2_ADV #(
    // "HIGH", "LOW" or "OPTIMIZED"
    .BANDWIDTH("HIGH"),
    .DIVCLK_DIVIDE(1), // (1 to 106)
    
    .CLKFBOUT_MULT_F(6), // (2 to 64)
    .CLKFBOUT_PHASE(0.0),
    .CLKFBOUT_USE_FINE_PS("FALSE"),
    
    // Set the clock period (ns) of input clocks
    .CLKIN1_PERIOD(5.000),
    .REF_JITTER1(0.010),
    
    .CLKIN2_PERIOD(10.000),
    .REF_JITTER2(0.010),
    
    // CLKOUT parameters:
    // DIVIDE: (1 to 128)
    // DUTY_CYCLE: (0.01 to 0.99) - This is dependent on the divide value.
    // PHASE: (0.0 to 360.0) - This is dependent on the divide value.
    // USE_FINE_PS: (TRUE or FALSE)
    
    .CLKOUT0_DIVIDE_F(24), // 200 * 6 / 24 = 50M
    .CLKOUT0_DUTY_CYCLE(0.5),
    .CLKOUT0_PHASE(0.0),
    .CLKOUT0_USE_FINE_PS("FALSE"),
    
    .CLKOUT1_DIVIDE(20), // 200 * 6 / 20 = 60M
    .CLKOUT1_DUTY_CYCLE(0.25),
    .CLKOUT1_PHASE(0.0),
    .CLKOUT1_USE_FINE_PS("FALSE"),
    
    .CLKOUT2_DIVIDE(24), // 200 * 6 / 24 = 50M
    .CLKOUT2_DUTY_CYCLE(0.5),
    .CLKOUT2_PHASE(0.0),
    .CLKOUT2_USE_FINE_PS("FALSE"),
    
    .CLKOUT3_DIVIDE(24),
    .CLKOUT3_DUTY_CYCLE(0.5),
    .CLKOUT3_PHASE(0.0),
    .CLKOUT3_USE_FINE_PS("FALSE"),
    
    .CLKOUT4_DIVIDE(20),
    .CLKOUT4_DUTY_CYCLE(0.5),
    .CLKOUT4_PHASE(0.0),
    .CLKOUT4_USE_FINE_PS("FALSE"),
    .CLKOUT4_CASCADE("FALSE"),
    
    .CLKOUT5_DIVIDE(20),
    .CLKOUT5_DUTY_CYCLE(0.5),
    .CLKOUT5_PHASE(0.0),
    .CLKOUT5_USE_FINE_PS("FALSE"),
    
    .CLKOUT6_DIVIDE(20),
    .CLKOUT6_DUTY_CYCLE(0.5),
    .CLKOUT6_PHASE(0.0),
    .CLKOUT6_USE_FINE_PS("FALSE"),
    
    // Misc parameters
    .COMPENSATION("ZHOLD"),
    .STARTUP_WAIT("FALSE")
) mmcme2_test_inst (
    .CLKFBOUT(clkfb_bufgin),
    .CLKFBOUTB(CLKFBOUTB_unused),
    
    .CLKFBSTOPPED(CLKFBSTOPPED_unused),
    .CLKINSTOPPED(CLKINSTOPPED_unused),
    
    // Clock outputs
    .CLKOUT0(clk0_bufgin),
    .CLKOUT0B(CLKOUT0B_unused),
    .CLKOUT1(clk1_bufgin),
    .CLKOUT1B(CLKOUT1B_unused),
    .CLKOUT2(clk2_bufgin),
    .CLKOUT2B(CLKOUT2B_unused),
    .CLKOUT3(clk3_bufgin),
    .CLKOUT3B(CLKOUT3B_unused),
    .CLKOUT4(clk4_bufgin),
    .CLKOUT5(clk5_bufgin),
    .CLKOUT6(clk6_bufgin),
    
    // DRP Ports
    .DO(DO), // (16-bits)
    .DRDY(DRDY),
    .DADDR(DADDR), //  7bits
    .DCLK(DCLK),
    .DEN(DEN),
    .DI(DI), // 16 bits
    .DWE(DWE),
    
    .LOCKED(LOCKED),
    .CLKFBIN(clkfb_bufgout),
    
    // Clock inputs
    .CLKIN1(CLKIN),
    .CLKIN2(1'b0),
    .CLKINSEL(1'b1),
    
    // Fine phase shifting
    .PSDONE(PSDONE_unused),
    .PSCLK(1'b0),
    .PSEN(1'b0),
    .PSINCDEC(1'b0),
    
    .PWRDWN(1'b0),
    .RST(RST)
);


endmodule
