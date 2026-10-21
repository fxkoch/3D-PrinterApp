#include "czip.h"
#include <zlib.h>
#include <string.h>

long czip_inflate_raw(const uint8_t *src, size_t src_len, uint8_t *dst, size_t dst_len) {
    z_stream stream;
    memset(&stream, 0, sizeof(stream));
    if (inflateInit2(&stream, -MAX_WBITS) != Z_OK) return -1;
    stream.next_in = (Bytef *)src;
    stream.avail_in = (uInt)src_len;
    stream.next_out = dst;
    stream.avail_out = (uInt)dst_len;
    int status = inflate(&stream, Z_FINISH);
    long written = (long)stream.total_out;
    inflateEnd(&stream);
    return status == Z_STREAM_END ? written : -1;
}

long czip_deflate_raw(const uint8_t *src, size_t src_len, uint8_t *dst, size_t dst_len) {
    z_stream stream;
    memset(&stream, 0, sizeof(stream));
    if (deflateInit2(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, -MAX_WBITS, 8, Z_DEFAULT_STRATEGY) != Z_OK) return -1;
    stream.next_in = (Bytef *)src;
    stream.avail_in = (uInt)src_len;
    stream.next_out = dst;
    stream.avail_out = (uInt)dst_len;
    int status = deflate(&stream, Z_FINISH);
    long written = (long)stream.total_out;
    deflateEnd(&stream);
    return status == Z_STREAM_END ? written : -1;
}

size_t czip_deflate_bound(size_t src_len) {
    return (size_t)compressBound((uLong)src_len) + 64;
}

uint32_t czip_crc32(const uint8_t *src, size_t len) {
    return (uint32_t)crc32(0L, src, (uInt)len);
}
