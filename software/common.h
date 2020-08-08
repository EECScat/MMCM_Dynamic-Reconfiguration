#ifndef __COMMON_H__
#define __COMMON_H__

#define HDF5IO(name) hdf5io_ ## name

#define SCOPE_NCH 8
#define SCOPE_MEM_LENGTH_MAX 67108864 /* 1GiB memory, (16-bit X 8-ch) per point */
#define SCOPE_DATA_TYPE int16_t
#define SCOPE_DATA_HDF5_TYPE H5T_NATIVE_INT16

struct waveform_attribute 
{
    unsigned int chMask;
    size_t nPt;     /* number of points in each event */
    size_t nFrames; /* number of Fast Frames in each event, 0 means off */
    double dt;
    double t0;
    double ymult[SCOPE_NCH];
    double yoff[SCOPE_NCH];
    double yzero[SCOPE_NCH];
};

/* utilities */
#define bitsof(x) (8*sizeof(x))

#ifdef DEBUG
  #define debug_printf(fmt, ...) do { fprintf(stderr, fmt, ##__VA_ARGS__); fflush(stderr); \
                                    } while (0)
#else
  #define debug_printf(...) ((void)0)
#endif
#define error_printf(fmt, ...) do { fprintf(stderr, fmt, ##__VA_ARGS__); fflush(stderr); \
                                  } while(0)

#define MIN(x,y) (((x)>(y))?(y):(x))
#define MAX(x,y) (((x)<(y))?(y):(x))

#ifndef strlcpy
#define strlcpy(a, b, c) do {                   \
        strncpy(a, b, (c)-1);                   \
        (a)[(c)-1] = '\0';                      \
    } while (0)
#endif

char *conv16network_endian(uint16_t *buf, size_t n);
char *conv32network_endian(uint32_t *buf, size_t n);

#endif /* __COMMON_H__ */
