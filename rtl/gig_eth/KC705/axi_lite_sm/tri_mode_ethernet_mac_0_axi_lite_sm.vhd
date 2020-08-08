--------------------------------------------------------------------------------
-- File       : tri_mode_ethernet_mac_0_axi_lite_sm.vhd
-- Author     : Xilinx Inc.
-- -----------------------------------------------------------------------------
-- (c) Copyright 2010 Xilinx, Inc. All rights reserved.
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
--------------------------------------------------------------------------------
-- Description:  This module is reponsible for bringing up both the MAC and the
-- attached PHY (if any) to enable basic packet transfer in both directions.
-- It is intended to be directly usable on a xilinx demo platform to demonstrate
-- simple bring up and data transfer.  The mac speed is set via inputs (which
-- can be connected to dip switches) and the PHY is configured to ONLY advertise
-- the specified speed.  To maximise compatibility on boards only IEEE registers
-- are used and the PHY address can be set via a parameter.
--
--------------------------------------------------------------------------------

library unisim;
use unisim.vcomponents.all;

library ieee;
use ieee.std_logic_1164.all;


entity tri_mode_ethernet_mac_0_axi_lite_sm is
   port (
      s_axi_aclk                       : in  std_logic;
      s_axi_resetn                     : in  std_logic;

      mac_speed                        : in  std_logic_vector(1 downto 0);
      update_speed                     : in  std_logic;
      serial_command                   : in  std_logic;
      serial_response                  : out std_logic;
   
      phy_loopback                     : in  std_logic;
      

      s_axi_awaddr                     : out std_logic_vector(11 downto 0) := (others => '0');
      s_axi_awvalid                    : out std_logic := '0';
      s_axi_awready                    : in  std_logic;

      s_axi_wdata                      : out std_logic_vector(31 downto 0) := (others => '0');
      s_axi_wvalid                     : out std_logic := '0';
      s_axi_wready                     : in  std_logic;

      s_axi_bresp                      : in  std_logic_vector(1 downto 0);
      s_axi_bvalid                     : in  std_logic;
      s_axi_bready                     : out std_logic;

      s_axi_araddr                     : out std_logic_vector(11 downto 0) := (others => '0');
      s_axi_arvalid                    : out std_logic := '0';
      s_axi_arready                    : in  std_logic;

      s_axi_rdata                      : in  std_logic_vector(31 downto 0);
      s_axi_rresp                      : in  std_logic_vector(1 downto 0);
      s_axi_rvalid                     : in  std_logic;
      s_axi_rready                     : out std_logic := '0'
   );
end tri_mode_ethernet_mac_0_axi_lite_sm;

architecture rtl of tri_mode_ethernet_mac_0_axi_lite_sm is

  attribute DowngradeIPIdentifiedWarnings: string;
  attribute DowngradeIPIdentifiedWarnings of RTL : architecture is "yes";

   component tri_mode_ethernet_mac_0_sync_block
   port (
      clk                        : in  std_logic;
      data_in                    : in  std_logic;
      data_out                   : out std_logic
   );
   end component;


   -- main state machine

   -- Encoded main state machine states.
   type state_typ is         (STARTUP,
                              CHANGE_SPEED,
                              
                              MDIO_RD,
                              MDIO_POLL_CHECK,
                              MDIO_1G,
                              MDIO_10_100,
                              MDIO_RGMII_RD,
                              MDIO_RGMII_RD_POLL,
                              MDIO_RGMII,
                              MDIO_DELAY_RD,
                              MDIO_DELAY_RD_POLL,
                              MDIO_DELAY,
                              MDIO_RESTART,
                              MDIO_LOOPBACK,
                              MDIO_STATS,
                              MDIO_STATS_POLL_CHECK,
                              
                              RESET_MAC_RX,
                              RESET_MAC_TX,
                              CNFG_MDIO,
                              CNFG_FLOW,
                              CNFG_FILTER,
                            
                              CNFG_LO_ADDR,
                              CNFG_HI_ADDR,
                              CHECK_SPEED);

   
   -- MDIO State machine
   type mdio_state_typ is    (IDLE,
                              SET_DATA,
                              INIT,
                              POLL);

   -- AXI State Machine
   type axi_state_typ is     (IDLE_A,
                              READ,
                              WRITE,
                              DONE);


   
   -- Management configuration register address     (0x500)
   constant CONFIG_MANAGEMENT_ADD  : std_logic_vector(16 downto 0) := "00000" & X"500";
   

   -- Flow control configuration register address   (0x40C0)
   constant CONFIG_FLOW_CTRL_ADD   : std_logic_vector(16 downto 0) := "00000" & X"40C";

   -- Receiver configuration register address       (0x4040)
   constant RECEIVER_ADD           : std_logic_vector(16 downto 0) := "00000" & X"404";

   -- Transmitter configuration register address    (0x4080)
   constant TRANSMITTER_ADD        : std_logic_vector(16 downto 0) :="00000" &  X"408";

   -- Speed configuration register address    (0x410)
   constant SPEED_CONFIG_ADD       : std_logic_vector(16 downto 0) :="00000" &  X"410";

   -- Unicast Word 0 configuration register address (0x7000)
   constant CONFIG_UNI0_CTRL_ADD   : std_logic_vector(16 downto 0) :="00000" & X"700";

   -- Unicast Word 1 configuration register address (0x7040)
   constant CONFIG_UNI1_CTRL_ADD   : std_logic_vector(16 downto 0) :="00000" & X"704";

   -- Address Filter configuration register address (0x7080)
   constant CONFIG_ADDR_CTRL_ADD   : std_logic_vector(16 downto 0) := "00000" & X"708";
   

   
   -- MDIO registers
   constant MDIO_CONTROL           : std_logic_vector(16 downto 0) := "00000" & X"504";
   constant MDIO_TX_DATA           : std_logic_vector(16 downto 0) := "00000" & X"508";
   constant MDIO_RX_DATA           : std_logic_vector(16 downto 0) := "00000" & X"50C";
   constant MDIO_OP_RD             : std_logic_vector(1 downto 0) := "10";
   constant MDIO_OP_WR             : std_logic_vector(1 downto 0) := "01";


   
   -- PHY Registers
   -- phy address is actually a 6 bit field but other bits are reserved so simpler to specify as 8 bit
   constant PHY_ADDR               : std_logic_vector(7 downto 0) := X"07";
   constant PHY_CONTROL_REG        : std_logic_vector(7 downto 0) := X"00";
   constant PHY_STATUS_REG         : std_logic_vector(7 downto 0) := X"01";
   constant PHY_ABILITY_REG        : std_logic_vector(7 downto 0) := X"04";
   constant PHY_1000BASET_CONTROL_REG : std_logic_vector(7 downto 0) := X"09";
   -- Non IEEE registers assume the PHY as provided on the Xilinx standard connectivity board i.e SP605
   constant PHY_MODE_CTL_REG       : std_logic_vector(7 downto 0) := X"14";
   constant PHY_MODE_STS_REG       : std_logic_vector(7 downto 0) := X"1b";

   ---------------------------------------------------
   -- Signal declarations
   signal axi_status               : std_logic_vector(4 downto 0);   -- used to keep track of axi transactions
   
   signal mdio_ready               : std_logic;                      -- captured to acknowledge the end of mdio transactions
   
   signal axi_rd_data              : std_logic_vector(31 downto 0);
   signal axi_wr_data              : std_logic_vector(31 downto 0);
   
   signal mdio_wr_data             : std_logic_vector(31 downto 0);
   

   signal axi_state                : state_typ;                      -- main state machine to configure example design
   
   signal mdio_access_sm           : mdio_state_typ;                 -- mdio state machine to handle mdio register config
   signal axi_access_sm            : axi_state_typ;                  -- axi state machine - handles the 5 channels

   signal start_access             : std_logic;                      -- used to kick the axi acees state machine
   
   signal start_mdio               : std_logic;                      -- used to kick the mdio state machine
   signal drive_mdio               : std_logic;                      -- selects between mdio fields and direct sm control
   signal mdio_op                  : std_logic_vector(1 downto 0);
   signal mdio_reg_addr            : std_logic_vector(7 downto 0);
   
   signal writenread               : std_logic;
   signal addr                     : std_logic_vector(16 downto 0);
   signal speed                    : std_logic_vector(1 downto 0);
   signal update_speed_sync        : std_logic;
   signal update_speed_reg         : std_logic;
   signal speedis10                : std_logic;
   signal speedis100               : std_logic;

   signal count_shift              : std_logic_vector(20 downto 0) := (others => '1');

   -- to avoid logic being stripped a serial input is included which enables an address/data and
   -- control to be setup for a user config access..
   signal serial_command_shift     : std_logic_vector(36 downto 0);
   signal load_data                : std_logic;
   signal capture_data             : std_logic;
   signal write_access             : std_logic;
   signal read_access              : std_logic;

   signal s_axi_reset              : std_logic;

   signal s_axi_awvalid_int        : std_logic;
   signal s_axi_wvalid_int         : std_logic;
   signal s_axi_bready_int         : std_logic;
   signal s_axi_arvalid_int        : std_logic;
   signal s_axi_rready_int         : std_logic;


   

begin

   s_axi_awvalid <= s_axi_awvalid_int;
   s_axi_wvalid  <= s_axi_wvalid_int;
   s_axi_bready  <= s_axi_bready_int;
   s_axi_arvalid <= s_axi_arvalid_int;
   s_axi_rready  <= s_axi_rready_int;

   s_axi_reset <= not s_axi_resetn;

   speedis10  <= '1' when speed = "00" else '0';
   speedis100 <= '1' when speed = "01" else '0';

   update_speed_sync_inst :tri_mode_ethernet_mac_0_sync_block
   port map (
      clk              => s_axi_aclk,
      data_in          => update_speed,
      data_out         => update_speed_sync
   );

   update_reg : process (s_axi_aclk)
   begin
      if s_axi_aclk'event and s_axi_aclk = '1' then
         if s_axi_reset = '1' then
            update_speed_reg   <= '0';
         else
            update_speed_reg   <= update_speed_sync;
         end if;
      end if;
   end process update_reg;


   -----------------------------------------------------------------------------
   -- Management process. This process sets up the configuration by
   -- turning off flow control, then checks gathered statistics at the
   -- end of transmission
   -----------------------------------------------------------------------------
   gen_state : process (s_axi_aclk)
   begin
      if s_axi_aclk'event and s_axi_aclk = '1' then
         if s_axi_reset = '1' then
            axi_state      <= STARTUP;
            start_access   <= '0';
   
            start_mdio     <= '0';
            drive_mdio     <= '0';
            mdio_op        <= (others => '0');
            mdio_reg_addr  <= (others => '0');
            
            writenread     <= '0';
            addr           <= (others => '0');
            axi_wr_data    <= (others => '0');
            speed          <= mac_speed;
         -- main state machine is kicking off multi cycle accesses in each state so has to
         -- stall while they take place
   
         elsif axi_access_sm = IDLE_A and mdio_access_sm = IDLE and start_access = '0' and start_mdio = '0' then
         
            case axi_state is
               when STARTUP =>
                  -- this state will be ran after reset to wait for count_shift
                  
                  if (count_shift(20) = '0') then
                        
                     -- set up MDC frequency. Write 0x58 to Management configuration
                     -- register (Add=340). This will enable MDIO and set MDC to 2.5MHz
                     -- (set CLOCK_DIVIDE value to 24 dec. for 125MHz s_axi_aclk and
                     -- enable mdio)
                     
                     speed          <= mac_speed;
                     assert false
                       report "Setting MDC Frequency to 2.5MHz...." & cr
                       severity note;
                     start_access   <= '1';
                     writenread     <= '1';
                     addr           <= CONFIG_MANAGEMENT_ADD;
                     
                     axi_wr_data    <= X"00000058";
                     
                     axi_state      <= CHANGE_SPEED;
                  end if;
                  
               when CHANGE_SPEED =>
                  -- program the MAC to the required speed
                  assert false
                    report "Programming MAC speed" & cr
                    severity note;
                  drive_mdio      <= '0';
                  
                  start_access    <= '1';
                  writenread      <= '1';
                  addr            <= SPEED_CONFIG_ADD;
                  -- bits 31:30 are used
                  axi_wr_data     <= speed & X"0000000" & "00";
   
                  axi_state       <= MDIO_RD;
                  
   
               when MDIO_RD =>
                  -- read phy status - if response is all ones then do not perform any
                  -- further MDIO accesses
                  assert false
                    report "Checking for PHY" & cr
                    severity note;
                  drive_mdio     <= '1';   -- switch axi transactions to use mdio values..
                  start_mdio     <= '1';
                  writenread     <= '0';
                  mdio_reg_addr  <= PHY_STATUS_REG;
                  mdio_op        <= MDIO_OP_RD;
                  axi_state      <= MDIO_POLL_CHECK;
               when MDIO_POLL_CHECK =>
                  if axi_rd_data(15 downto 0) = X"ffff" then
                     -- if status is all ones then no PHY exists at this address
                     -- (this is used by the tri_mode_ethernet_mac_0_demo_tb to avoid performing lots of phy accesses)
                      
                     axi_state      <= RESET_MAC_RX;
                  else
                   
                     axi_state      <= MDIO_1G;
                  end if;
               when MDIO_1G =>
                  -- set 1G advertisement
                  assert false
                    report "Setting PHY 1G advertisement" & cr
                    severity note;
                  start_mdio     <= '1';
                  mdio_reg_addr  <= PHY_1000BASET_CONTROL_REG;
                  mdio_op        <= MDIO_OP_WR;
                  -- 0x200 is 1G full duplex, 0x100 is 1G half duplex
                  -- only advertise the mode we want..
                  axi_wr_data    <= X"0000" & "000000" & speed(1) & '0' & X"00";
                  axi_state      <= MDIO_10_100;
               when MDIO_10_100 =>
                  -- set 10/100 advertisement
                  assert false
                    report "Setting PHY 10/100M advertisement" & cr
                    severity note;
                  start_mdio     <= '1';
                  mdio_reg_addr  <= PHY_ABILITY_REG;
                  mdio_op        <= MDIO_OP_WR;
                  -- bit8 : full 100M, bit7 : half 100M, bit6 : full 10M, bit5 : half 10M
                  -- only advertise the mode we want..
                  axi_wr_data    <= X"00000" & "000" & speedis100 & '0' & speedis10 & "000000";
                  axi_state      <= MDIO_RGMII_RD;
               when MDIO_RGMII_RD =>
                  assert false
                    report "Checking current config" & cr
                    severity note;
                  start_mdio     <= '1';
                  writenread     <= '0';
                  mdio_reg_addr  <= PHY_MODE_STS_REG;
                  mdio_op        <= MDIO_OP_RD;
                  axi_state      <= MDIO_RGMII_RD_POLL;
               when MDIO_RGMII_RD_POLL =>
                  axi_state      <= MDIO_RGMII;
                  -- prepare write_data for the next state
                  axi_wr_data    <= X"0000" & axi_rd_data(15 downto 4) & X"b";
               when MDIO_RGMII =>
                  -- set PHY to RGMII (if no jumper)
                  assert false
                    report "Setting PHY for RGMII - assumes Xilinx Standard Connectivity Board PHY" & cr
                    severity note;
                  start_mdio     <= '1';
                  mdio_reg_addr  <= PHY_MODE_STS_REG;
                  mdio_op        <= MDIO_OP_WR;
                  axi_state      <= MDIO_DELAY_RD;
               -- may not need the following three states
               when MDIO_DELAY_RD =>
                  assert false
                    report "Checking current config" & cr
                    severity note;
                  start_mdio     <= '1';
                  writenread     <= '0';
                  mdio_reg_addr  <= PHY_MODE_CTL_REG;
                  mdio_op        <= MDIO_OP_RD;
                  axi_state      <= MDIO_DELAY_RD_POLL;
               when MDIO_DELAY_RD_POLL =>
                  axi_state      <= MDIO_DELAY;
                  -- prepare write_data for the next state
                  axi_wr_data    <= X"0000" & axi_rd_data(15 downto 8) & '1' & axi_rd_data(6 downto 2) & '0' & axi_rd_data(0);
               when MDIO_DELAY =>
                  -- add/remove the clock delay
                  assert false
                    report "Setting PHY RGMII delay - assumes Xilinx Standard Connectivity Board PHY" & cr
                    severity note;
                  start_mdio     <= '1';
                  mdio_reg_addr  <= PHY_MODE_CTL_REG;
                  mdio_op        <= MDIO_OP_WR;
                  axi_state      <= MDIO_RESTART;
               when MDIO_RESTART =>
                  -- set autoneg and reset
                  -- if loopback is selected then do not set autonegotiate and program the required speed directly
                  -- otherwise set autonegotiate
                  assert false
                    report "Applying PHY software reset" & cr
                    severity note;
                  start_mdio     <= '1';
                  mdio_reg_addr  <= PHY_CONTROL_REG;
                  mdio_op        <= MDIO_OP_WR;
                  if phy_loopback = '1' then
                     -- bit15: software reset, bit13 : speed LSB, bit 8 : full duplex, bit 6 : speed MSB
                     axi_wr_data    <= X"0000" & "10" &  speedis100 &  X"0" & '1' & '0' & speed(1) & "000000";
                     axi_state      <= MDIO_LOOPBACK;
                  else
                     -- bit15: software reset, bit12 : AN enable (set after power up)
                     axi_wr_data    <= X"0000" & X"9" & X"000";
                     axi_state      <= MDIO_STATS;
                  end if;
               when MDIO_LOOPBACK =>
                  -- set phy loopback
                  assert false
                    report "Applying PHY loopback" & cr
                    severity note;
                  start_mdio     <= '1';
                  mdio_reg_addr  <= PHY_CONTROL_REG;
                  mdio_op        <= MDIO_OP_WR;
                  -- bit14: loopback, bit13 : speed LSB, bit 8 : full duplex, bit 6 : speed MSB
                  axi_wr_data    <= X"0000" & "01" & speedis100 & X"0" & '1' & '0' & speed(1) & "000000";
                  axi_state      <= RESET_MAC_RX;
               when MDIO_STATS =>
                  start_mdio     <= '1';
                  assert false
                    report "Wait for Autonegotiation to complete" & cr
                    severity note;
                  mdio_reg_addr  <= PHY_STATUS_REG;
                  mdio_op        <= MDIO_OP_RD;
                  axi_state      <= MDIO_STATS_POLL_CHECK;
               when MDIO_STATS_POLL_CHECK =>
                  -- bit 5 is autoneg complete - assume required speed is selected
                  if axi_rd_data(5) = '1' then
                     axi_state      <= RESET_MAC_RX;
                  else
                     axi_state      <= MDIO_STATS;
                  end if;

               -- once here the PHY is ACTIVE - NOTE only IEEE registers are used
               when RESET_MAC_RX =>
                  assert false
                    report "Reseting MAC RX" & cr
                    severity note;
                  
                  drive_mdio     <= '0';
                  
                  start_access   <= '1';
                  writenread     <= '1';
                  addr           <= RECEIVER_ADD;
                  axi_wr_data    <= X"90000000";
                  axi_state      <= RESET_MAC_TX;
               when RESET_MAC_TX =>
                  assert false
                    report "Reseting MAC TX" & cr
                    severity note;
                  start_access   <= '1';
                  writenread     <= '1';
                  addr           <= TRANSMITTER_ADD;
                  axi_wr_data    <= X"90000000";
                  
                  axi_state      <= CNFG_MDIO;
                  
                  
               when CNFG_MDIO =>
                       
                     -- set up MDC frequency. Write 0x58 to Management configuration
                     -- register (Add=340). This will enable MDIO and set MDC to 2.5MHz
                     -- (set CLOCK_DIVIDE value to 24 dec. for 125MHz s_axi_aclk and
                     -- enable mdio)
                     
                  assert false
                    report "Setting MDC Frequency to 2.5MHZ...." & cr
                    severity note;
                  start_access   <= '1';
                  writenread     <= '1';
                  addr           <= CONFIG_MANAGEMENT_ADD;
                     
                     axi_wr_data    <= X"00000058";
                     
                  axi_state      <= CNFG_FLOW;
               when CNFG_FLOW =>
                  assert false
                    report "Disabling Flow control...." & cr
                    severity note;
                  start_access   <= '1';
                  writenread     <= '1';
                  addr           <= CONFIG_FLOW_CTRL_ADD;
                  axi_wr_data    <= (others => '0');
                  axi_state      <= CNFG_LO_ADDR;
    
               when CNFG_LO_ADDR =>
                  assert false
                    report "Configuring unicast address(low word)...." & cr
                    severity note;
                  start_access   <= '1';
                  writenread     <= '1';
                  addr           <= CONFIG_UNI0_CTRL_ADD;
                  axi_wr_data    <= X"040302DA";
                  axi_state      <= CNFG_HI_ADDR;
               when CNFG_HI_ADDR =>
                  assert false
                    report "Configuring unicast address(high word)...." & cr
                    severity note;
                  start_access   <= '1';
                  writenread     <= '1';
                  addr           <= CONFIG_UNI1_CTRL_ADD;
                  axi_wr_data    <= X"00000605";
                  axi_state      <= CNFG_FILTER;
               
                
               when CNFG_FILTER =>
                  assert false
                    report "Setting core to promiscuous mode...." & cr
                    severity note;
                  start_access   <= '1';
                  writenread     <= '1';
                  addr           <= CONFIG_ADDR_CTRL_ADD;
                  axi_wr_data    <= X"80000000";
                  axi_state      <= CHECK_SPEED;
               when CHECK_SPEED =>
                  if update_speed_reg = '1' then
                    axi_state      <= CHANGE_SPEED;
                    speed          <= mac_speed;
                  else
                     if capture_data = '1' then
                        axi_wr_data <= serial_command_shift(33 downto 2);
                     end if;
                     if write_access = '1' or read_access = '1' then
                        addr         <= "00000" & serial_command_shift (13 downto 2);
                        start_access <= '1';
                        writenread   <= write_access;
                     end if;
                  end if;
               when others =>
                  axi_state <= STARTUP;
            end case;
         else
            start_access <= '0';
            
            start_mdio   <= '0';
            
         end if;
      end if;
   end process gen_state;


   
   --------------------------------------------------
   -- MDIO setup - split from main state machine to make more manageable

   gen_mdio_state : process (s_axi_aclk)
   begin
      if s_axi_aclk'event and s_axi_aclk = '1' then
         if s_axi_reset = '1' then
            mdio_access_sm <= IDLE;
         elsif axi_access_sm = IDLE_A or axi_access_sm = DONE then
            case mdio_access_sm is
               when IDLE =>
                  if start_mdio = '1' then
                     if mdio_op = MDIO_OP_WR then
                        mdio_access_sm <= SET_DATA;
                        mdio_wr_data   <= axi_wr_data;
                     else
                        mdio_access_sm <= INIT;
                        mdio_wr_data   <= PHY_ADDR & mdio_reg_addr & mdio_op & "001" & "00000000000";
                     end if;
                  end if;
               when SET_DATA =>
                  mdio_access_sm <= INIT;
                  mdio_wr_data   <= PHY_ADDR & mdio_reg_addr & mdio_op & "001" & "00000000000";
               when INIT =>
                  mdio_access_sm <= POLL;
               when POLL =>
                  if mdio_ready = '1' then
                     mdio_access_sm <= IDLE;
                  end if;
            end case;
         elsif mdio_access_sm = POLL and mdio_ready = '1' then
            mdio_access_sm <= IDLE;
         end if;
      end if;
   end process gen_mdio_state;


   ---------------------------------------------------------------------------------------------
   -- processes to generate the axi transactions - only simple reads and write can be generated

   gen_axi_state : process (s_axi_aclk)
   begin
      if s_axi_aclk'event and s_axi_aclk = '1' then
         if s_axi_reset = '1' then
            axi_access_sm <= IDLE_A;
         else
            case axi_access_sm is
               when IDLE_A =>
   
                  if start_access = '1' or start_mdio = '1' or mdio_access_sm /= IDLE then
                     if mdio_access_sm = POLL then
                        axi_access_sm <= READ;
                     elsif (start_access = '1' and writenread = '1') or
                           (start_mdio = '1' or mdio_access_sm = SET_DATA or mdio_access_sm = INIT) then
                        axi_access_sm <= WRITE;
                     else
                        axi_access_sm <= READ;
                     end if;
                  end if;
               when WRITE =>
                  -- wait in this state until axi_status signals the write is complete
                  if axi_status(4 downto 2) = "111" then
                     axi_access_sm <= DONE;
                  end if;
               when READ =>
                  -- wait in this state until axi_status signals the read is complete
                  if axi_status(1 downto 0) = "11" then
                     axi_access_sm <= DONE;
                  end if;
               when DONE =>
                  axi_access_sm <= IDLE_A;
            end case;
         end if;
      end if;
   end process gen_axi_state;

   -- need a process per axi interface (i.e 5)
   -- in each case the interface is driven accordingly and once acknowledged a sticky
   -- status bit is set and the process waits until the access_sm moves on
   -- READ ADDR
   read_addr_p : process (s_axi_aclk)
   begin
      if s_axi_aclk'event and s_axi_aclk = '1' then
         if axi_access_sm = READ then
            if axi_status(0) = '0' then
               
               if drive_mdio = '1' then
                  s_axi_araddr   <= MDIO_RX_DATA(11 downto 0);
               else
                  s_axi_araddr   <= addr(11 downto 0);
               end if;
               s_axi_arvalid_int <= '1';
               if s_axi_arready = '1' and s_axi_arvalid_int = '1' then
                  axi_status(0)     <= '1';
                  s_axi_araddr      <= (others => '0');
                  s_axi_arvalid_int <= '0';
               end if;
            end if;
         else
            axi_status(0)     <= '0';
            s_axi_araddr      <= (others => '0');
            s_axi_arvalid_int <= '0';
         end if;
      end if;
   end process read_addr_p;

   -- READ DATA/RESP
   read_data_p : process (s_axi_aclk)
   begin
      if s_axi_aclk'event and s_axi_aclk = '1' then
         if axi_access_sm = READ then
            if axi_status(1) = '0' then
               s_axi_rready_int  <= '1';
               if s_axi_rvalid = '1' and s_axi_rready_int = '1' then
                  axi_status(1) <= '1';
                  s_axi_rready_int  <= '0';
                  axi_rd_data   <= s_axi_rdata;
                  
                  if drive_mdio = '1' and s_axi_rdata(16) = '1' then
                     mdio_ready <= '1';
                  end if;
                  
               end if;
            end if;
         else
            s_axi_rready_int  <= '0';
            axi_status(1)     <= '0';
            
            if axi_access_sm = IDLE_A  and (start_access = '1' or start_mdio = '1') then
               mdio_ready     <= '0';
               axi_rd_data   <= (others => '0');
            end if;
         end if;
      end if;
   end process read_data_p;

   -- WRITE ADDR
   write_addr_p : process (s_axi_aclk)
   begin
      if s_axi_aclk'event and s_axi_aclk = '1' then
         if axi_access_sm = WRITE then
            if axi_status(2) = '0' then
               if drive_mdio = '1' then
                  if mdio_access_sm = SET_DATA then
                     s_axi_awaddr <= MDIO_TX_DATA(11 downto 0);
                  else
                     s_axi_awaddr <= MDIO_CONTROL(11 downto 0);
                  end if;
               else
                  s_axi_awaddr   <= addr(11 downto 0);
               end if;
               s_axi_awvalid_int <= '1';
               if s_axi_awready = '1' and s_axi_awvalid_int = '1' then
                  axi_status(2)     <= '1';
                  s_axi_awaddr      <= (others => '0');
                  s_axi_awvalid_int <= '0';
               end if;
            end if;
         else
            s_axi_awaddr      <= (others => '0');
            s_axi_awvalid_int <= '0';
            axi_status(2)     <= '0';
         end if;
      end if;
   end process write_addr_p;

   -- WRITE DATA
   write_data_p : process (s_axi_aclk)
   begin
      if s_axi_aclk'event and s_axi_aclk = '1' then
         if axi_access_sm = WRITE then
            if axi_status(3) = '0' then
               
               if drive_mdio = '1' then
                  s_axi_wdata   <= mdio_wr_data;
               else
                  s_axi_wdata   <= axi_wr_data;
               end if;
               
               s_axi_wvalid_int  <= '1';
               if s_axi_wready = '1' and s_axi_wvalid_int = '1' then
                  axi_status(3)    <= '1';
                  s_axi_wvalid_int <= '0';
               end if;
            end if;
         else
            s_axi_wdata      <= (others => '0');
            s_axi_wvalid_int <= '0';
            axi_status(3)    <= '0';
         end if;
      end if;
   end process write_data_p;

   -- WRITE RESP
   write_resp_p : process (s_axi_aclk)
   begin
      if s_axi_aclk'event and s_axi_aclk = '1' then
         if axi_access_sm = WRITE then
            if axi_status(4) = '0' then
               s_axi_bready_int  <= '1';
               if s_axi_bvalid = '1' and s_axi_bready_int = '1' then
                  axi_status(4)    <= '1';
                  s_axi_bready_int     <= '0';
               end if;
            end if;
         else
            s_axi_bready_int     <= '0';
            axi_status(4)    <= '0';
         end if;
      end if;
   end process write_resp_p;

   shift_command : process (s_axi_aclk)
   begin
      if s_axi_aclk'event and s_axi_aclk = '1' then
         if load_data = '1' then
            serial_command_shift <= serial_command_shift(35 downto 33) & axi_rd_data & serial_command_shift(0) & serial_command;
         else
            serial_command_shift <= serial_command_shift(35 downto 0) & serial_command;
         end if;
      end if;
   end process shift_command;

   serial_response <= serial_command_shift(34) when axi_state = CHECK_SPEED else '1';

   -- the serial command is expected to have a start and stop bit - to avoid a counter -
   -- and a two bit code field in the uppper two bits.
   -- these decode as follows:
   -- 00 - read address
   -- 01 - write address
   -- 10 - write data
   -- 11 - read data - slightly more involved - when detected the read data is registered into the shift and passed out
   -- 11 is used for read data as if the input is tied high the output will simply reflect whatever was
   -- captured but will not result in any activity
   -- it is expected that the write data is setup BEFORE the write address
   shift_decode : process (s_axi_aclk)
   begin
      if s_axi_aclk'event and s_axi_aclk = '1' then
         load_data <= '0';
         capture_data <= '0';
         write_access <= '0';
         read_access <= '0';
         if serial_command_shift(36) = '0' and serial_command_shift(35) = '1' and serial_command_shift(0) = '1' then
            if serial_command_shift(34) = '1' and serial_command_shift(33) = '1' then
               load_data <= '1';
            elsif serial_command_shift(34) = '1' and serial_command_shift(33) = '0' then
               capture_data <= '1';
            elsif serial_command_shift(34) = '0' and serial_command_shift(33) = '1' then
               write_access <= '1';
            else
               read_access <= '1';
            end if;
         end if;
      end if;
   end process shift_decode;


   -- don't reset this  - it will always be updated before it is used..
   -- it does need an init value (all ones)
   -- Create fully synchronous reset in the s_axi clock domain.
   gen_count : process (s_axi_aclk)
   begin
      if s_axi_aclk'event and s_axi_aclk = '1' then
         count_shift <= count_shift(19 downto 0) & s_axi_reset;
      end if;
   end process gen_count;

end rtl;

