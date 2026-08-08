#include "GzipShim.h"
#include <stdlib.h>
#include <string.h>
#include <zlib.h>

static int run_zlib(const unsigned char *input, size_t input_len, unsigned char **output, size_t *output_len, int encode) {
    if (!input || !output || !output_len) return -1;

    z_stream stream;
    memset(&stream, 0, sizeof(stream));

    int init_result;
    if (encode) {
        init_result = deflateInit2(&stream, Z_BEST_COMPRESSION, Z_DEFLATED, 16 + MAX_WBITS, 8, Z_DEFAULT_STRATEGY);
    } else {
        init_result = inflateInit2(&stream, 16 + MAX_WBITS);
    }
    if (init_result != Z_OK) return init_result;

    size_t capacity = encode ? compressBound((uLong)input_len) + 32 : input_len * 3 + 4096;
    if (capacity < 8192) capacity = 8192;
    unsigned char *buffer = (unsigned char *)malloc(capacity);
    if (!buffer) {
        if (encode) deflateEnd(&stream); else inflateEnd(&stream);
        return -2;
    }

    stream.next_in = (Bytef *)input;
    stream.avail_in = (uInt)input_len;

    int result = Z_OK;
    do {
        if (stream.total_out >= capacity) {
            capacity *= 2;
            unsigned char *next = (unsigned char *)realloc(buffer, capacity);
            if (!next) {
                free(buffer);
                if (encode) deflateEnd(&stream); else inflateEnd(&stream);
                return -3;
            }
            buffer = next;
        }

        stream.next_out = buffer + stream.total_out;
        stream.avail_out = (uInt)(capacity - stream.total_out);
        result = encode ? deflate(&stream, Z_FINISH) : inflate(&stream, Z_NO_FLUSH);
    } while (result == Z_OK);

    if (result != Z_STREAM_END) {
        free(buffer);
        if (encode) deflateEnd(&stream); else inflateEnd(&stream);
        return result;
    }

    *output_len = stream.total_out;
    *output = buffer;
    if (encode) deflateEnd(&stream); else inflateEnd(&stream);
    return Z_OK;
}

int gzip_compress(const unsigned char *input, size_t input_len, unsigned char **output, size_t *output_len) {
    return run_zlib(input, input_len, output, output_len, 1);
}

int gzip_decompress(const unsigned char *input, size_t input_len, unsigned char **output, size_t *output_len) {
    return run_zlib(input, input_len, output, output_len, 0);
}

void gzip_free(unsigned char *ptr) {
    free(ptr);
}
