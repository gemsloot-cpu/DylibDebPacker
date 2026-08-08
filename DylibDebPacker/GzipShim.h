#ifndef GzipShim_h
#define GzipShim_h

#include <stddef.h>

int gzip_compress(const unsigned char *input, size_t input_len, unsigned char **output, size_t *output_len);
int gzip_decompress(const unsigned char *input, size_t input_len, unsigned char **output, size_t *output_len);
void gzip_free(unsigned char *ptr);

#endif
