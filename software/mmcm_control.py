from command import *
import socket
import time

Delay=0.001

###################################################
# functions for mmcm control
###################################################
def mmcm_reconfig(s, cmd, clkb_mult, clkb_frac, clk_div, clk_id, clkout_div_high,clkout_div_low,duty_50_force, clkout_frac, phase_mux, phase_dalay):
    # readme
    # clock = clk * clkb_mult.clkb_frac / clk_div / (clkout_div_high+clkout_div_low).clkout_frac
    # clkb_mult : 2 to 64
    # clkb_frac : 4 bits, bit 3:1 with 0.125 accuracy, bit 0 for enable
    # clk_div : 1 to 128
    # clkout_div_high : 1 to 64
    # clkout_div_low : 1 to 64
    # phase_mux : 1 to 7, resolution is 1/8 VCO period, VCO frequency is 200MHz * clkb_mult
    # clkout_frac : same with clkb_frac

    # clk_id 0xA
    # clkb_mult, clkb_frac, clk_div
    # clkb_mult = 0x1
    # clkb_frac = 0x0
    # clk_div = 0x1
    bandwidth = "HIGH"
    # bandwidth :
    # "LOW" : Low Bandwidth
    # "LOW_SS" : low Spread spectrum bandwidth
    # "HIGH" : High bandwidth
    # "OPTIMIZED" : Optimized bandwidth

    #
    # power bits
    #
    ret = cmd.cmd_write_register(0,0xFFFF)
    s.sendall(ret)
    # time.sleep(Delay)
    ret = cmd.cmd_write_register(1,0x0000)
    s.sendall(ret)
    # time.sleep(Delay)
    ret = cmd.cmd_write_register(2,0x0028)
    s.sendall(ret)
    # time.sleep(Delay)

    #
    # ClkReg1 for CLKOUT 0~6
    #
    # HIGH_TIME = clkout_div // 2
    if duty_50_force == 1:
        HIGH_TIME = (clkout_div_high+clkout_div_low) // 2
        if ((clkout_div_high+clkout_div_low) % 2) == 1:
            LOW_TIME = HIGH_TIME + 1
        else:
            LOW_TIME = HIGH_TIME
    else:
        HIGH_TIME = clkout_div_high
        LOW_TIME = clkout_div_low

    clkout_reg_1 = (HIGH_TIME << 6) + LOW_TIME + (phase_mux << 13)
    # mask
    clkout_reg_1_hex = (clkout_reg_1) & 0x0FFF
    # print hex(clkout_reg_1_hex)
    ret = cmd.cmd_write_register(3,clkout_reg_1_hex)
    s.sendall(ret)
    # time.sleep(Delay)
    # bit mask : refer to datasheet
    ret = cmd.cmd_write_register(4,0x1000)
    s.sendall(ret)
    # time.sleep(Delay)
    # DRP Address
    rom_id = 5
    if      clk_id == 0:
        ret = cmd.cmd_write_register(rom_id,0x0008)
    elif clk_id == 1:
        ret = cmd.cmd_write_register(rom_id,0x000A)
    elif clk_id == 2:
        ret = cmd.cmd_write_register(rom_id,0x000C)
    elif clk_id == 3:
        ret = cmd.cmd_write_register(rom_id,0x000E)
    elif clk_id == 4:
        ret = cmd.cmd_write_register(rom_id,0x0010)
    elif clk_id == 5:
        ret = cmd.cmd_write_register(rom_id,0x0006)
    elif clk_id == 6:
        ret = cmd.cmd_write_register(rom_id,0x0012)
    s.sendall(ret)
    # time.sleep(Delay)

    #
    # ClkReg2 for CLKOUT 0~6
    #
    NO_COUNT = 1 if (clkout_div_high+clkout_div_low) == 1 else 0
    if duty_50_force == 1:
        EDGE = 1 if ((clkout_div_high+clkout_div_low) % 2) == 1 else 0
    else:
        EDGE = 0
    # FRAC_WF_R is been set to 0
    clkout_reg_2 = (NO_COUNT << 6) + (EDGE << 7) + (clkout_frac << 11) + phase_dalay
    # mask
    if clk_id == 0:
        clkout_reg_2_hex = (clkout_reg_2) & 0x78FF
    else:
        clkout_reg_2_hex = (clkout_reg_2) & 0x00FF
    ret = cmd.cmd_write_register(6,clkout_reg_2_hex)
    s.sendall(ret)
    # time.sleep(Delay)
    # bit mask : refer to datasheet
    if clk_id == 0:
        ret = cmd.cmd_write_register(7,0x8000)
    elif (clk_id == 5) or (clk_id == 6):
        ret = cmd.cmd_write_register(7,0xC000)
    else:
        ret = cmd.cmd_write_register(7,0xFC00)
    s.sendall(ret)
    # time.sleep(Delay)
    # DRP Address
    rom_id = 8
    if      clk_id == 0:
        ret = cmd.cmd_write_register(rom_id,0x0009)
    elif clk_id == 1:
        ret = cmd.cmd_write_register(rom_id,0x000B)
    elif clk_id == 2:
        ret = cmd.cmd_write_register(rom_id,0x000D)
    elif clk_id == 3:
        ret = cmd.cmd_write_register(rom_id,0x000F)
    elif clk_id == 4:
        ret = cmd.cmd_write_register(rom_id,0x0011)
    elif clk_id == 5:
        ret = cmd.cmd_write_register(rom_id,0x0007)
    elif clk_id == 6:
        ret = cmd.cmd_write_register(rom_id,0x0013)
    s.sendall(ret)
    # time.sleep(Delay)

    #
    # divider
    #
    NO_COUNT = 1 if clk_div == 1 else 0
    EDGE = 1 if (clk_div % 2) == 1 else 0
    HIGH_TIME = clk_div // 2
    # the duty is 50%, so the LOW TIME equals to HIGH TIME
    LOW_TIME = HIGH_TIME
    div_reg = (EDGE << 13) + (NO_COUNT << 12) + (HIGH_TIME << 6) + LOW_TIME
    # mask
    div_reg = (div_reg) & 0x3fff
    ret = cmd.cmd_write_register(9,div_reg)
    s.sendall(ret)
    # time.sleep(Delay)
    # bit mask : refer to datasheet
    ret = cmd.cmd_write_register(10,0xC000)
    s.sendall(ret)
    # time.sleep(Delay)
    # DRP Address
    ret = cmd.cmd_write_register(11,0x0016)
    s.sendall(ret)
    # time.sleep(Delay)

    #
    # reg1 for feedback
    #
    HIGH_TIME = clkb_mult // 2
    # the duty is 50%, so the LOW TIME equals to HIGH TIME
    LOW_TIME = HIGH_TIME
    clkb_reg_1 = (HIGH_TIME << 6) + LOW_TIME
    # mask
    clkb_reg_1_hex = (clkb_reg_1) & 0x0FFF
    ret = cmd.cmd_write_register(12,clkb_reg_1_hex)
    s.sendall(ret)
    # time.sleep(Delay)
    # bit mask : refer to datasheet
    ret = cmd.cmd_write_register(13,0x1000)
    s.sendall(ret)
    # time.sleep(Delay)
    # DRP Address
    ret = cmd.cmd_write_register(14,0x0014)
    s.sendall(ret)
    # time.sleep(Delay)

    #
    # reg2 for feedback
    #
    NO_COUNT = 1 if clkb_mult == 1 else 0
    EDGE = 1 if (clkb_mult % 2) == 1 else 0
    # FRAC_WF_R is been set to 0
    clkb_reg_2 = (NO_COUNT << 6) + (EDGE << 7) + (clkb_frac << 11)
    # mask
    clkb_reg_2 = (clkb_reg_2) & 0x78C0
    ret = cmd.cmd_write_register(15,clkb_reg_2)
    s.sendall(ret)
    # time.sleep(Delay)
    # bit mask : refer to datasheet
    ret = cmd.cmd_write_register(16,0x8000)
    s.sendall(ret)
    # time.sleep(Delay)
    # DRP Address
    ret = cmd.cmd_write_register(17,0x0015)
    s.sendall(ret)
    # time.sleep(Delay)

    #
    # reg1 for lock
    #
    lock_reg = lock_table[clkb_mult-1];
    lock_reg1 = (lock_reg >> 20) & 0x03FF
    ret = cmd.cmd_write_register(18,lock_reg1)
    s.sendall(ret)
    # time.sleep(Delay)
    # bit mask : refer to datasheet
    ret = cmd.cmd_write_register(19,0xFC00)
    s.sendall(ret)
    # time.sleep(Delay)
    # DRP Address
    ret = cmd.cmd_write_register(20,0x0018)
    s.sendall(ret)
    # time.sleep(Delay)

    #
    # reg2 for lock
    #
    lock_reg2 = (((lock_reg >> 30) & 0x001F) << 10) + (lock_reg & 0x03FF)
    ret = cmd.cmd_write_register(21,lock_reg2)
    s.sendall(ret)
    # time.sleep(Delay)
    # bit mask : refer to datasheet
    ret = cmd.cmd_write_register(22,0x8000)
    s.sendall(ret)
    # time.sleep(Delay)
    # DRP Address
    ret = cmd.cmd_write_register(23,0x0019)
    s.sendall(ret)
    # time.sleep(Delay)

    #
    # reg3 for lock
    #
    lock_reg3 = (((lock_reg >> 35) & 0x001F) << 10) + ((lock_reg >> 10) & 0x03FF)
    ret = cmd.cmd_write_register(24,lock_reg3)
    s.sendall(ret)
    # time.sleep(Delay)
    # bit mask : refer to datasheet
    ret = cmd.cmd_write_register(25,0x8000)
    s.sendall(ret)
    # time.sleep(Delay)
    # DRP Address
    ret = cmd.cmd_write_register(26,0x001A)
    s.sendall(ret)
    # time.sleep(Delay)

    #
    # reg1 for filter
    #
    if bandwidth == "LOW":
        filter_reg = filter_table_low[clkb_mult-1]
    elif bandwidth == "LOW_SS":
        filter_reg = filter_table_low_ss[clkb_mult-1]
    elif bandwidth == "HIGH":
        filter_reg = filter_table_high[clkb_mult-1]
    elif bandwidth == "OPTIMIZED":
        filter_reg = filter_table_optimized[clkb_mult-1]
    filter_reg1 = (((filter_reg >> 9) & 0x0001) << 15) + (((filter_reg >> 7) & 0x0003) << 11) + (((filter_reg >> 6) & 0x0001) << 8)
    ret = cmd.cmd_write_register(27,filter_reg1)
    s.sendall(ret)
    # time.sleep(Delay)
    # bit mask : refer to datasheet
    ret = cmd.cmd_write_register(28,0x66FF)
    s.sendall(ret)
    # time.sleep(Delay)
    # DRP Address
    ret = cmd.cmd_write_register(29,0x004E)
    s.sendall(ret)
    # time.sleep(Delay)

    #
    # reg2 for filter
    #
    filter_reg2 = (((filter_reg >> 5) & 0x0001) << 15) + (((filter_reg >> 3) & 0x0003) << 11) + (((filter_reg >> 1) & 0x0003) << 7) + (((filter_reg) & 0x0001) << 4)
    ret = cmd.cmd_write_register(30,filter_reg2)
    s.sendall(ret)
    # time.sleep(Delay)
    # bit mask : refer to datasheet
    ret = cmd.cmd_write_register(31,0x666F)
    s.sendall(ret)
    # time.sleep(Delay)
    # DRP Address
    ret = cmd.cmd_write_register(32,0x004F)
    s.sendall(ret)
    # time.sleep(Delay)

    #
    # power bits
    #
    ret = cmd.cmd_write_register(33,0x0000)
    s.sendall(ret)
    # time.sleep(Delay)
    ret = cmd.cmd_write_register(34,0x0000)
    s.sendall(ret)
    # time.sleep(Delay)
    ret = cmd.cmd_write_register(35,0x0028)
    s.sendall(ret)
    # time.sleep(Delay)


    #
    # fre flag
    #
    if (clkout_frac & 0x1) == 1:
        fre = 200.0 * clkb_mult / clk_div / ( (clkout_div_high+clkout_div_low)+ (clkout_frac >> 0x1)*0.125 )
    else:
        fre = 200.0 * clkb_mult / clk_div / (clkout_div_high+clkout_div_low)
    print "clock", clk_id, "=", fre
    #if fre > 101 :
    #    ret = cmd.cmd_write_register(36,0x8002)
    #elif fre > 101 :
    #    ret = cmd.cmd_write_register(36,0x8001)
    #else:
    #    ret = cmd.cmd_write_register(36,0x8000)
    #s.sendall(ret)
    # time.sleep(Delay)

    # time.sleep(Delay)
    #
    # RCEN
    #
    ret = cmd.cmd_send_pulse(0x01)
    s.sendall(ret)
    time.sleep(Delay)
    return 0

# global variable
lock_table = [
# This table is composed of:
# LockRefDlyLockFBDlyLockCntLockSatHighUnlockCnt
# insert underline in number: python 3.6 attribute
0b0011000110111110100011111010010000000001,
0b0011000110111110100011111010010000000001,
0b0100001000111110100011111010010000000001,
0b0101101011111110100011111010010000000001,
0b0111001110111110100011111010010000000001,
0b1000110001111110100011111010010000000001,
0b1001110011111110100011111010010000000001,
0b1011010110111110100011111010010000000001,
0b1100111001111110100011111010010000000001,
0b1110011100111110100011111010010000000001,
0b1111111111111000010011111010010000000001,
0b1111111111110011100111111010010000000001,
0b1111111111101110111011111010010000000001,
0b1111111111101011110011111010010000000001,
0b1111111111101000101011111010010000000001,
0b1111111111100111000111111010010000000001,
0b1111111111100011111111111010010000000001,
0b1111111111100010011011111010010000000001,
0b1111111111100000110111111010010000000001,
0b1111111111011111010011111010010000000001,
0b1111111111011101101111111010010000000001,
0b1111111111011100001011111010010000000001,
0b1111111111011010100111111010010000000001,
0b1111111111011001000011111010010000000001,
0b1111111111011001000011111010010000000001,
0b1111111111010111011111111010010000000001,
0b1111111111010101111011111010010000000001,
0b1111111111010101111011111010010000000001,
0b1111111111010100010111111010010000000001,
0b1111111111010100010111111010010000000001,
0b1111111111010010110011111010010000000001,
0b1111111111010010110011111010010000000001,
0b1111111111010010110011111010010000000001,
0b1111111111010001001111111010010000000001,
0b1111111111010001001111111010010000000001,
0b1111111111010001001111111010010000000001,
0b1111111111001111101011111010010000000001,
0b1111111111001111101011111010010000000001,
0b1111111111001111101011111010010000000001,
0b1111111111001111101011111010010000000001,
0b1111111111001111101011111010010000000001,
0b1111111111001111101011111010010000000001,
0b1111111111001111101011111010010000000001,
0b1111111111001111101011111010010000000001,
0b1111111111001111101011111010010000000001,
0b1111111111001111101011111010010000000001,
0b1111111111001111101011111010010000000001,
0b1111111111001111101011111010010000000001,
0b1111111111001111101011111010010000000001,
0b1111111111001111101011111010010000000001,
0b1111111111001111101011111010010000000001,
0b1111111111001111101011111010010000000001,
0b1111111111001111101011111010010000000001,
0b1111111111001111101011111010010000000001,
0b1111111111001111101011111010010000000001,
0b1111111111001111101011111010010000000001,
0b1111111111001111101011111010010000000001,
0b1111111111001111101011111010010000000001,
0b1111111111001111101011111010010000000001,
0b1111111111001111101011111010010000000001,
0b1111111111001111101011111010010000000001,
0b1111111111001111101011111010010000000001,
0b1111111111001111101011111010010000000001,
0b1111111111001111101011111010010000000001]

filter_table_low = [
# CPRESLFHF
0b0010111100,
0b0010111100,
0b0010111100,
0b0010111100,
0b0010011100,
0b0010101100,
0b0010110100,
0b0010001100,
0b0010010100,
0b0010010100,
0b0010100100,
0b0010111000,
0b0010111000,
0b0010111000,
0b0010111000,
0b0010000100,
0b0010000100,
0b0010000100,
0b0010011000,
0b0010011000,
0b0010011000,
0b0010011000,
0b0010011000,
0b0010011000,
0b0010011000,
0b0010101000,
0b0010101000,
0b0010101000,
0b0010101000,
0b0010101000,
0b0010110000,
0b0010110000,
0b0010110000,
0b0010110000,
0b0010110000,
0b0010110000,
0b0010110000,
0b0010110000,
0b0010110000,
0b0010110000,
0b0010110000,
0b0010110000,
0b0010110000,
0b0010110000,
0b0010110000,
0b0010110000,
0b0010110000,
0b0010001000,
0b0010001000,
0b0010001000,
0b0010001000,
0b0010001000,
0b0010001000,
0b0010001000,
0b0010001000,
0b0010001000,
0b0010001000,
0b0010001000,
0b0010001000,
0b0010001000,
0b0010001000,
0b0010001000,
0b0010001000,
0b0010001000]

filter_table_low_ss = [
# CPRESLFHF
0b0010111111,
0b0010111111,
0b0010111111,
0b0010111111,
0b0010011111,
0b0010101111,
0b0010110111,
0b0010001111,
0b0010010111,
0b0010010111,
0b0010100111,
0b0010111011,
0b0010111011,
0b0010111011,
0b0010111011,
0b0010000111,
0b0010000111,
0b0010000111,
0b0010011011,
0b0010011011,
0b0010011011,
0b0010011011,
0b0010011011,
0b0010011011,
0b0010011011,
0b0010101011,
0b0010101011,
0b0010101011,
0b0010101011,
0b0010101011,
0b0010110011,
0b0010110011,
0b0010110011,
0b0010110011,
0b0010110011,
0b0010110011,
0b0010110011,
0b0010110011,
0b0010110011,
0b0010110011,
0b0010110011,
0b0010110011,
0b0010110011,
0b0010110011,
0b0010110011,
0b0010110011,
0b0010110011,
0b0010001011,
0b0010001011,
0b0010001011,
0b0010001011,
0b0010001011,
0b0010001011,
0b0010001011,
0b0010001011,
0b0010001011,
0b0010001011,
0b0010001011,
0b0010001011,
0b0010001011,
0b0010001011,
0b0010001011,
0b0010001011,
0b0010001011]

filter_table_high = [
# CPRESLFHF
0b0010111100,
0b0100111100,
0b0101101100,
0b0111011100,
0b1101011100,
0b1110101100,
0b1110110100,
0b1111001100,
0b1110010100,
0b1111010100,
0b1111100100,
0b1101000100,
0b1111100100,
0b1111100100,
0b1111100100,
0b1111100100,
0b1111010100,
0b1111010100,
0b1100000100,
0b1100000100,
0b1100000100,
0b0101110000,
0b0101110000,
0b0101110000,
0b0101110000,
0b0011010000,
0b0011010000,
0b0011010000,
0b0011010000,
0b0011010000,
0b0011010000,
0b0011010000,
0b0011010000,
0b0011010000,
0b0011010000,
0b0011010000,
0b0011010000,
0b0011010000,
0b0011010000,
0b0011010000,
0b0011010000,
0b0010100000,
0b0010100000,
0b0010100000,
0b0010100000,
0b0010100000,
0b0111000100,
0b0111000100,
0b0100110000,
0b0100110000,
0b0100110000,
0b0100110000,
0b0110000100,
0b0110000100,
0b0101011000,
0b0101011000,
0b0101011000,
0b0010010000,
0b0010010000,
0b0010010000,
0b0010010000,
0b0100101000,
0b0011110000,
0b0011110000]

filter_table_optimized = [
# CPRESLFHF
0b0010111100,
0b0100111100,
0b0101101100,
0b0111011100,
0b1101011100,
0b1110101100,
0b1110110100,
0b1111001100,
0b1110010100,
0b1111010100,
0b1111100100,
0b1101000100,
0b1111100100,
0b1111100100,
0b1111100100,
0b1111100100,
0b1111010100,
0b1111010100,
0b1100000100,
0b1100000100,
0b1100000100,
0b0101110000,
0b0101110000,
0b0101110000,
0b0101110000,
0b0011010000,
0b0011010000,
0b0011010000,
0b0011010000,
0b0011010000,
0b0011010000,
0b0011010000,
0b0011010000,
0b0011010000,
0b0011010000,
0b0011010000,
0b0011010000,
0b0011010000,
0b0011010000,
0b0011010000,
0b0011010000,
0b0010100000,
0b0010100000,
0b0010100000,
0b0010100000,
0b0010100000,
0b0111000100,
0b0111000100,
0b0100110000,
0b0100110000,
0b0100110000,
0b0100110000,
0b0110000100,
0b0110000100,
0b0101011000,
0b0101011000,
0b0101011000,
0b0010010000,
0b0010010000,
0b0010010000,
0b0010010000,
0b0100101000,
0b0011110000,
0b0011110000]

if __name__ == "__main__":
    host = '192.168.2.3'
    port = 1024
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.connect((host,port))
    cmd = Cmd()
    # mmcm_reconfig(s, cmd, clkb_mult, clkb_frac, clk_div, clk_id, clkout_div, clkout_frac)
    mmcm_reconfig(s, cmd, 0x6, 0x0, 0x1, 0x0, 0x20, 0x0)
    s.close()
