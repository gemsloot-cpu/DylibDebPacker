#ifndef Bzip2Shim_h
#define Bzip2Shim_h

#include <stddef.h>

int bzip2_decompress(const unsigned char *input, size_t input_len, unsigned char **output, size_t *output_len);
void bzip2_free(unsigned char *ptr);

#endif
