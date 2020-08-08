`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: CCNU
// Engineer: Shen
// 
// Create Date: 2019/07/11 20:37:22
// Design Name: 
// Module Name: mmcm_drp
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


module mmcm_drp(
    // These signals are controlled by user logic interface and are covered
    // in more detail within the XAPP.
    input             CLK, 
    input             RST, // active high
    input [48*12-1:0] RCREG, // MMCM ReConFiGuration parameters
    input             RCEN, // MMCM ReConfiguration ENable
    output reg        RCRDY, // MMCM ReConfiguration ReaDY
    // These signals are to be connected to the MMCM_ADV by port name.
    // Their use matches the MMCM port description in the Device User Guide.
    input      [15:0] DO,
    input             DRDY,
    input             LOCKED,
    output reg        DWE,
    output reg        DEN,
    output reg [6:0]  DADDR,
    output reg [15:0] DI,
    output            DCLK,
    output reg        MMCM_DRP_RST
    );

reg[3:0] w_cnt;
wire[6:0] drp_daddr;
wire[15:0] drp_bitmask;
wire[15:0] drp_bitset;
reg[47:0] data;

assign drp_daddr[6:0] = data[38:32];
assign drp_bitmask[15:0] = data[31:16];
assign drp_bitset[15:0] = data[15:0];

assign DCLK = CLK;

// state machine 
reg[7:0] current_state, next_state;
parameter 
        RESTART    = 8'd0,
        WAIT_LOCK  = 8'd1,
        WAIT_RCEN  = 8'd2,
        DATA_GET   = 8'd3,
        READ       = 8'd4,
        WAIT_R_RDY = 8'd5,
        BITMASK    = 8'd6,
        BITSET     = 8'd7,
        WRITE      = 8'd8,
        WAIT_W_RDY = 8'd9;

// phase I
always@(posedge CLK) 
begin
    if(RST) 
        begin
            current_state <= RESTART;
        end 
    else 
        begin
            current_state <= next_state;
        end
end 
// phase II
always@(current_state, LOCKED, RCEN, DRDY, w_cnt)
begin
    case(current_state)
        RESTART: begin next_state <= WAIT_LOCK;end
        WAIT_LOCK: begin if(LOCKED==1'b1) next_state <= WAIT_RCEN;
                        else next_state <= WAIT_LOCK; end 
        WAIT_RCEN: begin if(RCEN==1'b1) next_state <= DATA_GET;
                        else next_state <= WAIT_RCEN; end 
        DATA_GET: next_state <= READ;
        READ: next_state <= WAIT_R_RDY;
        WAIT_R_RDY: begin if(DRDY==1'b1) next_state <= BITMASK;
                        else next_state <= WAIT_R_RDY; end 
        BITMASK: next_state <= BITSET;
        BITSET: next_state <= WRITE;
        WRITE: next_state <= WAIT_W_RDY;
        WAIT_W_RDY: begin 
                        if(DRDY==1'b1) 
                            if(w_cnt==4'd11) begin next_state <= WAIT_LOCK; end
                            else begin next_state <= DATA_GET; end
                        else next_state <= WAIT_W_RDY; 
                    end 
        default: next_state <= RESTART;
    endcase
        
end

// phase III
always@(posedge CLK)
begin
	case(current_state)
	   RESTART:
	       begin
	           RCRDY <= 1'b0;
	           DWE <= 1'b0;
	           DEN <= 1'b0;
	           DADDR <= 7'd0;
	           DI <= 16'd0;
	           MMCM_DRP_RST <= 1'b1;
	           w_cnt <= 4'd0;
	       end
        WAIT_LOCK:
            begin
                DWE <= 1'b0;
                DEN <= 1'b0;
                DADDR <= DADDR;
                DI <= DI;
                MMCM_DRP_RST <= 1'b0;
                w_cnt <= 4'd0;
//                if(LOCKED==1'b1)
//                    RCRDY <= 1'b1;
//                else
                RCRDY <= 1'b0;
            end
        WAIT_RCEN:
            begin
                RCRDY <= 1'b1;
                DWE <= 1'b0;     
                DEN <= 1'b0;     
                DADDR <= DADDR;   
                DI <= DI;     
                MMCM_DRP_RST <= 1'b0;
                w_cnt <= 4'd0;
            end
        DATA_GET: 
            begin                
                RCRDY <= 1'b0;   
                DWE <= 1'b0;     
                DEN <= 1'b0;     
                DADDR <= DADDR;   
                DI <= DI;     
                MMCM_DRP_RST <= 1'b1;
                w_cnt <= w_cnt; 
                data <= RCREG[w_cnt*48+47-:48];
                
                // drp_daddr[6:0] =     RCREG[w_cnt*48+38-:7]; //data[38:32];
                // drp_bitmask[15:0] =  RCREG[w_cnt*48+31-:16];//data[31:16];
                // drp_bitset[15:0] =   RCREG[w_cnt*48+15-:16];//data[15:0];
                
            end                  
        READ: 
            begin
                RCRDY <= 1'b0;   
                DWE <= 1'b0;     
                DEN <= 1'b1;     
                DADDR <= drp_daddr;   
                DI <= DI;     
                MMCM_DRP_RST <= 1'b1;
                w_cnt <= w_cnt;
            end
        WAIT_R_RDY: 
            begin                  
                RCRDY <= 1'b0;     
                DWE <= 1'b0;       
                DEN <= 1'b0;       
                DADDR <= DADDR;
                DI <= DI;       
                MMCM_DRP_RST <= 1'b1;  
                w_cnt <= w_cnt;
            end                    
        BITMASK: 
            begin                  
                RCRDY <= 1'b0;     
                DWE <= 1'b0;       
                DEN <= 1'b0;       
                DADDR <= DADDR;
                DI <= drp_bitmask & DO;       
                MMCM_DRP_RST <= 1'b1;  
                w_cnt <= w_cnt;
            end                    
        BITSET: 
            begin                      
                RCRDY <= 1'b0;         
                DWE <= 1'b0;           
                DEN <= 1'b0;           
                DADDR <= DADDR;    
                DI <= drp_bitset | DI;
                MMCM_DRP_RST <= 1'b1;      
                w_cnt <= w_cnt;
            end                        
        WRITE: 
            begin                     
                RCRDY <= 1'b0;        
                DWE <= 1'b1;          
                DEN <= 1'b1;          
                DADDR <= drp_daddr;   
                DI <= DI;
                MMCM_DRP_RST <= 1'b1;     
                w_cnt <= w_cnt + 1'b1;
            end                       
        WAIT_W_RDY: 
            begin                     
                RCRDY <= 1'b0;        
                DWE <= 1'b0;          
                DEN <= 1'b0;          
                DADDR <= drp_daddr;   
                DI <= DI;
                MMCM_DRP_RST <= 1'b1;     
                w_cnt <= w_cnt;
            end                       
	   default:;
	endcase
end


//ila_1 ila_1_inst (
//	.clk(CLK), // input wire clk

//	.probe0(w_cnt), // input wire [3:0]  probe0  
//    .probe1(data), // input wire [47:0]  probe1
//    .probe2(current_state), // input wire [7:0]  probe2
//    .probe3(RCREG), // input wire [575:0]  probe3
//    .probe4(RCEN), // input wire [0:0]  probe4 
//    .probe5(RCRDY), // input wire [0:0]  probe5 
//    .probe6(DO), // input wire [15:0]  probe6 
//    .probe7(DRDY), // input wire [0:0]  probe7 
//    .probe8(LOCKED), // input wire [0:0]  probe8 
//    .probe9(DWE), // input wire [0:0]  probe9 
//    .probe10(DEN), // input wire [0:0]  probe10 
//    .probe11(DADDR), // input wire [6:0]  probe11 
//    .probe12(DI), // input wire [15:0]  probe12 
//    .probe13(DCLK), // input wire [0:0]  probe13 
//    .probe14(MMCM_DRP_RST), // input wire [0:0]  probe14
//    .probe15(drp_daddr), // input wire [6:0]  probe15 
//    .probe16(drp_bitmask), // input wire [15:0]  probe16 
//    .probe17(drp_bitset) // input wire [15:0]  probe17
    
//);

endmodule
