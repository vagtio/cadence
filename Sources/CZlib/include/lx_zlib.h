#ifndef LX_ZLIB_H
#define LX_ZLIB_H

#include <stddef.h>

/* Returns 0 on success, non-zero on failure. Caller owns *out (free with lx_free). */
int lx_inflate(const unsigned char *in, size_t in_len, unsigned char **out, size_t *out_len);
int lx_deflate(const unsigned char *in, size_t in_len, unsigned char **out, size_t *out_len);
void lx_free(void *p);

#endif
