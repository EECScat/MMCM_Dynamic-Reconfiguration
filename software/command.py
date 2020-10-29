# -*- coding: utf-8 -*-
"""
Created on Wed Oct 28 19:59:54 2020

@author: Shen
"""

import socket
import traceback

class Cmd(object):
    def __init__(self):
        self.text = "command class"

    def cmd_send_pulse(self, mask):
        buf = 0x000b0000 | (0x0000ffff & mask)
        buf = buf.to_bytes(length=4, byteorder='big', signed=False)
        return buf

    def cmd_read_status(self, addr):
        buf = (0xffff0000 & ((0x8000 + addr) << 16));
        buf = buf.to_bytes(length=4, byteorder='big', signed=False)
        return buf

    def cmd_write_register(self, addr, val):
        buf = (0xffff0000 & ((0x0020 + addr) << 16)) | (0x0000ffff & val);
        buf = buf.to_bytes(length=4, byteorder='big', signed=False)
        return buf

    def cmd_read_register(self, addr):
        buf = (0xffff0000 & ((0x8020 + addr) << 16));
        buf = buf.to_bytes(length=4, byteorder='big', signed=False)
        return buf

    def cmd_read_datafifo(self, n):
        buf0 = (0xffff0000 & (0x001a << 16)) | (0x0000ffff & (n>>16))
        buf0 = buf0.to_bytes(length=4, byteorder='big', signed=False)
        buf1 = (0xffff0000 & (0x0019 << 16)) | (0x0000ffff & n);
        buf1 = buf1.to_bytes(length=4, byteorder='big', signed=False)
        buf = buf0 + buf1
        return buf

if __name__ == "__main__":

    s = socket.socket()
    host = '192.168.2.3'
    port = 1024
    print("connecting")
    s.connect((host,port))
    s.settimeout(0.5)
    print("connected")
    while True:
        try :
            s.recv(1024)
        except socket.timeout:
            break
    
    cmd = Cmd()

    ret = cmd.cmd_read_datafifo(0x3)
    print([hex(s) for s in ret])
    
    s.close()