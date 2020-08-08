from ctypes import *

def data_calculate(addr_data, addr_mapsbyte,addr_mapsbyte_temp,i2c_data,musk,fcounter,framadd):
    soname = "./build/command.so"
    cmdGen = cdll.LoadLibrary(soname)
    cfun = cmdGen.data_cal
    # buf = addressof(databuf)
    cfun(c_char_p(addr_data),c_void_p(addr_mapsbyte),c_void_p(addr_mapsbyte_temp),c_void_p(i2c_data),c_void_p(musk),pointer(fcounter),framadd)

def wdtest(musk):
    soname = "./build/command.so"
    cmdGen = cdll.LoadLibrary(soname)
    cfun = cmdGen.wdtest
    # buf = addressof(databuf)
    cfun(c_void_p(musk))

class Cmd:
    soname = "./build/command.so"
    nmax = 20000

    def __init__(self):
        self.cmdGen = cdll.LoadLibrary(self.soname)
        self.buf = create_string_buffer(self.nmax)

    def cmd_send_pulse(self, mask):
        cfun = self.cmdGen.cmd_send_pulse
        buf = addressof(self.buf)
        n = cfun(byref(c_void_p(buf)), c_uint(mask))
        return self.buf.raw[0:n]

    def cmd_read_status(self, addr):
        cfun = self.cmdGen.cmd_read_status
        buf = addressof(self.buf)
        n = cfun(byref(c_void_p(buf)), c_uint(addr))
        return self.buf.raw[0:n]

    def cmd_write_memory(self, addr, aval, nval):
        cfun = self.cmdGen.cmd_write_memory
        buf = addressof(self.buf)
        n = cfun(byref(c_void_p(buf)), c_uint(addr), c_void_p(aval), c_size_t(nval))
        return self.buf.raw[0:n]

    def cmd_read_memory(self, addr, val):
        cfun = self.cmdGen.cmd_read_memory
        buf = addressof(self.buf)
        n = cfun(byref(c_void_p(buf)), c_uint(addr), c_uint(val))
        return self.buf.raw[0:n]

    def cmd_write_register(self, addr, val):
        cfun = self.cmdGen.cmd_write_register
        buf = addressof(self.buf)
        n = cfun(byref(c_void_p(buf)), c_uint(addr), c_uint(val))
        return self.buf.raw[0:n]

    def cmd_read_register(self, addr):
        cfun = self.cmdGen.cmd_read_register
        buf = addressof(self.buf)
        n = cfun(byref(c_void_p(buf)), c_uint(addr))
        return self.buf.raw[0:n]

    def cmd_read_datafifo(self, val):
        cfun = self.cmdGen.cmd_read_datafifo
        buf = addressof(self.buf)
        n = cfun(byref(c_void_p(buf)), c_uint(val))
        return self.buf.raw[0:n]

    def cmd_write_memory_file(self, file_name):
        cfun = self.cmdGen.cmd_write_memory_file
        buf = addressof(self.buf)
        n = cfun(byref(c_void_p(buf)), c_char_p(file_name))
        return self.buf.raw[0:n]

if __name__ == "__main__":
    cmd = Cmd()
    ret = cmd.write_register(1, 0x5a5a)
    print [hex(ord(s)) for s in ret]
