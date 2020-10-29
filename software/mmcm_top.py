# -*- coding: utf-8 -*-
"""
Created on Mo July 22 2019
This the main python script for datataking and processing
@author: Shen
"""

from command import *

from mmcm_control import *

cmd = Cmd()

# mmcm_reconfig(s, cmd, clkb_mult, clkb_frac, clk_div, clk_id, clkout_div_high,clkout_div_low,duty_50_force, clkout_frac, phase_mux, phase_dalay)
    # readme
    # clock = clk * clkb_mult.clkb_frac / clk_div / (clkout_div_high+clkout_div_low).clkout_frac
    # clkb_mult : 2 to 64, clkb_mult must be divied by 2
    # clkb_frac : 4 bits, bit 3:1 with 0.125 accuracy, bit 0 for enable
    # clk_div : 1 to 128
    # clkout_div_high : 1 to 64
    # clkout_div_low : 1 to 64
    # duty cycle : clkout_div_high / ( clkout_div_high + clkout_div_low )
    # phase_mux : 1 to 7, resolution is 1/8 VCO period, VCO frequency is clk_in * clkb_mult / clk_div
    # For example, the clk_in frequency in KC705 is 200MHz, so the VCO frequency is 200MHz * clkb_mult / clk_div
    # phase_dalay: 1 to 64 resolution is VCO period
    # clkout_frac : same with clkb_frac



try:
    cmd.eth_init('192.168.2.3',1024)
    mmcm_reconfig(cmd, 0x6, 0x0, 0x6, 0x1, 0x05,0x05,0x0, 0x0, 0x0, 0x06)
except:
    print("error information:")
    traceback.print_exc()
    cmd.eth_close()
else:
    cmd.eth_close()
