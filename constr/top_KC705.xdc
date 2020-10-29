# ------------------system pins : reset & clk --------------
# --system reset active High
set_property PACKAGE_PIN AB7 [get_ports CPU_RESET]
set_property IOSTANDARD LVCMOS15 [get_ports CPU_RESET]
# system clk 200MHz IO_L12_T1_MRCC_33
set_property VCCAUX_IO DONTCARE [get_ports {SYS_CLK_P}]
set_property IOSTANDARD DIFF_SSTL15 [get_ports {SYS_CLK_P}]
set_property PACKAGE_PIN AD12 [get_ports {SYS_CLK_P}]
set_property VCCAUX_IO DONTCARE [get_ports {SYS_CLK_N}]
set_property IOSTANDARD DIFF_SSTL15 [get_ports {SYS_CLK_N}]
set_property PACKAGE_PIN AD11 [get_ports {SYS_CLK_N}]

# ------------------PINS for GBE--------------------------
# --125MHz clock, for GTP/GTH/GTX
set_property PACKAGE_PIN G8 [get_ports {SGMIICLK_Q0_P}]
set_property PACKAGE_PIN G7 [get_ports {SGMIICLK_Q0_N}]
# --PHY_RESET, MDIO, MDC
set_property PACKAGE_PIN L20      [get_ports PHY_RESET_N]
set_property IOSTANDARD  LVCMOS25 [get_ports PHY_RESET_N]
set_property PACKAGE_PIN J21      [get_ports MDIO]
set_property IOSTANDARD  LVCMOS25 [get_ports MDIO]
set_property PACKAGE_PIN R23      [get_ports MDC]
set_property IOSTANDARD  LVCMOS25 [get_ports MDC]
# --RGMII PORTS
set_property PACKAGE_PIN U28      [get_ports RGMII_RXD[3]]
set_property PACKAGE_PIN T25      [get_ports RGMII_RXD[2]]
set_property PACKAGE_PIN U25      [get_ports RGMII_RXD[1]]
set_property PACKAGE_PIN U30      [get_ports RGMII_RXD[0]]
set_property IOSTANDARD  LVCMOS25 [get_ports RGMII_RXD[3]]
set_property IOSTANDARD  LVCMOS25 [get_ports RGMII_RXD[2]]
set_property IOSTANDARD  LVCMOS25 [get_ports RGMII_RXD[1]]
set_property IOSTANDARD  LVCMOS25 [get_ports RGMII_RXD[0]]
set_property PACKAGE_PIN L28      [get_ports RGMII_TXD[3]]
set_property PACKAGE_PIN M29      [get_ports RGMII_TXD[2]]
set_property PACKAGE_PIN N25      [get_ports RGMII_TXD[1]]
set_property PACKAGE_PIN N27      [get_ports RGMII_TXD[0]]
set_property IOSTANDARD  LVCMOS25 [get_ports RGMII_TXD[3]]
set_property IOSTANDARD  LVCMOS25 [get_ports RGMII_TXD[2]]
set_property IOSTANDARD  LVCMOS25 [get_ports RGMII_TXD[1]]
set_property IOSTANDARD  LVCMOS25 [get_ports RGMII_TXD[0]]
set_property PACKAGE_PIN M27      [get_ports RGMII_TX_CTL]
set_property PACKAGE_PIN K30      [get_ports RGMII_TXC]
set_property IOSTANDARD  LVCMOS25 [get_ports RGMII_TX_CTL]
set_property IOSTANDARD  LVCMOS25 [get_ports RGMII_TXC]
set_property PACKAGE_PIN R28      [get_ports RGMII_RX_CTL]
set_property IOSTANDARD  LVCMOS25 [get_ports RGMII_RX_CTL]
set_property PACKAGE_PIN U27      [get_ports RGMII_RXC]
set_property IOSTANDARD  LVCMOS25 [get_ports RGMII_RXC]


# ------------- timing constraint for GBE --------------------------
# 200MHZ system clk
create_clock -name system_clock -period 5.0 [get_ports {SYS_CLK_P}]
# 125MHz GBE clk
create_clock -name sgmii_clock  -period 8.0 [get_ports {SGMIICLK_Q0_P}]
# set different clock domain
set_clock_groups -name async_sysclk_sgmii -asynchronous \
     -group [get_clocks -include_generated_clocks  system_clock] \
     -group [get_clocks -include_generated_clocks sgmii_clock]
set_clock_groups -asynchronous \
     -group [get_clocks -include_generated_clocks -of_objects [get_ports RGMII_RXC]] \
     -group [get_clocks -include_generated_clocks sgmii_clock]
# GBE delay setting
set_property IODELAY_GROUP tri_mode_ethernet_mac_iodelay_grp [get_cells -hier -filter {name =~ *trimac_fifo_block/trimac_sup_block/tri_mode_ethernet_mac_idelayctrl_common_i}]
#set_property IDELAY_VALUE 20 [get_cells -hier -filter {name =~ *trimac_fifo_block/trimac_sup_block/tri_mode_ethernet_mac_i/*/rgmii_interface/delay_rgmii_rx*}]
#set_property IDELAY_VALUE 20 [get_cells -hier -filter {name =~ *trimac_fifo_block/trimac_sup_block/tri_mode_ethernet_mac_i/*/rgmii_interface/rxdata_bus[*].delay_rgmii_rx*}]
# If TEMAC timing fails, use the following to relax the requirements
# The RGMII receive interface requirement allows a 1ns setup and 1ns hold - this is met but only just so constraints are relaxed
#set_input_delay -clock [get_clocks tri_mode_ethernet_mac_0_rgmii_rx_clk] -max -1.5 [get_ports {rgmii_rxd[*] rgmii_rx_ctl}]
#set_input_delay -clock [get_clocks tri_mode_ethernet_mac_0_rgmii_rx_clk] -min -2.8 [get_ports {rgmii_rxd[*] rgmii_rx_ctl}]
#set_input_delay -clock [get_clocks tri_mode_ethernet_mac_0_rgmii_rx_clk] -clock_fall -max -1.5 -add_delay [get_ports {rgmii_rxd[*] rgmii_rx_ctl}]
#set_input_delay -clock [get_clocks tri_mode_ethernet_mac_0_rgmii_rx_clk] -clock_fall -min -2.8 -add_delay [get_ports {rgmii_rxd[*] rgmii_rx_ctl}]


# ------------- timing constraint for reset ------------------------
set_false_path -from [get_pins -of_objects [get_cells -hierarchical -filter {NAME =~ *GLOBAL_RST_reg*}] -filter {NAME =~ *C}]

# ------------- control interface ignore checking ------------------
set_false_path -from [get_pins -of_objects [get_cells -hierarchical -filter {NAME =~ *control_interface_inst*sConfigReg_reg[*]}] -filter {NAME =~ *C}]
set_false_path -from [get_pins -of_objects [get_cells -hierarchical -filter {NAME =~ *control_interface_inst*sPulseReg_reg[*]}] -filter {NAME =~ *C}]
set_false_path -to [get_pins -of_objects [get_cells -hierarchical -filter {NAME =~ *control_interface_inst*sRegOut_reg[*]}] -filter {NAME =~ *D}]

# ------------- ignore checking --------------------------
#set_false_path -from [get_pins -of_objects [get_cells -hierarchical -filter {NAME =~ *sFifoWrEn_reg*}] -filter {NAME =~ *C}]
#set_false_path -to [get_pins -of_objects [get_cells -hierarchical -filter {NAME =~ *sdes_insti*SIG_PAR_reg[*]}] -filter {NAME =~ *D}]
#set_false_path -to [get_pins -of_objects [get_cells -hierarchical -filter {NAME =~ *sdes_insti*ERR_reg*}] -filter {NAME =~ *D}]

