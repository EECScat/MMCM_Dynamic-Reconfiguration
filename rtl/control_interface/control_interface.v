`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: CCNU
// Engineer: Shen
// 
// Create Date: 2019/07/05 12:06:52
// Design Name: 
// Module Name: control_interface
// Project Name: 
// Target Devices: 
// Tool Versions: 
// Description: 
// 
// Dependencies: 
// 
// Revision:
// Revision 0.01 - File Created
// Revision 1.1 CONFIG_REG reset to '1' 
// 
// Additional Comments:
// 
//////////////////////////////////////////////////////////////////////////////////

module control_interface(
    input CLK,
    input RESET,
//-- From FPGA to PC
    output [35:0] FIFO_Q,  //interface fifo data output port
    output FIFO_EMPTY,  //: buffer std_logic;    -- interface fifo "emtpy" signal
    input FIFO_RDREQ,  //-- interface fifo read request
    input FIFO_RDCLK,  //-- interface fifo read clock
//-- From PC to FPGA, FWFT
    input [35:0] CMD_FIFO_Q,  //-- interface command fifo data out port
    input CMD_FIFO_EMPTY,  //-- interface command fifo "emtpy" signal
    output reg CMD_FIFO_RDREQ,  //-- interface command fifo read request
//-- Digital I/O
    output [639:0] CONFIG_REG,  //-- thirtytwo 16bit registers
    output [15:0] PULSE_REG,  //-- 16bit pulse register
    input [175:0] STATUS_REG,  //-- eleven 16bit registers
// -- Memory interface
    output MEM_WE,  //-- memory write enable
    output [31:0] MEM_ADDR,  //
    output [31:0] MEM_DIN,  //OUT std_logic_vector(31 DOWNTO 0);  -- memory data input
    input [31:0] MEM_DOUT,  //-- memory data output
//-- Data FIFO interface, FWFT
    input [31:0] DATA_FIFO_Q,
    input DATA_FIFO_EMPTY,
    //input DATA_FIFO_ALMOST_EMPTY,
    output DATA_FIFO_RDREQ,
    output DATA_FIFO_RDCLK
    
    );

// signals for FIFO
reg [4:0] bMemNotReg;
parameter SEL_REG = 4'd0,
        SEL_MEM = 4'd1,
        SEL_FIFO = 4'd2;
wire [35:0] sFifoD;
reg sFifoWrreq;
wire sFifoFull;
wire sFifoRst;
wire sFifoClk;

// signals for single-port RAM
reg sWea;
reg [31:0] sAddrA;
reg [31:0] sDinA;
wire [31:0] sDoutA;
reg [15:0] sDinReg;
reg [15:0] sMemioCnt;
reg [31:0] sMemLatch;


reg [639:0] sConfigReg;
reg [15:0] sPulseReg;
reg [15:0] sRegOut;

// signals for FIFO read
// to read data from a FIFO
reg [15:0] sDataFifoCount;
reg sDataFIFOrdreq;
reg [15:0] sDataFifoHigh;
reg [31:0] counterFIFO;  

reg [15:0] counterV;
reg [11:0]address_i;

reg [7:0] cmdState;
parameter INIT = 8'b0000_0001,
        WAIT_CMD = 8'b0000_0010,
        GET_CMD = 8'b0000_0100,
        INTERPRET_CMD = 8'b0000_1000,
        MEM_ADV = 8'b0001_0000,
        MEM_RD_CNT = 8'b0010_0000,
        PULSE_DELAY = 8'b0100_0000,
        FIFO_ADV = 8'b1000_0000;

                      
assign CONFIG_REG = sConfigReg;
assign PULSE_REG = sPulseReg;
assign MEM_WE = sWea;
assign MEM_ADDR = sAddrA;
assign MEM_DIN = sDinA;
assign sDoutA = MEM_DOUT;

//  -- data fifo
assign  DATA_FIFO_RDCLK = CLK;
assign DATA_FIFO_RDREQ = sDataFIFOrdreq;

//  -- data/event FIFO
assign sFifoRst = RESET;
assign sFifoClk = CLK;


assign sFifoD[35:32] = 4'b0000;  //-- these bits not used
assign sFifoD[31:0] = (bMemNotReg == SEL_MEM)? MEM_DOUT :
                        (bMemNotReg == SEL_FIFO) ? DATA_FIFO_Q:
                        {16'h0000, sRegOut};
// fifo used to buffer the datas prepared to be transmited to PC from FPGA 
fifo36x512 data_fifo(
    .rst(RESET),
    .wr_clk(CLK),
    .rd_clk(FIFO_RDCLK),
    .din(sFifoD),
    .wr_en(sFifoWrreq),
    .rd_en(FIFO_RDREQ),
    .dout(FIFO_Q),
    .full(),
    .empty(FIFO_EMPTY),
    .prog_full(sFifoFull),
    .wr_rst_busy(),
    .rd_rst_busy()
    );

always@(posedge CLK or posedge RESET)
begin
    if(RESET == 1'b1)
        begin
            counterV <= 16'd0;
            cmdState <= INIT;
            CMD_FIFO_RDREQ <= 1'b0;
            sConfigReg <= {640{1'b1}}; // sConfigReg <= ~(576'b0);
            sPulseReg <= 16'd0;
            sDinReg <= 16'd0;
            sMemioCnt <= 16'd0;
            sWea <= 1'b0;
            sAddrA <= 32'd0;
            sDinA <= 32'd0;
            sFifoWrreq     <= 1'b0;
            sRegOut        <= 16'd0;
            sDataFIFOrdreq <= 1'b0;
            bMemNotReg <= SEL_REG;
            address_i <= 12'd0;
            counterFIFO <= 32'd0;
            sDataFifoHigh <= 16'd0;
        end

    else
        begin
            //-- memory input
            sDinA[15:0] <= sDinReg;
            sDinA[31:16] <= CMD_FIFO_Q[15:0];
            // -- defaults:
            CMD_FIFO_RDREQ <= 1'b0;
            sFifoWrreq     <= 1'b0;
            sWea           <= 1'b0;
            sRegOut        <= 16'd0;
            sDataFIFOrdreq <= 1'b0;
            
            case(cmdState)
                INIT:// initialize registers to some sensible values
                    begin
                        //-- currently all 0
                        sConfigReg <= {640{1'b1}};
                        sPulseReg  <= 16'd0; 
                        sAddrA     <= 32'd0;
                        //-- at least 1 memory read
                        sMemioCnt  <= 16'd1;
                        cmdState   <= WAIT_CMD;
                    end
                WAIT_CMD:// Wait for CMD_FIFO words
                    begin
                        bMemNotReg <= SEL_REG;    //-- output registers
                        sPulseReg  <= 16'd0;   //-- reset pulse REGISTER
                        //-- wait for FIFO not empty
                        if(CMD_FIFO_EMPTY ==1'b0)
                            begin
                                CMD_FIFO_RDREQ <= 1'b1;
                                cmdState <= INTERPRET_CMD; //-- GET_CMD;
                                address_i <= CMD_FIFO_Q[27:16];
                            end
                    end
                //GET_CMD: // one wait state to get next CMD_FIFO word
                         // When FWFT FIFO is used, this state should be skipped.
                        //begin cmdState <= INTERPRET_CMD; end
                INTERPRET_CMD:// Now interpret the current CMD_FIFO output
                    /*---------------------------------------------------------------------
                    -- CMD_FIFO_Q format:
                    -- Q(31)      : READ/NOT_WRITE
                    -- Q(30:28)   : not used
                    -- Q(27:16)   : ADDRESS
                    -- Q(15:0)    : DATA
                    ---------------------------------------------------------------------*/
                    begin
                        //address_i <= CMD_FIFO_Q[27:16];
                        if(CMD_FIFO_Q[31] == 1'b1)
                            // a READ transaction ////////
                            casex(address_i)
                            12'b0000_001x_xxxx,
                            12'b0000_0100_0xxx:  // 
                                begin
                                    sRegOut <= sConfigReg[(address_i-32)*16+15-:16];
                                    sFifoWrreq <= 1'b1;
                                    cmdState <= WAIT_CMD;
                                end
                            12'b0000_0000_0xxx,
                            12'b0000_0000_100x,
                            12'b0000_0000_1010 :// 0 <= address_i <= 10 -- STATUS_REG
                                begin
                                    sRegOut <= STATUS_REG[address_i*16+15-:16];
                                    sFifoWrreq <= 1'b1;
                                    cmdState <= WAIT_CMD;
                                end
      
                            12'd16:    //   -- memory count REGISTER
                                begin
                                    sRegOut    <= sMemioCnt;
                                    sFifoWrreq <= 1'b1;
                                    cmdState   <= WAIT_CMD;
                                end 
                                
                            12'd17: // -- memory address LSB REGISTER
                                begin
                                    sRegOut <= sAddrA[15:0];
                                    sFifoWrreq <= 1'b1;
                                    cmdState <= WAIT_CMD;
                                end 
      
                            12'd18: //-- memory address MSB REGISTER
                                begin
                                    sRegOut    <= sAddrA[31:16];
                                    sFifoWrreq <= 1'b1;
                                    cmdState   <= WAIT_CMD;
                                end 
      
                            12'd20:  //-- read sMemioCnt 32bit memory words
                      //  -- reads 32bit memory words starting at the current
                      //  -- address sAddrA
                                begin
                                    counterV <= sMemioCnt;
                                    bMemNotReg <= SEL_MEM;  //  -- switch FIFO input to memory output
                                    if(sFifoFull == 1'b0)
                                        begin
                                            sFifoWrreq <= 1'b1;  //  -- latch current memory output
                                            sAddrA <= sAddrA + 1'b1; // -- and advance the address
                                            cmdState <= MEM_RD_CNT;
                                        end
                                    //else
                                end 
      
                            default:  //  -- bad address, return FFFF
                                begin
                                    sRegOut <= {16{1'b1}};
                                    sFifoWrreq <= 1'b1;
                                    cmdState   <= WAIT_CMD;
                                end 
                            endcase
                        else
                            // a WRITE transaction ////////
                            casex(address_i)
                            12'b0000_001x_xxxx,
                            12'b0000_0100_0xxx:     //  -- 32 <= address_i <= 71  -- CONFIG_REG
                                                    // 32~67 ( 36 * 16 = 576) for MMCM; 
                                begin
                                    sConfigReg[(address_i-32)*16+15-:16] <= CMD_FIFO_Q[15:0];
                                    cmdState <= WAIT_CMD;
                                end 
                            12'd11:  //  -- PULSE_REG
                                begin
                                    sPulseReg <= CMD_FIFO_Q[15:0];
                                    counterV <= 16'd2;  //  -- 2:60ns; define the pulse width
                                    cmdState <= PULSE_DELAY;
                                end 
      
                            12'd16:  //  -- memory count REGISTER
                                begin
                                    sMemioCnt <= CMD_FIFO_Q[15:0];
                                    cmdState  <= WAIT_CMD;
                                end 
      
                            12'd17:  //  -- memory address LSB REGISTER
                                begin
                                    sAddrA[15:0] <= CMD_FIFO_Q[15:0];
                                    cmdState <= WAIT_CMD;
                                end 
      
                            12'd18:  //  -- memory address MSB REGISTER
                                begin
                                    sAddrA[31:16] <= CMD_FIFO_Q[15:0];
                                    cmdState <= WAIT_CMD;
                                end 
      
                            12'd19:  //  -- memory LS16B
                                begin
                                    sDinReg  <= CMD_FIFO_Q[15:0];
                                    cmdState <= WAIT_CMD;
                                end  
      
                            12'd20:  //  -- memory MS16B
                            // -- raise WriteEnable for one clock, which clocks IN
                            // -- register 18 as LS16B and the data content of
                            // -- the CMD_FIFO word as MS16B
                                begin
                                    sWea     <= 1'b1;
                                    cmdState <= MEM_ADV;
                                end 
      
                            12'd25:  //  -- Data Fifo read count
                                begin
                                    counterFIFO <= {sDataFifoHigh[15:0],CMD_FIFO_Q[15:0]};
                                    bMemNotReg <= SEL_FIFO;
                                    //-- IF DATA_FIFO_EMPTY = '0' AND counterFIFO > 0 THEN
                                    cmdState <= FIFO_ADV;
                                    //-- ELSE
                                    //-- cmdState <= WAIT_CMD;
                                    //-- END IF;
                                end 
      
                            12'd26:
                                begin
                                    sDataFifoHigh <= CMD_FIFO_Q[15:0];
                                    cmdState <= WAIT_CMD;
                                end 
      
                            default:  //  -- bad address, do nothing
                                cmdState <= WAIT_CMD;
                            endcase
                    end
                
                MEM_ADV:  //  advance memory address
                    begin
                        sAddrA <= sAddrA + 1'b1;
                        cmdState <= WAIT_CMD;
                    end
                    
                MEM_RD_CNT:  //  read sMemioCnt memory addresses
                    begin
                        counterV <= counterV - 1'b1;
                        //  -- wait for FIFO not FULL
                        if(counterV == 16'd0)
                            //  -- Done
                            begin
                                cmdState <= WAIT_CMD;
                            end
                        else if(sFifoFull == 1'b0)
                            begin
                                //  -- latch current memory output
                                sFifoWrreq <= 1'b1;
                                //-- and advance address
                                sAddrA <= sAddrA + 1'b1;
                                cmdState <= MEM_RD_CNT;
                            end
                        else
                            begin
                                //  -- FIFO Full:
                                //  -- go back to previous count and wait for FIFO not full
                                counterV <= counterV + 1'b1;
                                cmdState <= MEM_RD_CNT;
                            end
                    end 

                    
                PULSE_DELAY:  //// delay two clocks to keep pulse high (total 3 clocks)
                    begin
                        
                        if(counterV == 16'b0)
                            cmdState <= WAIT_CMD;
                        else
                            begin
                                counterV <= counterV - 1'b1;
                                cmdState <= PULSE_DELAY;
                            end
                    end 

                FIFO_ADV:  // Data FIFO read
                    //  -- read data fifo, write reads to output fifo
                    //  -- exit when enough words were transferred
                    //  -- DATA_FIFO_EMPTY prematurely terminates the transfer
                    if(counterFIFO == 32'd0)
                        cmdState <= WAIT_CMD;
                    else if(DATA_FIFO_EMPTY == 1'b0)
                        begin
                            if(sFifoFull == 1'b0)
                                begin                                 
                                    sFifoWrreq <= 1'b1;               
                                    sDataFIFOrdreq <= 1'b1;           
                                    counterFIFO <= counterFIFO - 1'b1;
                                end                                   
//                            cmdState <= FIFO_ADV;
//                            if(sFifoFull == 1'b0)
//                                if(counterFIFO == 32'd0)
//                                    //-- we are done
//                                    cmdState <= WAIT_CMD;
//                                else
//                                    //-- more to copy
//                                    begin
//                                        sFifoWrreq <= 1'b1;
//                                        sDataFIFOrdreq <= 1'b1;
//                                        counterFIFO <= counterFIFO - 1'b1;
//                                    end
                            //else
                            //  cmdState <= WAIT_CMD;
                        end 
                            // shouldn't happen
                default:cmdState <= WAIT_CMD;
                    //  --  cmdState <= WAIT_CMD;
            endcase
        end
end


//ila_2 ila_2_inst (
//	.clk(CLK), // input wire clk
//	.probe0(CMD_FIFO_EMPTY), // input wire [0:0]  probe0  
//	.probe1(CMD_FIFO_Q), // input wire [35:0]  probe1 
//	.probe2(CMD_FIFO_RDREQ), // input wire [0:0]  probe2 
//	.probe3(cmdState), // input wire [7:0]  probe3 
//	.probe4(address_i), // input wire [11:0]  probe4
//	.probe5(sPulseReg), // input wire [15:0]  probe5 
//    .probe6(sConfigReg), // input wire [575:0]  probe6
//    .probe7(RESET) // input wire [0:0]  probe7
//);

endmodule
