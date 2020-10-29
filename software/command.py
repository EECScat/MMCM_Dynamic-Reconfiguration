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

    def eth_init(self,host,port):
        self.s = socket.socket()
        print("connecting")
        self.s.connect((host,port))
        self.s.settimeout(0.5)
        print("connected")
        while True:
            try :
                self.s.recv(1024)
            except socket.timeout:
                break
            
    def eth_close(self):
        self.s.close()

    def cmd_send_pulse(self, mask):
        buf = 0x000b0000 | (0x0000ffff & mask)
        buf = buf.to_bytes(length=4, byteorder='big', signed=False)
        self.s.sendall(buf)
        return buf

    def cmd_read_status(self, addr):
        buf = (0xffff0000 & ((0x8000 + addr) << 16));
        buf = buf.to_bytes(length=4, byteorder='big', signed=False)
        self.s.sendall(buf)
        return buf

    def cmd_write_register(self, addr, val):
        buf = (0xffff0000 & ((0x0020 + addr) << 16)) | (0x0000ffff & val);
        buf = buf.to_bytes(length=4, byteorder='big', signed=False)
        self.s.sendall(buf)
        return buf

    def cmd_read_register(self, addr):
        buf = (0xffff0000 & ((0x8020 + addr) << 16));
        buf = buf.to_bytes(length=4, byteorder='big', signed=False)
        self.s.sendall(buf)
        return buf

    def cmd_read_datafifo(self, n):
        buf0 = (0xffff0000 & (0x001a << 16)) | (0x0000ffff & (n>>16))
        buf0 = buf0.to_bytes(length=4, byteorder='big', signed=False)
        buf1 = (0xffff0000 & (0x0019 << 16)) | (0x0000ffff & n);
        buf1 = buf1.to_bytes(length=4, byteorder='big', signed=False)
        buf = buf0 + buf1
        self.s.sendall(buf)
        return buf

if __name__ == "__main__":
    cmd = Cmd()
    
    try:
        cmd.eth_init('192.168.2.3',1024)
        ret = cmd.cmd_read_datafifo(0x3)
        print([hex(s) for s in ret])
    except:
        traceback.print_exc()
        print("error information:")
        cmd.eth_close()
    else:
        cmd.eth_close()



