`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: CCNU
// Engineer: Shen
// 
// Create Date: 2019/07/04 17:07:58
// Design Name: 
// Module Name: mmcm_resetter
// Project Name: 
// Target Devices: 
// Tool Versions: 
// Description: 
//      This module is intended for power-on resetting, while accepting force reset
//      (i.e. from a button push) to reset both clock generator (DCM) and other
//      components in the design.  It sets CLK_RST high for (CNT_RANGE_HIGH -
//      CLK_RESET_DELAY_CNT) cycles, Then wait for the DCM_LOCKED signal.  It waits
//      for another (CNT_RANGE_HIGH - GBL_RESET_DELAY_CNT) cycles before setting
//      GLOBAL_RST low.  This module will monitor both FORCE_RST and DCM_LOCKED,
//      and go through proper resetting sequence if either condition is triggered.
// Dependencies: 
// 
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
// 
//////////////////////////////////////////////////////////////////////////////////


module mmcm_resetter
//#(
//parameter CLK_RESET_DELAY_CNT = 10000,
//parameter GBL_RESET_DELAY_CNT = 100,
//parameter CNT_RANGE_HIGH = 16383
//)
(
input FORCE_RST,
input CLK,    // system clock
input DCM_LOCKED,
output reg DCM_RST,
output reg GLOBAL_RST
    );

parameter CLK_RESET_DELAY_CNT = 14'd10000;// 2^14 = 16384
parameter GBL_RESET_DELAY_CNT = 14'd15000;
parameter CNT_RANGE_HIGH = 14'd16383;
reg[13:0] RstCtr;

reg [4:0] rstState;
parameter R0 = 5'b00001,
        R1 = 5'b00010,
        R2 = 5'b00100,
        R3 = 5'b01000,
        R4 = 5'b10000;
        
always@(posedge CLK or posedge FORCE_RST)
begin
    if(FORCE_RST == 1'b1)
        begin
            rstState <= R0;
            RstCtr <= 14'd0;
        end
    else 
        begin
            DCM_RST <= 1'b0;
            GLOBAL_RST <= 1'b1;
            case(rstState)
                R0:
                    begin
                        DCM_RST <= 1'b1;
                        RstCtr <= CLK_RESET_DELAY_CNT;
                        rstState <= R1;
                    end
                R1:
                    begin
                        DCM_RST <= 1'b1;
                        if(RstCtr == 14'd0)
                            rstState <= R2;
                        else
                            RstCtr <= RstCtr + 1'b1;
                    end
                R2:
                    begin
                        RstCtr <= GBL_RESET_DELAY_CNT;
                        if(DCM_LOCKED == 1'b1)
                            rstState <= R3;
                        else
                            rstState <= R2;
                    end
                R3:
                    begin
                        if(RstCtr == 14'd0)
                            rstState <= R4;
                        else
                            begin
                                rstState <= R3;
                                RstCtr <= RstCtr + 1'b1;
                            end
                    end
                R4:
                    begin
                        GLOBAL_RST <= 1'b0;
                        if(DCM_LOCKED == 1'b0)
                            rstState <= R0;
                        else
                            rstState <= R4;
                    end
                default:rstState <= R0;
            endcase
        end
end
endmodule
