# MMCM_Dynamic-Reconfiguration
This repository provides a method to dynamically change the clock output frequency, phase shift, and duty cycle of the mixed-mode clock manager (MMCM) for the Xilinx® 7 series FPGA  
Useage  
  1.Move into work 
  2.Open vivado  
  3.In the TCL console: source ../scripts/readout_mmcmRC.tcl  
  4.Generate Bitstream and download it into the KC705 board  
  5.Move into sirectory software  
  6.In the terminal:python mmcm_top.py  
  
