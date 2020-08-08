--------------------------------------------------------------------------------
-- Title      : VHDL Support Level Module
-- File       : tri_mode_ethernet_mac_0_support.vhd
-- Author     : Xilinx Inc.
-- -----------------------------------------------------------------------------
-- (c) Copyright 2013 Xilinx, Inc. All rights reserved.
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
-- Description: This module holds the support level for the Tri-Mode
--              Ethernet MAC IP.  It contains potentially shareable FPGA
--              resources such as clocking, reset and IDELAYCTRL logic.
--              This can be used as-is in a single core design, or adapted
--              for use with multi-core implementations.
--------------------------------------------------------------------------------

library unisim;
use unisim.vcomponents.all;

library ieee;
use ieee.std_logic_1164.all;

--------------------------------------------------------------------------------
-- The entity declaration for the block support level
--------------------------------------------------------------------------------
entity tri_mode_ethernet_mac_0_support is
   port(

      gtx_clk                    : in  std_logic;
      gtx_clk_out                : out  std_logic;
      gtx_clk90_out              : out  std_logic;

      -- Reference clock for IDELAYCTRL's
      refclk                     : in  std_logic;
      -- asynchronous reset
      glbl_rstn                  : in  std_logic;
      rx_axi_rstn                : in  std_logic;
      tx_axi_rstn                : in  std_logic;

      -- Receiver Interface
      ----------------------------
      rx_enable                  : out std_logic;

      rx_statistics_vector       : out std_logic_vector(27 downto 0);
      rx_statistics_valid        : out std_logic;

      rx_mac_aclk                : out std_logic;
      rx_reset                   : out std_logic;
      rx_axis_mac_tdata          : out std_logic_vector(7 downto 0);
      rx_axis_mac_tvalid         : out std_logic;
      rx_axis_mac_tlast          : out std_logic;
      rx_axis_mac_tuser          : out std_logic;

      -- Transmitter Interface
      -------------------------------
      tx_enable                  : out std_logic;

      tx_ifg_delay               : in  std_logic_vector(7 downto 0);
      tx_statistics_vector       : out std_logic_vector(31 downto 0);
      tx_statistics_valid        : out std_logic;

      tx_mac_aclk                : out std_logic;
      tx_reset                   : out std_logic;
      tx_axis_mac_tdata          : in  std_logic_vector(7 downto 0);
      tx_axis_mac_tvalid         : in  std_logic;
      tx_axis_mac_tlast          : in  std_logic;
      tx_axis_mac_tuser          : in  std_logic_vector(0 downto 0);
      tx_axis_mac_tready         : out std_logic;

      -- MAC Control Interface
      ------------------------
      pause_req                  : in  std_logic;
      pause_val                  : in  std_logic_vector(15 downto 0);

      speedis100                 : out std_logic;
      speedis10100               : out std_logic;
      -- RGMII Interface
      ------------------
      rgmii_txd                  : out std_logic_vector(3 downto 0);
      rgmii_tx_ctl               : out std_logic;
      rgmii_txc                  : out std_logic;
      rgmii_rxd                  : in  std_logic_vector(3 downto 0);
      rgmii_rx_ctl               : in  std_logic;
      rgmii_rxc                  : in  std_logic;
      inband_link_status         : out std_logic;
      inband_clock_speed         : out std_logic_vector(1 downto 0);
      inband_duplex_status       : out std_logic;

      
      -- MDIO Interface
      -----------------
      mdio                       : inout std_logic;
      mdc                        : out std_logic;

      -- AXI-Lite Interface
      -----------------
      s_axi_aclk                 : in  std_logic;
      s_axi_resetn               : in  std_logic;

      s_axi_awaddr               : in  std_logic_vector(11 downto 0);
      s_axi_awvalid              : in  std_logic;
      s_axi_awready              : out std_logic;

      s_axi_wdata                : in  std_logic_vector(31 downto 0);
      s_axi_wvalid               : in  std_logic;
      s_axi_wready               : out std_logic;

      s_axi_bresp                : out std_logic_vector(1 downto 0);
      s_axi_bvalid               : out std_logic;
      s_axi_bready               : in  std_logic;

      s_axi_araddr               : in  std_logic_vector(11 downto 0);
      s_axi_arvalid              : in  std_logic;
      s_axi_arready              : out std_logic;

      s_axi_rdata                : out std_logic_vector(31 downto 0);
      s_axi_rresp                : out std_logic_vector(1 downto 0);
      s_axi_rvalid               : out std_logic;
      s_axi_rready               : in  std_logic;

      mac_irq                    : out std_logic

   );
end tri_mode_ethernet_mac_0_support;

architecture wrapper of tri_mode_ethernet_mac_0_support is

  ------------------------------------------------------------------------------
  -- Component declaration for the TEMAC core
  ------------------------------------------------------------------------------
   component tri_mode_ethernet_mac_0
   port(
      gtx_clk                    : in  std_logic;
      gtx_clk90                  : in  std_logic;
      
      -- asynchronous reset
      glbl_rstn                  : in  std_logic;
      rx_axi_rstn                : in  std_logic;
      tx_axi_rstn                : in  std_logic;

      -- Receiver Interface
      ----------------------------
      rx_enable                  : out std_logic;

      rx_statistics_vector       : out std_logic_vector(27 downto 0);
      rx_statistics_valid        : out std_logic;

      rx_mac_aclk                : out std_logic;
      rx_reset                   : out std_logic;
      rx_axis_mac_tdata          : out std_logic_vector(7 downto 0);
      rx_axis_mac_tvalid         : out std_logic;
      rx_axis_mac_tlast          : out std_logic;
      rx_axis_mac_tuser          : out std_logic;

      -- Transmitter Interface
      -------------------------------
      tx_enable                  : out std_logic;

      tx_ifg_delay               : in  std_logic_vector(7 downto 0);
      tx_statistics_vector       : out std_logic_vector(31 downto 0);
      tx_statistics_valid        : out std_logic;

      tx_mac_aclk                : out std_logic;
      tx_reset                   : out std_logic;
      tx_axis_mac_tdata          : in  std_logic_vector(7 downto 0);
      tx_axis_mac_tvalid         : in  std_logic;
      tx_axis_mac_tlast          : in  std_logic;
      tx_axis_mac_tuser          : in  std_logic_vector(0 downto 0);
      tx_axis_mac_tready         : out std_logic;
      -- MAC Control Interface
      ------------------------
      pause_req                  : in  std_logic;
      pause_val                  : in  std_logic_vector(15 downto 0);

      speedis100                 : out std_logic;
      speedis10100               : out std_logic;
      -- RGMII Interface
      ------------------
      rgmii_txd                  : out std_logic_vector(3 downto 0);
      rgmii_tx_ctl               : out std_logic;
      rgmii_txc                  : out std_logic;
      rgmii_rxd                  : in  std_logic_vector(3 downto 0);
      rgmii_rx_ctl               : in  std_logic;
      rgmii_rxc                  : in  std_logic;
      inband_link_status         : out std_logic;
      inband_clock_speed         : out std_logic_vector(1 downto 0);
      inband_duplex_status       : out std_logic;

      -- MDIO Interface
      -----------------
      mdio                       : inout std_logic;
      mdc                        : out std_logic;
      -- AXI-Lite Interface
      -----------------
      s_axi_aclk                 : in  std_logic;
      s_axi_resetn               : in  std_logic;

      s_axi_awaddr               : in  std_logic_vector(11 downto 0);
      s_axi_awvalid              : in  std_logic;
      s_axi_awready              : out std_logic;

      s_axi_wdata                : in  std_logic_vector(31 downto 0);
      s_axi_wvalid               : in  std_logic;
      s_axi_wready               : out std_logic;

      s_axi_bresp                : out std_logic_vector(1 downto 0);
      s_axi_bvalid               : out std_logic;
      s_axi_bready               : in  std_logic;

      s_axi_araddr               : in  std_logic_vector(11 downto 0);
      s_axi_arvalid              : in  std_logic;
      s_axi_arready              : out std_logic;

      s_axi_rdata                : out std_logic_vector(31 downto 0);
      s_axi_rresp                : out std_logic_vector(1 downto 0);
      s_axi_rvalid               : out std_logic;
      s_axi_rready               : in  std_logic;

      mac_irq                    : out std_logic

   );
   end component;

  ------------------------------------------------------------------------------
  -- Shareable logic component declarations
  ------------------------------------------------------------------------------
  component tri_mode_ethernet_mac_0_support_clocking
  port (
        clk_in1                  : in     std_logic;
        clk_out1                 : out    std_logic;
        clk_out2                 : out    std_logic;
        reset                    : in     std_logic;
        locked                   : out    std_logic
    );
  end component;

  component tri_mode_ethernet_mac_0_support_resets
  port (
       glbl_rstn                 : in     std_logic;
       refclk                    : in     std_logic;
       idelayctrl_ready          : in     std_logic;
       idelayctrl_reset_out      : out    std_logic;     -- The reset pulse for the IDELAYCTRL.

       gtx_clk                   : in     std_logic;
       gtx_dcm_locked            : in     std_logic;
       gtx_mmcm_rst_out          : out    std_logic   -- The reset pulse for the MMCM.
    );
  end component;

    -- Internal signals
    signal mmcm_out_gtx_clk      : std_logic;
    signal mmcm_out_gtx_clk90    : std_logic;
    signal gtx_mmcm_rst          : std_logic;
    signal gtx_mmcm_locked       : std_logic;
    signal idelayctrl_reset      : std_logic;
    signal idelayctrl_ready      : std_logic;


begin

   -----------------------------------------------------------------------------
   -- Shareable logic
   -----------------------------------------------------------------------------

      gtx_clk_out                <= mmcm_out_gtx_clk;
      gtx_clk90_out              <= mmcm_out_gtx_clk90;

  -- Instantiate the sharable clocking logic
  tri_mode_ethernet_mac_support_clocking_i : tri_mode_ethernet_mac_0_support_clocking
  port map (
      clk_in1                    => gtx_clk,
      clk_out1                   => mmcm_out_gtx_clk,
      clk_out2                   => mmcm_out_gtx_clk90,
      reset                      => gtx_mmcm_rst,
      locked                     => gtx_mmcm_locked
 );

  -- Instantiate the sharable reset logic
  tri_mode_ethernet_mac_support_resets_i : tri_mode_ethernet_mac_0_support_resets
  port map(
      glbl_rstn                  => glbl_rstn,
      refclk                     => refclk,
      
      idelayctrl_ready           => idelayctrl_ready,
      
      idelayctrl_reset_out       => idelayctrl_reset,
      gtx_clk                    => gtx_clk,
      gtx_dcm_locked             => gtx_mmcm_locked,
      gtx_mmcm_rst_out           => gtx_mmcm_rst
   );

   -- An IDELAYCTRL primitive needs to be instantiated for the Fixed Tap Delay
   -- mode of the IDELAY.
   tri_mode_ethernet_mac_idelayctrl_common_i : IDELAYCTRL
    generic map (
      SIM_DEVICE => "7SERIES"
    )
    port map (
      RDY                    => idelayctrl_ready,
      REFCLK                 => refclk,
      RST                    => idelayctrl_reset
   );


   -----------------------------------------------------------------------------
   -- Instantiate the TEMAC core
   -----------------------------------------------------------------------------
   tri_mode_ethernet_mac_i : tri_mode_ethernet_mac_0
   port map (
      gtx_clk                    => mmcm_out_gtx_clk,
      gtx_clk90                  => mmcm_out_gtx_clk90,
      -- asynchronous reset
      glbl_rstn                  => glbl_rstn,
      rx_axi_rstn                => rx_axi_rstn,
      tx_axi_rstn                => tx_axi_rstn,


      -- Receiver Interface
      ----------------------------
      rx_enable                  => rx_enable,

      rx_statistics_vector       => rx_statistics_vector,
      rx_statistics_valid        => rx_statistics_valid,

      rx_mac_aclk                => rx_mac_aclk,
      rx_reset                   => rx_reset,
      rx_axis_mac_tdata          => rx_axis_mac_tdata,
      rx_axis_mac_tvalid         => rx_axis_mac_tvalid,
      rx_axis_mac_tlast          => rx_axis_mac_tlast,
      rx_axis_mac_tuser          => rx_axis_mac_tuser,


      -- Transmitter Interface
      -------------------------------
      tx_enable                  => tx_enable,

      tx_ifg_delay               => tx_ifg_delay,
      tx_statistics_vector       => tx_statistics_vector,
      tx_statistics_valid        => tx_statistics_valid,

      tx_mac_aclk                => tx_mac_aclk,
      tx_reset                   => tx_reset,
      tx_axis_mac_tdata          => tx_axis_mac_tdata,
      tx_axis_mac_tvalid         => tx_axis_mac_tvalid,
      tx_axis_mac_tlast          => tx_axis_mac_tlast,
      tx_axis_mac_tuser          => tx_axis_mac_tuser,
      tx_axis_mac_tready         => tx_axis_mac_tready,

      -- MAC Control Interface
      ------------------------
      pause_req                  => pause_req,
      pause_val                  => pause_val,

      speedis100                 => speedis100,
      speedis10100               => speedis10100,
      -- RGMII Interface
      ------------------
      rgmii_txd                  => rgmii_txd,
      rgmii_tx_ctl               => rgmii_tx_ctl,
      rgmii_txc                  => rgmii_txc,
      rgmii_rxd                  => rgmii_rxd,
      rgmii_rx_ctl               => rgmii_rx_ctl,
      rgmii_rxc                  => rgmii_rxc,
      inband_link_status         => inband_link_status,
      inband_clock_speed         => inband_clock_speed,
      inband_duplex_status       => inband_duplex_status,


      -- MDIO Interface
      -----------------
      mdio                       => mdio,
      mdc                        => mdc,

      -- AXI-Lite Interface
      -----------------
      s_axi_aclk                 => s_axi_aclk,
      s_axi_resetn               => s_axi_resetn,

      s_axi_awaddr               => s_axi_awaddr,
      s_axi_awvalid              => s_axi_awvalid,
      s_axi_awready              => s_axi_awready,

      s_axi_wdata                => s_axi_wdata,
      s_axi_wvalid               => s_axi_wvalid,
      s_axi_wready               => s_axi_wready,

      s_axi_bresp                => s_axi_bresp,
      s_axi_bvalid               => s_axi_bvalid,
      s_axi_bready               => s_axi_bready,

      s_axi_araddr               => s_axi_araddr,
      s_axi_arvalid              => s_axi_arvalid,
      s_axi_arready              => s_axi_arready,

      s_axi_rdata                => s_axi_rdata,
      s_axi_rresp                => s_axi_rresp,
      s_axi_rvalid               => s_axi_rvalid,
      s_axi_rready               => s_axi_rready,

      mac_irq                    => mac_irq

   );

end wrapper;

 
