-------------------------------------------------------------------------------
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

-- Output     Output      Phase    Duty Cycle   Pk-to-Pk     Phase
-- Clock     Freq (MHz)  (degrees)    (%)     Jitter (ps)  Error (ps)
------------------------------------------------------------------------------
-- clk_out1   125.000      0.000      50.0       91.364     85.928
-- clk_out2   125.000     90.000      50.0       70.716     85.928
--
------------------------------------------------------------------------------
-- Input Clock   Input Freq (MHz)   Input Jitter (UI)
------------------------------------------------------------------------------
-- primary         125.000            0.010

library ieee;
use ieee.std_logic_1164.all;

library unisim;
use unisim.vcomponents.all;

entity tri_mode_ethernet_mac_0_support_clocking is
port
 (-- Clock in ports
  clk_in1           : in     std_logic;
  -- Clock out ports
  clk_out1          : out    std_logic;
  clk_out2          : out    std_logic;
  -- Status and control signals
  reset             : in     std_logic;
  locked            : out    std_logic
 );
end tri_mode_ethernet_mac_0_support_clocking;

architecture xilinx of tri_mode_ethernet_mac_0_support_clocking is
  -- Input clock buffering / unused connectors
  signal clkin1           : std_logic;
  -- Output clock buffering / unused connectors
  signal clkfbout         : std_logic;
  signal clkfboutb_unused : std_logic;
  signal clkout0          : std_logic;
  signal clkout0b_unused  : std_logic;
  signal clkout1          : std_logic;
  signal clkout1b_unused  : std_logic;
  signal clkout2          : std_logic;
  signal clkout2b_unused  : std_logic;
  signal clkout3          : std_logic;
  signal clkout3_unused   : std_logic;
  signal clkout3b_unused  : std_logic;
  signal clkout4_unused   : std_logic;
  signal clkout5_unused   : std_logic;
  signal clkout6_unused   : std_logic;
  -- Dynamic programming unused signals
  signal do_unused        : std_logic_vector(15 downto 0);
  signal drdy_unused      : std_logic;
  -- Dynamic phase shift unused signals
  signal psdone_unused    : std_logic;
  -- Unused status signals
  signal clkfbstopped_unused : std_logic;
  signal clkinstopped_unused : std_logic;
 
begin


  -- Clocking primitive
  --------------------------------------
  -- Instantiation of the MMCM primitive
  --    * Unused inputs are tied off
  --    * Unused outputs are labeled unused

  
  mmcm_adv_inst : MMCME2_ADV
  
  generic map
   (BANDWIDTH            => "OPTIMIZED",
    COMPENSATION         => "ZHOLD",
    DIVCLK_DIVIDE        => 1,
    CLKFBOUT_MULT_F      => 5.000,
    CLKFBOUT_PHASE       => 0.000,
    CLKOUT0_DIVIDE_F     => 5.000,
    CLKOUT0_PHASE        => 0.000,
    CLKOUT0_DUTY_CYCLE   => 0.500,
    CLKOUT1_DIVIDE       => 5,
    CLKOUT1_PHASE        => 90.000,
    CLKOUT1_DUTY_CYCLE   => 0.500,
    CLKOUT2_DIVIDE       => 5,
    CLKOUT2_PHASE        => 0.000,
    CLKOUT2_DUTY_CYCLE   => 0.500,
    CLKIN1_PERIOD        => 8.000,
    REF_JITTER1          => 0.010)
  port map
    -- Output clocks
   (CLKFBOUT            => clkfbout,
    CLKFBOUTB           => clkfboutb_unused,
    CLKOUT0             => clkout0,
    CLKOUT0B            => clkout0b_unused,
    CLKOUT1             => clkout1,
    CLKOUT1B            => clkout1b_unused,
    CLKOUT2             => clkout2,
    CLKOUT2B            => clkout2b_unused,
    CLKOUT3             => clkout3_unused,
    CLKOUT3B            => clkout3b_unused,
    CLKOUT4             => clkout4_unused,
    CLKOUT5             => clkout5_unused,
    CLKOUT6             => clkout6_unused,
    -- Input clock control
    CLKFBIN             => clkfbout,
    CLKIN1              => clk_in1,
    CLKIN2              => '0',
    -- Tied to always select the primary input clock
    CLKINSEL            => '1',
    -- Ports for dynamic reconfiguration
    DADDR               => (others => '0'),
    DCLK                => '0',
    DEN                 => '0',
    DI                  => (others => '0'),
    DO                  => do_unused,
    DRDY                => drdy_unused,
    DWE                 => '0',
    -- Ports for dynamic phase shift
    PSCLK               => '0',
    PSEN                => '0',
    PSINCDEC            => '0',
    PSDONE              => psdone_unused,
 
    -- Other control and status signals
    LOCKED              => locked,
 
    CLKINSTOPPED        => clkinstopped_unused,
    CLKFBSTOPPED        => clkfbstopped_unused,
    PWRDWN              => '0',
    RST                 => reset);

  -- Output buffering
  -------------------------------------

  clkout1_buf : BUFGCE
  port map
   (O   => clk_out1,
    CE  => '1',
    I   => clkout0);
    
  clkout2_buf : BUFGCE
  port map
   (O   => clk_out2,
    CE  => '1',
    I   => clkout1);

 
end xilinx;
