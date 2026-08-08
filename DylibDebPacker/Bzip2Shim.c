#include "Bzip2Shim.h"
#include <bzlib.h>
#include <stdlib.h>

int bzip2_decompress(const unsigned char *input, size_t input_len, unsigned char **output, size_t *output_len) {
    if (!input || !output || !output_len || input_len > 0xFFFFFFFFu) return -1;

    unsigned int capacity = (unsigned int)(input_len * 5 + 1024 * 1024);
    if (capacity < 1024 * 1024) capacity = 1024 * 1024;

    for (int attempt = 0; attempt < 8; attempt++) {
        unsigned char *buffer = (unsigned char *)malloc(capacity);
        if (!buffer) return -2;

        unsigned int decompressedLen = capacity;
        int result = BZ2_bzBuffToBuffDecompress(
            (char *)buffer,
            &decompressedLen,
            (char *)input,
            (unsigned int)input_len,
            0,
            0
        );

        if (result == BZ_OK) {
            *output = buffer;
            *output_len = decompressedLen;
            return 0;
        }

        free(buffer);
        if (result != BZ_OUTBUFF_FULL) return result;
        capacity *= 2;
    }
    return -3;
}

void bzip2_free(unsigned char *ptr) {
    free(ptr);
}
