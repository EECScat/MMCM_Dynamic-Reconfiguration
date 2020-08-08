/*
 * Copyright (c) 2013
 *
 *     Yuan Mei
 *
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 1. Redistributions of source code must retain the above copyright
 * notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 * notice, this list of conditions and the following disclaimer in the
 * documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY THE AUTHOR AND CONTRIBUTORS ``AS IS'' AND
 * ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
 * ARE DISCLAIMED. IN NO EVENT SHALL THE AUTHOR OR CONTRIBUTORS BE LIABLE
 * FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
 * DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
 * OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
 * HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
 * LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
 * OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
 * SUCH DAMAGE.
 */

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <arpa/inet.h>

#include "common.h"
#include "command.h"

char *conv16network_endian(uint16_t *buf, size_t n)
{
    size_t i;
    for(i=0; i<n; i++) {
        buf[i] = htons(buf[i]);
    }
    return (char*)buf;
}

char *conv32network_endian(uint32_t *buf, size_t n)
{
    size_t i;
    for(i=0; i<n; i++) {
        buf[i] = htonl(buf[i]);
    }
    return (char*)buf;
}

size_t cmd_read_status(uint32_t **bufio, uint32_t addr)
{
    uint32_t *buf;
    buf = *bufio;
    if(buf == NULL) {
        buf = (uint32_t*)calloc(1, sizeof(uint32_t));
        if(buf == NULL)
            return -1;
        *bufio = buf;
    }
    buf[0] = (0xffff0000 & ((0x8000 + addr) << 16));
    conv32network_endian(buf, 1);
    return 1*sizeof(uint32_t);
}

size_t cmd_send_pulse(uint32_t **bufio, uint32_t mask)
{
    uint32_t *buf;
    buf = *bufio;
    if(buf == NULL) {
        buf = (uint32_t*)calloc(1, sizeof(uint32_t));
        if(buf == NULL)
            return -1;
        *bufio = buf;
    }
    buf[0] = 0x000b0000 | (0x0000ffff & mask);
    conv32network_endian(buf, 1);
    return 1*sizeof(uint32_t);
}

size_t cmd_write_memory(uint32_t **bufio, uint32_t addr, uint32_t *aval, size_t nval)
{
    size_t idx, i;
    uint32_t *buf;

    buf = *bufio;
    if(buf == NULL) {
        buf = (uint32_t*)calloc(nval*2+2, sizeof(uint32_t));
        if(buf == NULL)
            return -1;
        *bufio = buf;
    }

    idx = 0;
    buf[idx++] = 0x00110000 | (0x0000ffff & addr);          // address LSB
    buf[idx++] = 0x00120000 | (0x0000ffff & (addr>>16));    // address MSB
    buf[idx++] = 0x00130000 | (0x0000ffff & (*aval));       // data LSB
    buf[idx++] = 0x00140000 | (0x0000ffff & ((*aval)>>16)); // data MSB
    for(i=1; i<nval; i++) {                                 // more data
        buf[idx++] = 0x00130000 | (0x0000ffff & aval[i]);
        buf[idx++] = 0x00140000 | (0x0000ffff & (aval[i]>>16));
    }
    conv32network_endian(buf, nval*2+2);
    return (nval*2+2)*sizeof(uint32_t);
}

size_t cmd_read_memory(uint32_t **bufio, uint32_t addr, uint32_t n)
{
    size_t idx;
    uint32_t *buf;

    buf = *bufio;
    if(buf == NULL) {
        buf = (uint32_t*)calloc(4, sizeof(uint32_t));
        if(buf == NULL)
            return -1;
        *bufio = buf;
    }

    idx = 0;
    buf[idx++] = 0x00110000 | (0x0000ffff & addr);       // address LSB
    buf[idx++] = 0x00120000 | (0x0000ffff & (addr>>16)); // address MSB
    buf[idx++] = 0x00100000 | (0x0000ffff & n);          // n words to read
    buf[idx++] = 0x80140000;                             // initialize read

    conv32network_endian(buf, 4);
    return 4*sizeof(uint32_t);
}

size_t cmd_write_register(uint32_t **bufio, uint32_t addr, uint32_t val)
{
    uint32_t *buf;
    buf = *bufio;
    if(buf == NULL) {
        buf = (uint32_t*)calloc(1, sizeof(uint32_t));
        if(buf == NULL)
            return -1;
        *bufio = buf;
    }
    buf[0] = (0xffff0000 & ((0x0020 + addr) << 16)) | (0x0000ffff & val);
    conv32network_endian(buf, 1);
    return 1*sizeof(uint32_t);
}

size_t cmd_read_register(uint32_t **bufio, uint32_t addr)
{
    uint32_t *buf;
    buf = *bufio;
    if(buf == NULL) {
        buf = (uint32_t*)calloc(1, sizeof(uint32_t));
        if(buf == NULL)
            return -1;
        *bufio = buf;
    }
    buf[0] = (0xffff0000 & ((0x8020 + addr) << 16));
    conv32network_endian(buf, 1);
    return 1*sizeof(uint32_t);
}

size_t cmd_read_datafifo(uint32_t **bufio, uint32_t n)
{
    uint32_t *buf;
    buf = *bufio;
    if(buf == NULL) {
        buf = (uint32_t*)calloc(2, sizeof(uint32_t));
        if(buf == NULL)
            return -1;
        *bufio = buf;
    }
    buf[0] = (0xffff0000 & (0x001a << 16)) | (0x0000ffff & (n>>16));
    buf[1] = (0xffff0000 & (0x0019 << 16)) | (0x0000ffff & n);
    conv32network_endian(buf, 2);
    return 2*sizeof(uint32_t);
}

size_t cmd_write_memory_file(uint32_t **bufio, char * file_name)
{
    size_t idx, i;
    uint32_t *buf;
    size_t n;
    buf = *bufio;
    if(buf == NULL) {
        buf = (uint32_t*)calloc(5000, sizeof(uint32_t));
        if(buf == NULL)
            return -1;
        *bufio = buf;
    }

    FILE *fp;
    char buffer[15];
    fp = fopen(file_name,"r");
    fseek(fp,SEEK_SET,0);
    size_t word_counter=0;
    uint32_t * jtag_buf;
    while(1 == fread(buffer,11,1,fp)){word_counter++;}
    jtag_buf = (uint32_t*)calloc(word_counter, sizeof(uint32_t));
    fseek(fp,SEEK_SET,0);
    uint32_t wd;
    int i_con=0;
    while(1 == fread(buffer,11,1,fp))
    {
      sscanf(buffer,"%x",&wd);
      jtag_buf[i_con] = wd;
      i_con++;
    }
    n = cmd_write_memory(&buf, 0, jtag_buf, word_counter);
    free(jtag_buf);
    fclose(fp);
    return n;
}

void wdtest(int *musk)
{
    printf("hello!! ");
    for(int l=0; l<928; l++)
      for(int m=0; m<960; m++)
      {
        if(musk[l*960+m] != 0)
          // maps[l*960+m] = maps_temp[l*960+m];
          // {maps[l*960+m] = 1;
            printf("%d,%d  ",l,m);
          // }
        // else
          // {maps[l*960+m] = 0;}
      }
}

void data_cal(unsigned char *databuf, unsigned short *maps, unsigned short *maps_temp,unsigned int *i2c_data, int *musk,int *fcounter, int framadd)
{
    unsigned char *buf;
    buf = databuf;
    int datanum = 20000;
    unsigned char w4 = 0;
    unsigned char w3 = 0;
    unsigned char w2 = 0;
    unsigned char w1 = 0;
    unsigned char  w = 0;
    unsigned short pdata_pre2 = 0;
    unsigned short pdata_pre1 = 0;
    int counter = 0;
    int odd = 0;
    unsigned short header = 0xaaaa;
    unsigned short tailer = 0x5678;
    int row = 0;
    int column = 0;
    int code = 0;
    int hsign = 0;
    int tsign = 0;
    int i = 0;
    int ch = 0;
    unsigned short pdata = 0x0000;
    char i2c_data_temp[8];

    for(i = 0; i<datanum*4; i++)
    {
      w  = buf[i];
      w4 = w3;
      w3 = w2;
      w2 = w1;
      w1 = w;
      if (counter != 0)
      {
        if (odd==1)
        {
            pdata = w;
            odd = 0;
        }
        else
        {
            pdata = pdata + (w << 8);
            odd = 1;
            pdata_pre2 = pdata_pre1;
            pdata_pre1 = pdata;
            counter += 1;
            if (pdata == tailer)
            {
                if (tsign == 0)
                  tsign = 1;
                else
                {
                    counter = 0;
                    tsign = 0;
                    *fcounter +=1;

                    // for(int s = 0; s < 8; s++)
                    //   {i2c_data[s] = i2c_data_temp[s];
                    //   }
                    i2c_data[0] = (((i2c_data_temp[1]&0x0f)<<16) + ((i2c_data_temp[2])<<8) + i2c_data_temp[3]); //frame_counter
                    i2c_data[1] = (i2c_data_temp[1] & 0x30) >> 4; //latchup_status
                    i2c_data[2] = ( (i2c_data_temp[4]<<2) + (i2c_data_temp[5] >> 6))>>2; //temperature
                    ch = ( i2c_data_temp[6] & 0x0c ) >> 2; //CH identifier
                    i2c_data[7] = ch;
                    if(ch == 0){i2c_data[3] = ((i2c_data_temp[6] & 0x03) << 8) + i2c_data_temp[7];} // CH 1 : Chip_VDD
                    else if(ch == 1){i2c_data[4] = ((i2c_data_temp[6] & 0x03) << 8) + i2c_data_temp[7];} // CH 2 : Mimosa_VDD
                    else if(ch == 2){i2c_data[5] = ((i2c_data_temp[6] & 0x03) << 8) + i2c_data_temp[7];} // CH 3 : Chip_I
                    else if(ch == 3)
                    {
                      i2c_data[6] = ((i2c_data_temp[6] & 0x03) << 8) + i2c_data_temp[7];
                      if(i2c_data[6] > 68)//53:300mA ; 68:400mA ; 84:500mA
                      {
                         printf("%d ",i2c_data[6]);
                      }
                    } // CH 4 : Mimosa_I

                    if (*fcounter == framadd)
                    {
                        *fcounter = 0;
                        for(int l=0; l<928; l++)
                          for(int m=0; m<960; m++)
                          {
                            // if(maps_temp[l*960+m] < 4998)
                              maps[l*960+m] = maps_temp[l*960+m];
                            // else
                              // maps[l*960+m] = 0;
                            maps_temp[l*960+m] = 0;
                          }
                    }
                }
            }
            else
            {
                tsign = 0;
                // if (counter > 2)   // -- without counter
                if (counter > 6)  // -- withcounter two
                {
                  if ((pdata_pre2 & 0x1000) != 0)
                      row = (pdata_pre2 >>2) & 0x03ff;
                  else
                  {
                      column = (pdata_pre2 >>2) & 0x03ff;
                      code = pdata_pre2 & 0x0003;
                      if(((column+code)<960)&(row<928))
                      {
                          for (int j = 0; j<(code+1); j++)
                            maps_temp[row*960+column+j] += 1;
                      }
                  }
                }
            }
        }
      }
      else
      {
        odd = 1;
        if ((w1==0xaa)&(w2==0xaa)&(w3==0xaa)&(w4==0xaa))
          counter = 1;
          for(int m = 0; m < 8; m++)
           if((i+m)<datanum*4)
            {i2c_data_temp[m] = buf[i + m + 1];
            }
      }
    }
    return 1;
}
