#ifndef __COMMAND_H__
#define __COMMAND_H__

size_t cmd_read_status(uint32_t **bufio, uint32_t addr);
size_t cmd_send_pulse(uint32_t **bufio, uint32_t mask);
size_t cmd_write_memory(uint32_t **bufio, uint32_t addr, uint32_t *aval, size_t nval);
size_t cmd_read_memory(uint32_t **bufio, uint32_t addr, uint32_t n);
size_t cmd_write_register(uint32_t **bufio, uint32_t addr, uint32_t val);
size_t cmd_read_register(uint32_t **bufio, uint32_t addr);
size_t cmd_read_datafifo(uint32_t **bufio, uint32_t n);
size_t cmd_write_memory_file(uint32_t **bufio, char * file_name);

#endif /* __COMMAND_H__ */
