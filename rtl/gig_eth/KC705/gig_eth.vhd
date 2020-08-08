--------------------------------------------------------------------------------
-- File       : tri_mode_ethernet_mac_0_example_design.vhd
-- Author     : Xilinx Inc.
-- -----------------------------------------------------------------------------
-- (c) Copyright 2004-2013 Xilinx, Inc. All rights reserved.
--
-- This file contains confidential and proprietary information
-- of Xilinx, Inc. and is protected under U.S. and
-- international copyright and other intellectual property
-- laws.
--
-- DISCLAIMER
-- This disclaimer is not a license and does not grant any
-- rights to the materials distributed herewith. Except as
-- otherwise provided in a valid license issued to you by
-- Xilinx, and to the maximum extent permitted by applicable
-- law: (1) THESE MATERIALS ARE MADE AVAILABLE "AS IS" AND
-- WITH ALL FAULTS, AND XILINX HEREBY DISCLAIMS ALL WARRANTIES
-- AND CONDITIONS, EXPRESS, IMPLIED, OR STATUTORY, INCLUDING
-- BUT NOT LIMITED TO WARRANTIES OF MERCHANTABILITY, NON-
-- INFRINGEMENT, OR FITNESS FOR ANY PARTICULAR PURPOSE; and
-- (2) Xilinx shall not be liable (whether in contract or tort,
-- including negligence, or under any other theory of
-- liability) for any loss or damage of any kind or nature
-- related to, arising under or in connection with these
-- materials, including for any direct, or any indirect,
-- special, incidental, or consequential loss or damage
-- (including loss of data, profits, goodwill, or any type of
-- loss or damage suffered as a result of any action brought
-- by a third party) even if such damage or loss was
-- reasonably foreseeable or Xilinx had been advised of the
-- possibility of the same.
--
-- CRITICAL APPLICATIONS
-- Xilinx products are not designed or intended to be fail-
-- safe, or for use in any application requiring fail-safe
-- performance, such as life-support or safety devices or
-- systems, Class III medical devices, nuclear facilities,
-- applications related to the deployment of airbags, or any
-- other applications that could lead to death, personal
-- injury, or severe property or environmental damage
-- (individually and collectively, "Critical
-- Applications"). Customer assumes the sole risk and
-- liability of any use of Xilinx products in Critical
-- Applications, subject only to applicable laws and
-- regulations governing limitations on product liability.
--
-- THIS COPYRIGHT NOTICE AND DISCLAIMER MUST BE RETAINED AS
-- PART OF THIS FILE AT ALL TIMES. 
-- -----------------------------------------------------------------------------
-- Description:  This is the Verilog example design for the Tri-Mode
--               Ethernet MAC core. It is intended that this example design
--               can be quickly adapted and downloaded onto an FPGA to provide
--               a real hardware test environment.
--
--               This level:
--
--               * Instantiates the FIFO Block wrapper, containing the
--                 block level wrapper and an RX and TX FIFO with an
--                 AXI-S interface;
--
--               * Instantiates a simple AXI-S example design,
--                 providing an address swap and a simple
--                 loopback function;
--
--               * Instantiates transmitter clocking circuitry
--                   -the User side of the FIFOs are clocked at gtx_clk
--                    at all times
--
--               * Instantiates a state machine which drives the AXI Lite
--                 interface to bring the TEMAC up in the correct state
--
--               * Serializes the Statistics vectors to prevent logic being
--                 optimized out
--
--               * Ties unused inputs off to reduce the number of IO
--
--               Please refer to the Datasheet, Getting Started Guide, and
--               the Tri-Mode Ethernet MAC User Gude for further information.
--
--
--    --------------------------------------------------
--    | EXAMPLE DESIGN WRAPPER                         |
--    |                                                |
--    |                                                |
--    |   -------------------     -------------------  |
--    |   |                 |     |                 |  |
--    |   |    Clocking     |     |     Resets      |  |
--    |   |                 |     |                 |  |
--    |   -------------------     -------------------  |
--    |           -------------------------------------|
--    |           |FIFO BLOCK WRAPPER                  |
--    |           |                                    |
--    |           |                                    |
--    |           |              ----------------------|
--    |           |              | SUPPORT LEVEL       |
--    | --------  |              |                     |
--    | |      |  |              |                     |
--    | | AXI  |->|------------->|                     |
--    | | LITE |  |              |                     |
--    | |  SM  |  |              |                     |
--    | |      |<-|<-------------|                     |
--    | |      |  |              |                     |
--    | --------  |              |                     |
--    |           |              |                     |
--    | --------  |  ----------  |                     |
--    | |      |  |  |        |  |                     |
--    | |      |->|->|        |->|                     |
--    | | PAT  |  |  |        |  |                     |
--    | | GEN  |  |  |        |  |                     |
--    | |(ADDR |  |  |  AXI-S |  |                     |
--    | | SWAP)|  |  |  FIFO  |  |                     |
--    | |      |  |  |        |  |                     |
--    | |      |  |  |        |  |                     |
--    | |      |  |  |        |  |                     |
--    | |      |<-|<-|        |<-|                     |
--    | |      |  |  |        |  |                     |
--    | --------  |  ----------  |                     |
--    |           |              |                     |
--    |           |              ----------------------|
--    |           -------------------------------------|
--    --------------------------------------------------

--------------------------------------------------------

library unisim;
use unisim.vcomponents.all;

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.com5402pkg.all;

--------------------------------------------------------------------------------
-- The entity declaration for the example_design level wrapper.
--------------------------------------------------------------------------------

entity gig_eth is
    port (
      -- asynchronous reset
      glbl_rst                      : in  std_logic;

      -- clocks
      gtx_clk                       : in  std_logic;  -- 125MHz
      ref_clk                       : in  std_logic;  -- 200MHz

      -- PHY interface
      phy_resetn                    : out std_logic;

      -- RGMII Interface
      ------------------
      rgmii_txd                     : out std_logic_vector(3 downto 0);
      rgmii_tx_ctl                  : out std_logic;
      rgmii_txc                     : out std_logic;
      rgmii_rxd                     : in  std_logic_vector(3 downto 0);
      rgmii_rx_ctl                  : in  std_logic;
      rgmii_rxc                     : in  std_logic;

      -- MDIO Interface
      -----------------
      mdio                          : inout std_logic;
      mdc                           : out std_logic;

      -- TCP
      MAC_ADDR                      : IN  std_logic_vector(47 DOWNTO 0);
      IPv4_ADDR                     : IN  std_logic_vector(31 DOWNTO 0);
      IPv6_ADDR                     : IN  std_logic_vector(127 DOWNTO 0);
      SUBNET_MASK                   : IN  std_logic_vector(31 DOWNTO 0);
      GATEWAY_IP_ADDR               : IN  std_logic_vector(31 DOWNTO 0);
      TCP_CONNECTION_RESET          : IN  std_logic;
      TX_TDATA                      : IN  std_logic_vector(7 downto 0);
      TX_TVALID                     : IN  std_logic;
      TX_TREADY                     : OUT std_logic;
      RX_TDATA                      : OUT std_logic_vector(7 downto 0);
      RX_TVALID                     : OUT std_logic;
      RX_TREADY                     : IN  std_logic;
      -- FIFO
      TCP_USE_FIFO                  : IN  std_logic;
      TX_FIFO_WRCLK                 : IN  std_logic;
      TX_FIFO_Q                     : IN  std_logic_vector(31 downto 0);
      TX_FIFO_WREN                  : IN  std_logic;     
      TX_FIFO_FULL                  : OUT std_logic;
      RX_FIFO_RDCLK                 : IN  std_logic;
      RX_FIFO_Q                     : OUT std_logic_vector(31 downto 0);
      RX_FIFO_RDEN                  : IN  std_logic;     
      RX_FIFO_EMPTY                 : OUT std_logic
    );
end gig_eth;

architecture wrapper of gig_eth is

  attribute DowngradeIPIdentifiedWarnings: string;
  attribute DowngradeIPIdentifiedWarnings of wrapper : architecture is "yes";

  COMPONENT COM5402 IS
    GENERIC (
      CLK_FREQUENCY   : integer               := 125;
      -- CLK frequency in MHz. Needed to compute actual delays.
      TX_IDLE_TIMEOUT : integer RANGE 0 TO 50 := 50;
      -- inactive input timeout, expressed in 4us units. -- 50*4us = 200us 
      -- Controls the transmit stream segmentation: data in the elastic buffer will be transmitted if
      -- no input is received within TX_IDLE_TIMEOUT, without waiting for the transmit frame to be filled with MSS data bytes.
      SIMULATION      : std_logic             := '0'
     -- 1 during simulation with Wireshark .cap file, '0' otherwise
     -- Wireshark many not be able to collect offloaded checksum computations.
     -- when SIMULATION =  '1': (a) IP header checksum is valid if 0000,
     -- (b) TCP checksum computation is forced to a valid 00001 irrespective of the 16-bit checksum
     -- captured by Wireshark.
    );
    PORT (
      --//-- CLK, RESET
      CLK         : IN std_logic;
      -- All signals are synchronous with CLK
      -- CLK must be a global clock 125 MHz or faster to match the Gbps MAC speed.
      ASYNC_RESET : IN std_logic;  -- to be phased out. replace with SYNC_RESET
      SYNC_RESET  : IN std_logic;

      --//-- CONFIGURATION
      -- configuration signals are synchonous with CLK
      -- Synchronous with CLK clock.
      MAC_ADDR        : IN std_logic_vector(47 DOWNTO 0);
      IPv4_ADDR       : IN std_logic_vector(31 DOWNTO 0);
      IPv6_ADDR       : IN std_logic_vector(127 DOWNTO 0);
      SUBNET_MASK     : IN std_logic_vector(31 DOWNTO 0);
      GATEWAY_IP_ADDR : IN std_logic_vector(31 DOWNTO 0);
      -- local IP address. 4 bytes for IPv4, 16 bytes for IPv6
      -- Natural order (MSB) 172.16.1.128 (LSB) as transmitted in the IP frame.

      --// User-initiated connection reset for stream I
      CONNECTION_RESET : IN std_logic_vector((NTCPSTREAMS-1) DOWNTO 0);

      --//-- Protocol -> Transmit MAC Interface
      -- 32-bit CRC is automatically appended by the MAC layer. User should not supply it.
      -- Synchonous with the user-side CLK
      MAC_TX_DATA       : OUT std_logic_vector(7 DOWNTO 0);
      -- MAC reads the data at the rising edge of CLK when MAC_TX_DATA_VALID = '1'
      MAC_TX_DATA_VALID : OUT std_logic;
      -- data valid
      MAC_TX_SOF        : out std_logic;
      -- start of frame: '1' when sending the first byte.
      MAC_TX_EOF        : OUT std_logic;
      -- '1' when sending the last byte in a packet to be transmitted. 
      -- Aligned with MAC_TX_DATA_VALID
      MAC_TX_CTS        : IN  std_logic;
      -- MAC-generated Clear To Send flow control signal, indicating room in the 
      -- MAC tx elastic buffer for a complete maximum size frame 1518B. 
      -- The user should check that this signal is high before deciding to send
      -- sending the next frame. 
      -- Note: MAC_TX_CTS may go low while the frame is transfered in. Ignore it as space is guaranteed
      -- at the start of frame.

      --//-- Receive MAC -> Protocol
      -- Valid rx packets only: packets with bad CRC or invalid address are discarded.
      -- The 32-bit CRC is always removed by the MAC layer.
      -- Synchonous with the user-side CLK
      MAC_RX_DATA       : IN std_logic_vector(7 DOWNTO 0);
      -- USER reads the data at the rising edge of CLK when MAC_RX_DATA_VALID = '1'
      MAC_RX_DATA_VALID : IN std_logic;
      -- data valid
      MAC_RX_SOF        : IN std_logic;
      -- '1' when sending the first byte in a received packet. 
      -- Aligned with MAC_RX_DATA_VALID
      MAC_RX_EOF        : IN std_logic;
      -- '1' when sending the last byte in a received packet. 
      -- Aligned with MAC_RX_DATA_VALID

      --//-- Application <- UDP rx
      UDP_RX_DATA         : OUT std_logic_vector(7 DOWNTO 0);
      UDP_RX_DATA_VALID   : OUT std_logic;
      UDP_RX_SOF          : OUT std_logic;
      UDP_RX_EOF          : OUT std_logic;
      -- 1 CLK pulse indicating that UDP_RX_DATA is the last byte in the UDP data field.
      -- ALWAYS CHECK UDP_RX_DATA_VALID at the end of packet (UDP_RX_EOF = '1') to confirm
      -- that the UDP packet is valid. External buffer may have to backtrack to the the last
      -- valid pointer to discard an invalid UDP packet.
      -- Reason: we only knows about bad UDP packets at the end.
      UDP_RX_DEST_PORT_NO : IN  std_logic_vector(15 DOWNTO 0);

      --//-- Application -> UDP tx
      UDP_TX_DATA           : IN  std_logic_vector(7 DOWNTO 0);
      UDP_TX_DATA_VALID     : IN  std_logic;
      UDP_TX_SOF            : IN  std_logic;  -- 1 CLK-wide pulse to mark the first byte in the tx UDP frame
      UDP_TX_EOF            : IN  std_logic;  -- 1 CLK-wide pulse to mark the last byte in the tx UDP frame
      UDP_TX_CTS            : OUT std_logic;
      UDP_TX_ACK            : OUT std_logic;  -- 1 CLK-wide pulse indicating that the previous UDP frame is being sent
      UDP_TX_NAK            : OUT std_logic;  -- 1 CLK-wide pulse indicating that the previous UDP frame could not be sent
      UDP_TX_DEST_IP_ADDR   : IN  std_logic_vector(127 DOWNTO 0);
      UDP_TX_DEST_PORT_NO   : IN  std_logic_vector(15 DOWNTO 0);
      UDP_TX_SOURCE_PORT_NO : IN  std_logic_vector(15 DOWNTO 0);

      --//-- Application <- TCP rx
      -- NTCPSTREAMS can operate independently. Only one stream active at any given time.
      -- Data is pushed out. Limited flow-control here. Receipient must be able to accept data
      -- at any time (in other words, it is the receipient's responsibility to have elastic 
      -- buffer if needed).
      TCP_RX_DATA       : OUT SLV8xNTCPSTREAMStype;
      TCP_RX_DATA_VALID : OUT std_logic_vector((NTCPSTREAMS-1) DOWNTO 0);
      TCP_RX_RTS        : OUT std_logic;
      TCP_RX_CTS        : IN  std_logic;
      -- Optional Clear-To-Send. pull to '1' when output flow control is unused.
      -- WARNING: pulling CTS down will stop the flow for ALL streams.

      --//-- Application -> TCP tx
      -- NTCPSTREAMS can operate independently and concurrently. No scheduling arbitration needed here.
      TCP_TX_DATA       : IN  SLV8xNTCPSTREAMStype;
      TCP_TX_DATA_VALID : IN  std_logic_vector((NTCPSTREAMS-1) DOWNTO 0);
      TCP_TX_CTS        : OUT std_logic_vector((NTCPSTREAMS-1) DOWNTO 0);
      -- Clear To Send = transmit flow control. 
      -- App is responsible for checking the CTS signal before sending APP_DATA

      --//-- TEST POINTS, COMSCOPE TRACES
      CS1     : OUT std_logic_vector(7 DOWNTO 0);
      CS1_CLK : OUT std_logic;
      CS2     : OUT std_logic_vector(7 DOWNTO 0);
      CS2_CLK : OUT std_logic;
      TP      : OUT std_logic_vector(10 DOWNTO 1)
    );
  END COMPONENT;
  -- Must have programmable full with single-threshold of 61
  -- out of total write-depth 64
  COMPONENT fifo8to32
    PORT (
      rst       : IN  std_logic;
      wr_clk    : IN  std_logic;
      rd_clk    : IN  std_logic;
      din       : IN  std_logic_vector(7 DOWNTO 0);
      wr_en     : IN  std_logic;
      rd_en     : IN  std_logic;
      dout      : OUT std_logic_vector(31 DOWNTO 0);
      full      : OUT std_logic;
      prog_full : OUT std_logic;
      empty     : OUT std_logic
    );
  END COMPONENT;

  COMPONENT fifo32to8
    PORT (
      rst    : IN  std_logic;
      wr_clk : IN  std_logic;
      rd_clk : IN  std_logic;
      din    : IN  std_logic_vector(31 DOWNTO 0);
      wr_en  : IN  std_logic;
      rd_en  : IN  std_logic;
      dout   : OUT std_logic_vector(7 DOWNTO 0);
      full   : OUT std_logic;
      empty  : OUT std_logic
    );
  END COMPONENT;

  ------------------------------------------------------------------------------
  -- Component Declaration for the Tri-Mode EMAC core FIFO Block wrapper
  ------------------------------------------------------------------------------

   component tri_mode_ethernet_mac_0_fifo_block
   port(
      gtx_clk                    : in  std_logic;
      -- asynchronous reset
      glbl_rstn                  : in  std_logic;
      rx_axi_rstn                : in  std_logic;
      tx_axi_rstn                : in  std_logic;

      -- Reference clock for IDELAYCTRL's
      refclk                     : in  std_logic;

      -- Receiver Statistics Interface
      -----------------------------------------
      rx_mac_aclk                : out std_logic;
      rx_reset                   : out std_logic;
      rx_statistics_vector       : out std_logic_vector(27 downto 0);
      rx_statistics_valid        : out std_logic;

      -- Receiver (AXI-S) Interface
      ------------------------------------------
      rx_fifo_clock              : in  std_logic;
      rx_fifo_resetn             : in  std_logic;
      rx_axis_fifo_tdata         : out std_logic_vector(7 downto 0);
      rx_axis_fifo_tvalid        : out std_logic;
      rx_axis_fifo_tready        : in  std_logic;
      rx_axis_fifo_tlast         : out std_logic;

      -- Transmitter Statistics Interface
      --------------------------------------------
      tx_mac_aclk                : out std_logic;
      tx_reset                   : out std_logic;
      tx_ifg_delay               : in  std_logic_vector(7 downto 0);
      tx_statistics_vector       : out std_logic_vector(31 downto 0);
      tx_statistics_valid        : out std_logic;

      -- Transmitter (AXI-S) Interface
      ---------------------------------------------
      tx_fifo_clock              : in  std_logic;
      tx_fifo_resetn             : in  std_logic;
      tx_axis_fifo_tdata         : in  std_logic_vector(7 downto 0);
      tx_axis_fifo_tvalid        : in  std_logic;
      tx_axis_fifo_tready        : out std_logic;
      tx_axis_fifo_tlast         : in  std_logic;

      -- MAC Control Interface
      --------------------------
      pause_req                  : in  std_logic;
      pause_val                  : in  std_logic_vector(15 downto 0);

      -- RGMII Interface
      --------------------
      rgmii_txd                  : out std_logic_vector(3 downto 0);
      rgmii_tx_ctl               : out std_logic;
      rgmii_txc                  : out std_logic;
      rgmii_rxd                  : in  std_logic_vector(3 downto 0);
      rgmii_rx_ctl               : in  std_logic;
      rgmii_rxc                  : in  std_logic;

      -- RGMII Inband Status Registers
      ----------------------------------
      inband_link_status        : out std_logic;
      inband_clock_speed        : out std_logic_vector(1 downto 0);
      inband_duplex_status      : out std_logic;

      -- MDIO Interface
      -------------------
      mdio                      : inout std_logic;
      mdc                       : out std_logic;
      -- AXI-Lite Interface
      -----------------
      s_axi_aclk                : in  std_logic;
      s_axi_resetn              : in  std_logic;

      s_axi_awaddr              : in  std_logic_vector(11 downto 0);
      s_axi_awvalid             : in  std_logic;
      s_axi_awready             : out std_logic;

      s_axi_wdata               : in  std_logic_vector(31 downto 0);
      s_axi_wvalid              : in  std_logic;
      s_axi_wready              : out std_logic;

      s_axi_bresp               : out std_logic_vector(1 downto 0);
      s_axi_bvalid              : out std_logic;
      s_axi_bready              : in  std_logic;

      s_axi_araddr              : in  std_logic_vector(11 downto 0);
      s_axi_arvalid             : in  std_logic;
      s_axi_arready             : out std_logic;

      s_axi_rdata               : out std_logic_vector(31 downto 0);
      s_axi_rresp               : out std_logic_vector(1 downto 0);
      s_axi_rvalid              : out std_logic;
      s_axi_rready              : in  std_logic
   );
   end component;

  ------------------------------------------------------------------------------
  -- Component Declaration for the AXI-Lite State machine
  ------------------------------------------------------------------------------

   component tri_mode_ethernet_mac_0_axi_lite_sm
   port (
      s_axi_aclk                : in  std_logic;
      s_axi_resetn              : in  std_logic;

      mac_speed                 : in  std_logic_vector(1 downto 0);
      update_speed              : in  std_logic;
      serial_command            : in  std_logic;
      serial_response           : out std_logic;
      phy_loopback              : in  std_logic;

      s_axi_awaddr              : out std_logic_vector(11 downto 0);
      s_axi_awvalid             : out std_logic;
      s_axi_awready             : in  std_logic;

      s_axi_wdata               : out std_logic_vector(31 downto 0);
      s_axi_wvalid              : out std_logic;
      s_axi_wready              : in  std_logic;

      s_axi_bresp               : in  std_logic_vector(1 downto 0);
      s_axi_bvalid              : in  std_logic;
      s_axi_bready              : out std_logic;

      s_axi_araddr              : out std_logic_vector(11 downto 0);
      s_axi_arvalid             : out std_logic;
      s_axi_arready             : in  std_logic;

      s_axi_rdata               : in  std_logic_vector(31 downto 0);
      s_axi_rresp               : in  std_logic_vector(1 downto 0);
      s_axi_rvalid              : in  std_logic;
      s_axi_rready              : out std_logic
   );
   end component;

  ------------------------------------------------------------------------------
  -- Component declaration for the synchroniser
  ------------------------------------------------------------------------------
  component tri_mode_ethernet_mac_0_sync_block
  port (
     clk                        : in  std_logic;
     data_in                    : in  std_logic;
     data_out                   : out std_logic
  );
  end component;

  ------------------------------------------------------------------------------
  -- Component declaration for the reset logic
  ------------------------------------------------------------------------------
  component tri_mode_ethernet_mac_0_example_design_resets is
  port (
     -- clocks
     s_axi_aclk                 : in std_logic;
     gtx_clk                    : in std_logic;

     -- asynchronous resets
     glbl_rst                   : in std_logic;
     reset_error                : in std_logic;
     rx_reset                   : in std_logic;
     tx_reset                   : in std_logic;

     dcm_locked                 : in std_logic;

     -- synchronous reset outputs
     glbl_rst_intn              : out std_logic;
     gtx_resetn                 : out std_logic := '0';
     s_axi_resetn               : out std_logic := '0';
     phy_resetn                 : out std_logic;
     chk_resetn                 : out std_logic := '0'
   );
   end component;

   ------------------------------------------------------------------------------
   -- internal signals used in this top level wrapper.
   ------------------------------------------------------------------------------

   -- example design clocks
   signal gtx_clk_bufg                       : std_logic;
   signal refclk_bufg                        : std_logic;
   signal s_axi_aclk                         : std_logic;
   signal rx_mac_aclk                        : std_logic;
   signal tx_mac_aclk                        : std_logic;
   signal phy_resetn_int                     : std_logic;
   -- resets (and reset generation)
   signal reset_error                        : std_logic;
   signal s_axi_resetn                       : std_logic;
   signal chk_resetn                         : std_logic;
   signal gtx_resetn                         : std_logic;
   signal rx_reset                           : std_logic;
   signal tx_reset                           : std_logic;

   signal dcm_locked                         : std_logic;
   signal glbl_rst_int                       : std_logic;
   signal phy_reset_count                    : unsigned(5 downto 0) := (others => '0');
   signal glbl_rst_intn                      : std_logic;

   signal mac_speed                          : std_logic_vector(1 downto 0);
   signal serial_response                    : std_logic;
   signal frame_error                        : std_logic;
   signal frame_errorn                       : std_logic;
   signal activity_flash                     : std_logic;
   signal activity_flashn                    : std_logic;

   signal update_speed                       : std_logic := '0';
   signal config_board                       : std_logic := '0';

   -- USER side RX AXI-S interface
   signal rx_fifo_clock                      : std_logic;
   signal rx_fifo_resetn                     : std_logic;
   signal rx_axis_fifo_tdata                 : std_logic_vector(7 downto 0);
   signal rx_axis_fifo_tvalid                : std_logic;
   signal rx_axis_fifo_tlast                 : std_logic;
   signal rx_axis_fifo_tready                : std_logic;

   -- USER side TX AXI-S interface
   signal tx_fifo_clock                      : std_logic;
   signal tx_fifo_resetn                     : std_logic;
   signal tx_axis_fifo_tdata                 : std_logic_vector(7 downto 0);
   signal tx_axis_fifo_tvalid                : std_logic;
   signal tx_axis_fifo_tlast                 : std_logic;
   signal tx_axis_fifo_tready                : std_logic;

   -- RX Statistics serialisation signals
   signal rx_statistics_s                    : std_logic := '0';
   signal rx_statistics_valid                : std_logic;
   signal rx_statistics_valid_reg            : std_logic;
   signal rx_statistics_vector               : std_logic_vector(27 downto 0);
   signal rx_stats                           : std_logic_vector(27 downto 0);
   signal rx_stats_shift                     : std_logic_vector(29 downto 0);
   signal rx_stats_toggle                    : std_logic := '0';
   signal rx_stats_toggle_sync               : std_logic;
   signal rx_stats_toggle_sync_reg           : std_logic := '0';

   -- TX Statistics serialisation signals
   signal tx_statistics_s                    : std_logic := '0';
   signal tx_statistics_valid                : std_logic;
   signal tx_statistics_valid_reg            : std_logic;
   signal tx_statistics_vector               : std_logic_vector(31 downto 0);
   signal tx_stats                           : std_logic_vector(31 downto 0);
   signal tx_stats_shift                     : std_logic_vector(33 downto 0);
   signal tx_stats_toggle                    : std_logic := '0';
   signal tx_stats_toggle_sync               : std_logic;
   signal tx_stats_toggle_sync_reg           : std_logic := '0';

   -- Pause interface DESerialisation
   signal pause_req_s                        : std_logic := '0';
   signal pause_shift                        : std_logic_vector(18 downto 0);
   signal pause_req                          : std_logic;
   signal pause_val                          : std_logic_vector(15 downto 0);

   -- AXI-Lite interface
   signal s_axi_awaddr                       : std_logic_vector(11 downto 0);
   signal s_axi_awvalid                      : std_logic;
   signal s_axi_awready                      : std_logic;
   signal s_axi_wdata                        : std_logic_vector(31 downto 0);
   signal s_axi_wvalid                       : std_logic;
   signal s_axi_wready                       : std_logic;
   signal s_axi_bresp                        : std_logic_vector(1 downto 0);
   signal s_axi_bvalid                       : std_logic;
   signal s_axi_bready                       : std_logic;
   signal s_axi_araddr                       : std_logic_vector(11 downto 0);
   signal s_axi_arvalid                      : std_logic;
   signal s_axi_arready                      : std_logic;
   signal s_axi_rdata                        : std_logic_vector(31 downto 0);
   signal s_axi_rresp                        : std_logic_vector(1 downto 0);
   signal s_axi_rvalid                       : std_logic;
   signal s_axi_rready                       : std_logic;

   -- signal tie offs
   signal tx_ifg_delay                       : std_logic_vector(7 downto 0) := (others => '0');    -- not used in this example

  signal inband_link_status                  : std_logic;
  signal inband_clock_speed                  : std_logic_vector(1 downto 0);
  signal inband_duplex_status                : std_logic;
  signal int_frame_error                     : std_logic;
  signal int_activity_flash                  : std_logic;

  -- set board defaults - only updated when reprogrammed
  signal enable_phy_loopback                 : std_logic := '0';

  -- tcp
  SIGNAL tcp_mac_addr             : std_logic_vector(47 DOWNTO 0);
  SIGNAL tcp_ipv4_addr            : std_logic_vector(31 DOWNTO 0);
  SIGNAL tcp_ipv6_addr            : std_logic_vector(127 DOWNTO 0);
  SIGNAL tcp_subnet_mask          : std_logic_vector(31 DOWNTO 0);
  SIGNAL tcp_gateway_ip_addr      : std_logic_vector(31 DOWNTO 0);
  --
  SIGNAL mac_rx_sof               : std_logic;
  SIGNAL tcp_rx_data              : std_logic_vector(7 DOWNTO 0);
  SIGNAL tcp_rx_data_valid        : std_logic;
  SIGNAL tcp_rx_rts               : std_logic;
  SIGNAL tcp_rx_cts               : std_logic;
  SIGNAL tcp_tx_data              : std_logic_vector(7 DOWNTO 0);
  SIGNAL tcp_tx_data_valid        : std_logic;
  SIGNAL tcp_tx_cts               : std_logic;
  --
  SIGNAL tcp_rx_data_slv8x        : SLV8xNTCPSTREAMStype;
  SIGNAL tcp_tx_data_slv8x        : SLV8xNTCPSTREAMStype;
  SIGNAL tcp_rx_data_valid_vector : std_logic_vector((NTCPSTREAMS-1) DOWNTO 0);
  SIGNAL tcp_tx_cts_vector        : std_logic_vector((NTCPSTREAMS-1) DOWNTO 0);
  --
  SIGNAL rx_fifo_full             : std_logic;
  SIGNAL rx_fifo_fullm3           : std_logic;
  SIGNAL tx_fifo_dout             : std_logic_vector(7 DOWNTO 0);
  SIGNAL tx_fifo_rden             : std_logic;
  SIGNAL tx_fifo_empty            : std_logic;
  --
  SIGNAL connection_reset_v       : std_logic_vector((NTCPSTREAMS-1) DOWNTO 0);
  SIGNAL tcp_tx_data_valid_v      : std_logic_vector((NTCPSTREAMS-1) DOWNTO 0);
  
  ------------------------------------------------------------------------------
  -- Begin architecture
  ------------------------------------------------------------------------------

begin

   frame_error  <= int_frame_error;
   frame_errorn <= not int_frame_error;
   activity_flash  <= int_activity_flash;
   activity_flashn <= not int_activity_flash;
   mac_speed       <= "11";

  ----------------------------------------------------------------------------
  -- Clock logic to generate required clocks from the 200MHz on board
  -- if 125MHz is available directly this can be removed
  ----------------------------------------------------------------------------
   gtx_clk_bufg <= gtx_clk;
   refclk_bufg  <= ref_clk;
   s_axi_aclk   <= gtx_clk;

   -- generate the user side clocks for the axi fifos
   tx_fifo_clock <= gtx_clk_bufg;
   rx_fifo_clock <= gtx_clk_bufg;

  ------------------------------------------------------------------------------
  -- Generate resets required for the fifo side signals etc
  ------------------------------------------------------------------------------

   example_resets : tri_mode_ethernet_mac_0_example_design_resets
   port map (
      -- clocks
      s_axi_aclk       => s_axi_aclk,
      gtx_clk          => gtx_clk_bufg,

      -- asynchronous resets
      glbl_rst         => glbl_rst,
      reset_error      => reset_error,
      rx_reset         => rx_reset,
      tx_reset         => tx_reset,

      dcm_locked       => dcm_locked,

      -- synchronous reset outputs
      glbl_rst_intn    => glbl_rst_intn,
      gtx_resetn       => gtx_resetn,
      s_axi_resetn     => s_axi_resetn,
      phy_resetn       => phy_resetn,
      chk_resetn       => chk_resetn
   );
   glbl_rst_int <= NOT glbl_rst_intn;
   dcm_locked   <= '1';
   reset_error  <= '0';

   -- generate the user side resets for the axi fifos
   tx_fifo_resetn <= gtx_resetn;
   rx_fifo_resetn <= gtx_resetn;

   ----------------------------------------------------------------------------
   -- Instantiate the AXI-LITE Controller
   ----------------------------------------------------------------------------

    axi_lite_controller : tri_mode_ethernet_mac_0_axi_lite_sm
    port map (
       s_axi_aclk                   => s_axi_aclk,
       s_axi_resetn                 => s_axi_resetn,

       mac_speed                    => mac_speed,
       update_speed                 => update_speed,
       serial_command               => pause_req_s,
       serial_response              => serial_response,
       phy_loopback                 => enable_phy_loopback,

       s_axi_awaddr                 => s_axi_awaddr,
       s_axi_awvalid                => s_axi_awvalid,
       s_axi_awready                => s_axi_awready,

       s_axi_wdata                  => s_axi_wdata,
       s_axi_wvalid                 => s_axi_wvalid,
       s_axi_wready                 => s_axi_wready,

       s_axi_bresp                  => s_axi_bresp,
       s_axi_bvalid                 => s_axi_bvalid,
       s_axi_bready                 => s_axi_bready,

       s_axi_araddr                 => s_axi_araddr,
       s_axi_arvalid                => s_axi_arvalid,
       s_axi_arready                => s_axi_arready,

       s_axi_rdata                  => s_axi_rdata,
       s_axi_rresp                  => s_axi_rresp,
       s_axi_rvalid                 => s_axi_rvalid,
       s_axi_rready                 => s_axi_rready
    );

   ------------------------------------------------------------------------------
   -- Instantiate the TRIMAC core FIFO Block wrapper
   ------------------------------------------------------------------------------
   trimac_fifo_block : tri_mode_ethernet_mac_0_fifo_block
    port map (
       gtx_clk                      => gtx_clk_bufg,
       -- asynchronous reset
       glbl_rstn                    => glbl_rst_intn,
       rx_axi_rstn                  => '1',
       tx_axi_rstn                  => '1',

       -- Reference clock for IDELAYCTRL's
       refclk                       => refclk_bufg,

       -- Receiver Statistics Interface
       -----------------------------------------
       rx_mac_aclk                  => rx_mac_aclk,
       rx_reset                     => rx_reset,
       rx_statistics_vector         => rx_statistics_vector,
       rx_statistics_valid          => rx_statistics_valid,

       -- Receiver => AXI-S Interface
       ------------------------------------------
       rx_fifo_clock                => rx_fifo_clock,
       rx_fifo_resetn               => rx_fifo_resetn,
       rx_axis_fifo_tdata           => rx_axis_fifo_tdata,
       rx_axis_fifo_tvalid          => rx_axis_fifo_tvalid,
       rx_axis_fifo_tready          => rx_axis_fifo_tready,
       rx_axis_fifo_tlast           => rx_axis_fifo_tlast,
       -- Transmitter Statistics Interface
       --------------------------------------------
       tx_mac_aclk                  => tx_mac_aclk,
       tx_reset                     => tx_reset,
       tx_ifg_delay                 => tx_ifg_delay,
       tx_statistics_vector         => tx_statistics_vector,
       tx_statistics_valid          => tx_statistics_valid,

       -- Transmitter => AXI-S Interface
       ---------------------------------------------
       tx_fifo_clock                => tx_fifo_clock,
       tx_fifo_resetn               => tx_fifo_resetn,
       tx_axis_fifo_tdata           => tx_axis_fifo_tdata,
       tx_axis_fifo_tvalid          => tx_axis_fifo_tvalid,
       tx_axis_fifo_tready          => tx_axis_fifo_tready,
       tx_axis_fifo_tlast           => tx_axis_fifo_tlast,

       -- MAC Control Interface
       --------------------------
       pause_req                    => pause_req,
       pause_val                    => pause_val,

       -- RGMII Interface
       --------------------
       rgmii_txd                    => rgmii_txd,
       rgmii_tx_ctl                 => rgmii_tx_ctl,
       rgmii_txc                    => rgmii_txc,
       rgmii_rxd                    => rgmii_rxd,
       rgmii_rx_ctl                 => rgmii_rx_ctl,
       rgmii_rxc                    => rgmii_rxc,

       -- RGMII Inband Status Registers
       ----------------------------------
       inband_link_status           => inband_link_status,
       inband_clock_speed           => inband_clock_speed,
       inband_duplex_status         => inband_duplex_status,

       -- MDIO Interface
       -------------------
       mdio                         => mdio,
       mdc                          => mdc,

       -- AXI-Lite Interface
       -----------------
       s_axi_aclk                   => s_axi_aclk,
       s_axi_resetn                 => s_axi_resetn,

       s_axi_awaddr                 => s_axi_awaddr,
       s_axi_awvalid                => s_axi_awvalid,
       s_axi_awready                => s_axi_awready,

       s_axi_wdata                  => s_axi_wdata,
       s_axi_wvalid                 => s_axi_wvalid,
       s_axi_wready                 => s_axi_wready,

       s_axi_bresp                  => s_axi_bresp,
       s_axi_bvalid                 => s_axi_bvalid,
       s_axi_bready                 => s_axi_bready,

       s_axi_araddr                 => s_axi_araddr,
       s_axi_arvalid                => s_axi_arvalid,
       s_axi_arready                => s_axi_arready,

       s_axi_rdata                  => s_axi_rdata,
       s_axi_rresp                  => s_axi_rresp,
       s_axi_rvalid                 => s_axi_rvalid,
       s_axi_rready                 => s_axi_rready
   );

   ---------------------------------------------< tcp_server
   PROCESS (gtx_clk_bufg) IS
   BEGIN  -- Make configurations synchronous to CLK125 of the TCP module
     IF rising_edge(gtx_clk_bufg) THEN
       tcp_mac_addr        <= MAC_ADDR;
       tcp_ipv4_addr       <= IPv4_ADDR;
       tcp_ipv6_addr       <= IPv6_ADDR;
       tcp_subnet_mask     <= SUBNET_MASK;
       tcp_gateway_ip_addr <= GATEWAY_IP_ADDR;
     END IF;
   END PROCESS;
 
   -- generate a 1-clk wide pulse SOF (start of frame)
   mac_rx_sof_gen : PROCESS (gtx_clk_bufg, glbl_rst_int) IS
     VARIABLE state       : std_logic;
     VARIABLE tvalid_prev : std_logic;
   BEGIN
     IF glbl_rst_int = '1' THEN
       state       := '0';
       tvalid_prev := '0';
       mac_rx_sof  <= '0';
     ELSIF falling_edge(gtx_clk_bufg) THEN
       mac_rx_sof <= '0';
       IF state = '0' THEN
         IF tvalid_prev = '0' AND rx_axis_fifo_tvalid = '1' THEN
           mac_rx_sof <= '1';
           state      := '1';
         END IF;
       ELSE                             -- state = '1'
         IF rx_axis_fifo_tlast = '1' THEN
           state := '0';
         END IF;
       END IF;
       tvalid_prev := rx_axis_fifo_tvalid;
     END IF;
   END PROCESS;

   rx_axis_fifo_tready  <= '1';
   tcp_rx_data          <= tcp_rx_data_slv8x(0);
   tcp_tx_data_slv8x(0) <= tcp_tx_data;
   tcp_tx_cts           <= tcp_tx_cts_vector(0);
   tcp_rx_data_valid    <= tcp_rx_data_valid_vector(0);
   connection_reset_v   <= (OTHERS => tcp_connection_reset);
   tcp_tx_data_valid_v  <= (OTHERS => tcp_tx_data_valid);
   tcp_server_inst : COM5402
     GENERIC MAP (
       CLK_FREQUENCY   => 125,
       -- CLK frequency in MHz. Needed to compute actual delays.
       TX_IDLE_TIMEOUT => 50,
       -- inactive input timeout, expressed in 4us units. -- 50*4us = 200us 
       -- Controls the transmit stream segmentation: data in the elastic buffer will be transmitted if
       -- no input is received within TX_IDLE_TIMEOUT, without waiting for the transmit frame to be filled with MSS data bytes.       
       SIMULATION      => '0'
      -- 1 during simulation with Wireshark .cap file, '0' otherwise
      -- Wireshark many not be able to collect offloaded checksum computations.
      -- when SIMULATION =  '1': (a) IP header checksum is valid if 0000,
      -- (b) TCP checksum computation is forced to a valid 00001 irrespective of the 16-bit checksum
      -- captured by Wireshark.
     )
     PORT MAP (
       --//-- CLK, RESET
       CLK         => gtx_clk_bufg,
       -- All signals are synchronous with CLK
       -- CLK must be a global clock 125 MHz or faster to match the Gbps MAC speed.
       ASYNC_RESET => glbl_rst_int,  -- to be phased out. replace with SYNC_RESET
       SYNC_RESET  => glbl_rst_int,

       --//-- CONFIGURATION
       -- configuration signals are synchonous with CLK
       -- Synchronous with CLK clock.
       MAC_ADDR        => tcp_mac_addr,
       IPv4_ADDR       => tcp_ipv4_addr,
       IPv6_ADDR       => tcp_ipv6_addr,
       SUBNET_MASK     => tcp_subnet_mask,
       GATEWAY_IP_ADDR => tcp_gateway_ip_addr,
       -- local IP address. 4 bytes for IPv4, 16 bytes for IPv6
       -- Natural order (MSB) 172.16.1.128 (LSB) as transmitted in the IP frame.

       --// User-initiated connection reset for stream I
       CONNECTION_RESET => connection_reset_v,

       --//-- Protocol -> Transmit MAC Interface
       -- 32-bit CRC is automatically appended by the MAC layer. User should not supply it.
       -- Synchonous with the user-side CLK
       MAC_TX_DATA       => tx_axis_fifo_tdata,
       -- MAC reads the data at the rising edge of CLK when MAC_TX_DATA_VALID = '1'
       MAC_TX_DATA_VALID => tx_axis_fifo_tvalid,
       -- data valid
       MAC_TX_SOF        => OPEN,
       -- start of frame: '1' when sending the first byte.       
       MAC_TX_EOF        => tx_axis_fifo_tlast,
       -- '1' when sending the last byte in a packet to be transmitted. 
       -- Aligned with MAC_TX_DATA_VALID
       MAC_TX_CTS        => tx_axis_fifo_tready,
       -- MAC-generated Clear To Send flow control signal, indicating room in the 
       -- MAC tx elastic buffer for a complete maximum size frame 1518B. 
       -- The user should check that this signal is high before deciding to send
       -- sending the next frame. 
       -- Note: MAC_TX_CTS may go low while the frame is transfered in. Ignore it as space is guaranteed
       -- at the start of frame.

       --//-- Receive MAC -> Protocol
       -- Valid rx packets only: packets with bad CRC or invalid address are discarded.
       -- The 32-bit CRC is always removed by the MAC layer.
       -- Synchonous with the user-side CLK
       MAC_RX_DATA       => rx_axis_fifo_tdata,
       -- USER reads the data at the rising edge of CLK when MAC_RX_DATA_VALID = '1'
       MAC_RX_DATA_VALID => rx_axis_fifo_tvalid,
       -- data valid
       MAC_RX_SOF        => mac_rx_sof,
       -- '1' when sending the first byte in a received packet. 
       -- Aligned with MAC_RX_DATA_VALID
       MAC_RX_EOF        => rx_axis_fifo_tlast,
       -- '1' when sending the last byte in a received packet. 
       -- Aligned with MAC_RX_DATA_VALID

       --//-- Application <- UDP rx
       UDP_RX_DATA         => OPEN,
       UDP_RX_DATA_VALID   => OPEN,
       UDP_RX_SOF          => OPEN,
       UDP_RX_EOF          => OPEN,
       -- 1 CLK pulse indicating that UDP_RX_DATA is the last byte in the UDP data field.
       -- ALWAYS CHECK UDP_RX_DATA_VALID at the end of packet (UDP_RX_EOF = '1') to confirm
       -- that the UDP packet is valid. External buffer may have to backtrack to the the last
       -- valid pointer to discard an invalid UDP packet.
       -- Reason: we only knows about bad UDP packets at the end.
       UDP_RX_DEST_PORT_NO => (OTHERS => '0'),

       --//-- Application -> UDP tx
       UDP_TX_DATA           => (OTHERS => '0'),
       UDP_TX_DATA_VALID     => '0',
       UDP_TX_SOF            => '0',  -- 1 CLK-wide pulse to mark the first byte in the tx UDP frame
       UDP_TX_EOF            => '0',  -- 1 CLK-wide pulse to mark the last byte in the tx UDP frame
       UDP_TX_CTS            => OPEN,
       UDP_TX_ACK            => OPEN,  -- 1 CLK-wide pulse indicating that the previous UDP frame is being sent
       UDP_TX_NAK            => OPEN,  -- 1 CLK-wide pulse indicating that the previous UDP frame could not be sent
       UDP_TX_DEST_IP_ADDR   => (OTHERS => '0'),
       UDP_TX_DEST_PORT_NO   => (OTHERS => '0'),
       UDP_TX_SOURCE_PORT_NO => (OTHERS => '0'),

       --//-- Application <- TCP rx
       -- NTCPSTREAMS can operate independently. Only one stream active at any given time.
       -- Data is pushed out. Limited flow-control here. Receipient must be able to accept data
       -- at any time (in other words, it is the receipient's responsibility to have elastic 
       -- buffer if needed).
       TCP_RX_DATA       => tcp_rx_data_slv8x,
       TCP_RX_DATA_VALID => tcp_rx_data_valid_vector,
       TCP_RX_RTS        => tcp_rx_rts,
       TCP_RX_CTS        => tcp_rx_cts,
       -- Optional Clear-To-Send. pull to '1' when output flow control is unused.
       -- WARNING: pulling CTS down will stop the flow for ALL streams.

       --//-- Application -> TCP tx
       -- NTCPSTREAMS can operate independently and concurrently. No scheduling arbitration needed here.
       TCP_TX_DATA       => tcp_tx_data_slv8x,
       TCP_TX_DATA_VALID => tcp_tx_data_valid_v,
       TCP_TX_CTS        => tcp_tx_cts_vector,
       -- Clear To Send = transmit flow control. 
       -- App is responsible for checking the CTS signal before sending APP_DATA

       --//-- TEST POINTS, COMSCOPE TRACES
       CS1     => OPEN,
       CS1_CLK => OPEN,
       CS2     => OPEN,
       CS2_CLK => OPEN,
       TP      => OPEN
     );

   -- Must have programmable full with single-threshold of 61
   -- out of total write-depth 64.
   -- When RX_CTS is low, the Server continues to drive out 3 more bytes of data
   -- (observed with ILA).  The fifo must be able to accept them, hence the use
   -- of prog_full.
   rx_fifo_inst : fifo8to32
     PORT MAP (
       rst       => glbl_rst_int,
       wr_clk    => gtx_clk_bufg,
       rd_clk    => RX_FIFO_RDCLK,
       din       => tcp_rx_data,
       wr_en     => tcp_rx_data_valid,
       rd_en     => RX_FIFO_RDEN,
       dout      => RX_FIFO_Q,
       full      => rx_fifo_full,
       prog_full => rx_fifo_fullm3,     -- asserted at (full-3) writes
       empty     => RX_FIFO_EMPTY
     );
   tcp_rx_cts <= (NOT rx_fifo_fullm3) WHEN TCP_USE_FIFO = '1' ELSE
                 RX_TREADY;
   RX_TDATA   <= tcp_rx_data;
   RX_TVALID  <= tcp_rx_data_valid;

   tx_fifo_inst : fifo32to8
     PORT MAP (
       rst    => glbl_rst_int,
       wr_clk => TX_FIFO_WRCLK,
       rd_clk => gtx_clk_bufg,
       din    => TX_FIFO_Q,
       wr_en  => TX_FIFO_WREN,
       rd_en  => tx_fifo_rden,
       dout   => tx_fifo_dout,
       full   => TX_FIFO_FULL,
       empty  => tx_fifo_empty
     );
   tcp_tx_data_valid <= ((NOT tx_fifo_empty) AND tcp_tx_cts) WHEN TCP_USE_FIFO = '1' ELSE
                        TX_TVALID;
   tx_fifo_rden      <= tcp_tx_data_valid;

   tcp_tx_data <= tx_fifo_dout WHEN TCP_USE_FIFO = '1' ELSE
                  TX_TDATA;
   TX_TREADY   <= tcp_tx_cts;

end wrapper;
