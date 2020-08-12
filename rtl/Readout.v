`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: CCNU
// Engineer: Shen
// 
// Create Date: 2019/03/09 20:13:12
// Design Name: 
// Module Name: Readout
// Project Name: 
// Target Devices: 
// Tool Versions: 
// Description: 
// 
// Dependencies: 
// 
// Revision:
// Revision   0.01 File Created
// Additional Comments:
// 
//////////////////////////////////////////////////////////////////////////////////

module Readout(
    //system clock 200MHz
    input SYS_CLK_P,   
    input SYS_CLK_N,
    input CPU_RESET,   //  active high reset
     
    output MMCM_OUT_0,   // J11
    output MMCM_OUT_1,   // J12
    input SW2,         //AA12          
    
    // GBE PORT
    input SGMIICLK_Q0_P,  // SGMCLK 125Mhz
    input SGMIICLK_Q0_N, 
    output PHY_RESET_N,  
    output[3:0] RGMII_TXD,    
    output RGMII_TX_CTL, 
    output RGMII_TXC,    
    input[3:0] RGMII_RXD,     
    input RGMII_RX_CTL,  
    input RGMII_RXC,     
    inout MDIO,          
    output MDC
    );

///////////////////////////////////////////////////////////////////////////////////////
// wires and regs
///////////////////////////////////////////////////////////////////////////////////////

// reset & clks
wire reset;
wire sys_clk;

//gig_eth
wire clk_sgmii_i;
wire clk_sgmii_i_i;
wire[7:0] gig_eth_tx_tdata;
wire gig_eth_tx_tvalid;
wire gig_eth_tx_tready;
wire[7:0] gig_eth_rx_tdata;
wire gig_eth_rx_tvalid;
wire gig_eth_rx_tready;
wire gig_eth_tcp_use_fifo;
wire gig_eth_tx_fifo_wrclk;
wire[31:0] gig_eth_tx_fifo_q;
wire gig_eth_tx_fifo_wren;
wire gig_eth_tx_fifo_full;
wire gig_eth_rx_fifo_rdclk;
wire[31:0] gig_eth_rx_fifo_q;
wire gig_eth_rx_fifo_rden;
wire gig_eth_rx_fifo_empty;

//control interface
wire clk_control_interface;
wire[35:0] control_fifo_q;
wire control_fifo_empty;
wire control_fifo_rdreq;
wire control_fifo_rdclk;
wire[35:0] cmd_fifo_q;
wire cmd_fifo_empty;
wire cmd_fifo_rdreq;
wire[639:0] config_reg;
wire[15:0] pulse_reg;
wire[175:0] status_reg;
wire[31:0] user_data_fifo_dout;
wire user_data_fifo_empty;
wire user_data_fifo_rden;
wire user_data_fifo_rdclk;

///////////////////////////////////////////////////////////////////////////////////////
// clocks
///////////////////////////////////////////////////////////////////////////////////////

// global_clock_reset instance
global_clock_reset clockg_inst (
    .SYS_CLK_P(SYS_CLK_P),
    .SYS_CLK_N(SYS_CLK_N),
    .FORCE_RST(CPU_RESET),
    // output
    .GLOBAL_RST(reset),      //active High
    .SYS_CLK(sys_clk),    //200MHz
    .CLK_OUT1(),
    .CLK_OUT2(),
    .CLK_OUT3(clk_control_interface),
    .CLK_OUT4()
    );

// reconfigurable mmcm
// wire for mmcm
wire GLOBAL_RST;
wire rcen;
wire rcrdy;
assign rcen = rcrdy ? pulse_reg[0] : 1'b0;
// mmcm instance
mmcm mmcm_inst(
    .sys_clk_i(sys_clk),
    .FORCE_RESET(CPU_RESET),
    .RCREG(config_reg[575:0]),   // wire[575:0] rcreg;   
    .RCEN(rcen),    // wire rcen; 
    .RCRDY(rcrdy),       // wire rcrdy; 
    .GLOBAL_RST(GLOBAL_RST), 
    .CLK_OUT0( MMCM_OUT_0 ),  
    .CLK_OUT1( MMCM_OUT_1 ),  
    .CLK_OUT2(  ),   
    .CLK_OUT3(  ),   
    .CLK_OUT4(  ),   
    .CLK_OUT5(  ),   
    .CLK_OUT6(  )   
    );

///////////////////////////////////////////////////////////////////////////////////////
// gig_eth
///////////////////////////////////////////////////////////////////////////////////////
IBUFDS_GTE2 IBUFDS_GTE2_inst (
    .O(clk_sgmii_i),         // 1-bit output: Refer to Transceiver User Guide
    .ODIV2(), // 1-bit output: Refer to Transceiver User Guide
    .CEB(1'b0),    // 1-bit input: Refer to Transceiver User Guide
    .I(SGMIICLK_Q0_P),      // 1-bit input: Refer to Transceiver User Guide
    .IB(SGMIICLK_Q0_N)      // 1-bit input: Refer to Transceiver User Guide
    );

BUFG BUFG_inst (
    .O(clk_sgmii_i_i), // 1-bit output: Clock output
    .I(clk_sgmii_i)  // 1-bit input: Clock input
    );


gig_eth gig_eth_inst(
    // asynchronous reset
    .glbl_rst(reset),
    //-- clocks
    .gtx_clk(clk_sgmii_i_i),
    .ref_clk(sys_clk),
    // PHY interface
    .phy_resetn(PHY_RESET_N),           
    // RGMII Interface
    .rgmii_txd(RGMII_TXD),            
    .rgmii_tx_ctl(RGMII_TX_CTL),         
    .rgmii_txc(RGMII_TXC),            
    .rgmii_rxd(RGMII_RXD),            
    .rgmii_rx_ctl(RGMII_RX_CTL),         
    .rgmii_rxc(RGMII_RXC),            
    // MDIO Interface
    .mdio(MDIO),                 
    .mdc(MDC),                  
    // TCP
    .MAC_ADDR(48'h000a3502a758),             
    .IPv4_ADDR(32'hc0a80203),            // 192.168.2.3
    .IPv6_ADDR(128'h0),            
    .SUBNET_MASK(32'hffffff00),          
    .GATEWAY_IP_ADDR(32'hc0a80201),      
    .TCP_CONNECTION_RESET(1'b0), 
    .TX_TDATA(gig_eth_tx_tdata),             
    .TX_TVALID(gig_eth_tx_tvalid),            
    .TX_TREADY(gig_eth_tx_tready),            
    .RX_TDATA(gig_eth_rx_tdata),             
    .RX_TVALID(gig_eth_rx_tvalid),            
    .RX_TREADY(gig_eth_rx_tready),            
    // FIFO
    .TCP_USE_FIFO(gig_eth_tcp_use_fifo),         
    .TX_FIFO_WRCLK(gig_eth_tx_fifo_wrclk),        
    .TX_FIFO_Q(gig_eth_tx_fifo_q),        //data form FPGA to PC    
    .TX_FIFO_WREN(gig_eth_tx_fifo_wren),         
    .TX_FIFO_FULL(gig_eth_tx_fifo_full),         
    .RX_FIFO_RDCLK(gig_eth_rx_fifo_rdclk),        
    .RX_FIFO_Q(gig_eth_rx_fifo_q),        //data from PC to FPGA    
    .RX_FIFO_RDEN(gig_eth_rx_fifo_rden),         
    .RX_FIFO_EMPTY(gig_eth_rx_fifo_empty)        
    );

// loopback
assign gig_eth_tx_tdata  = gig_eth_rx_tdata;
assign gig_eth_tx_tvalid = gig_eth_rx_tvalid;
assign gig_eth_rx_tready = gig_eth_tx_tready;
// tcp fifo config
assign gig_eth_tcp_use_fifo  =1 'b1;
assign gig_eth_tx_fifo_wrclk = clk_sgmii_i_i;
assign gig_eth_tx_fifo_q     = control_fifo_q[31:0];
assign gig_eth_tx_fifo_wren  = (! control_fifo_empty) && (! gig_eth_tx_fifo_full);
assign gig_eth_rx_fifo_rdclk = clk_control_interface;
assign gig_eth_rx_fifo_rden  = cmd_fifo_rdreq;
// port connection
assign control_fifo_rdreq   = gig_eth_tx_fifo_wren;
assign control_fifo_rdclk   = gig_eth_tx_fifo_wrclk;
assign cmd_fifo_q           = {4'b0000 , gig_eth_rx_fifo_q};
assign cmd_fifo_empty       = gig_eth_rx_fifo_empty;

///////////////////////////////////////////////////////////////////////////////////////
// control_interface instance
///////////////////////////////////////////////////////////////////////////////////////


control_interface control_interface_inst(
    .RESET(reset),
    .CLK(clk_control_interface),
    // From FPGA to PC
    .FIFO_Q(control_fifo_q),  // interface fifo data output port
    .FIFO_EMPTY(control_fifo_empty),    // interface fifo "emtpy" signal
    .FIFO_RDREQ(control_fifo_rdreq),    // interface fifo read request
    .FIFO_RDCLK(control_fifo_rdclk),    // interface fifo read clock
    // From PC to FPGA, FWFT
    .CMD_FIFO_Q(cmd_fifo_q),  // interface command fifo data out port
    .CMD_FIFO_EMPTY(cmd_fifo_empty),    // interface command fifo "emtpy" signal
    .CMD_FIFO_RDREQ(cmd_fifo_rdreq),    // interface command fifo read request
    // Digital I/O
    .CONFIG_REG(config_reg), // thirtytwo 16bit registers
    .PULSE_REG(pulse_reg),  // 16bit pulse register
    .STATUS_REG(status_reg), // eleven 16bit registers
    // Memory interface
    .MEM_WE(),
    .MEM_ADDR(),
    .MEM_DIN(),
    .MEM_DOUT(),
    // Data FIFO interface, FWFT
    .DATA_FIFO_Q(user_data_fifo_dout),
    .DATA_FIFO_EMPTY(user_data_fifo_empty),
    .DATA_FIFO_RDREQ(user_data_fifo_rden),
    .DATA_FIFO_RDCLK(user_data_fifo_rdclk)
    );
///////////////////////////////////////////////////////////////////////////////////////
// user function
///////////////////////////////////////////////////////////////////////////////////////

endmodule
