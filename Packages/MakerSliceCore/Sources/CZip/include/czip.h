// Thin wrapper over zlib so the Swift ZIP reader works on iOS and Linux alike.
#ifndef CZIP_H
#define CZIP_H

#include <stdint.h>
#include <stddef.h>

/// Inflates a raw DEFLATE stream (as stored in ZIP entries).
/// Returns the number of bytes written, or -1 on error.
long czip_inflate_raw(const uint8_t *src, size_t src_len, uint8_t *dst, size_t dst_len);

/// Deflates `src` into a raw DEFLATE stream. Returns bytes written or -1.
long czip_deflate_raw(const uint8_t *src, size_t src_len, uint8_t *dst, size_t dst_len);

/// Upper bound of the deflated size for `src_len` input bytes.
size_t czip_deflate_bound(size_t src_len);

uint32_t czip_crc32(const uint8_t *src, size_t len);

#endif
