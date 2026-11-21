#include "include/lx_zlib.h"
#include <stdlib.h>
#include <string.h>
#include <zlib.h>

/* Grow-as-needed single-shot helper; windowBits 15+32 auto-detects gzip/zlib headers. */
static int run(int mode, const unsigned char *in, size_t in_len, unsigned char **out, size_t *out_len) {
  z_stream s;
  memset(&s, 0, sizeof(s));
  int rc = mode == 0 ? inflateInit2(&s, 15 + 32) : deflateInit(&s, Z_DEFAULT_COMPRESSION);
  if (rc != Z_OK) return rc;

  size_t cap = in_len * 3 + 1024;
  unsigned char *buf = malloc(cap);
  if (!buf) { mode == 0 ? inflateEnd(&s) : deflateEnd(&s); return Z_MEM_ERROR; }

  s.next_in = (Bytef *)in;
  s.avail_in = (uInt)in_len;

  size_t total = 0;
  for (;;) {
    s.next_out = buf + total;
    s.avail_out = (uInt)(cap - total);
    rc = mode == 0 ? inflate(&s, Z_NO_FLUSH) : deflate(&s, Z_FINISH);
    total = cap - s.avail_out;
    if (rc == Z_STREAM_END) break;
    if (rc != Z_OK && rc != Z_BUF_ERROR) { free(buf); mode == 0 ? inflateEnd(&s) : deflateEnd(&s); return rc; }
    if (total == cap) {
      cap *= 2;
      unsigned char *grown = realloc(buf, cap);
      if (!grown) { free(buf); mode == 0 ? inflateEnd(&s) : deflateEnd(&s); return Z_MEM_ERROR; }
      buf = grown;
    }
  }
  mode == 0 ? inflateEnd(&s) : deflateEnd(&s);
  *out = buf;
  *out_len = total;
  return 0;
}

int lx_inflate(const unsigned char *in, size_t in_len, unsigned char **out, size_t *out_len) {
  return run(0, in, in_len, out, out_len);
}

int lx_deflate(const unsigned char *in, size_t in_len, unsigned char **out, size_t *out_len) {
  return run(1, in, in_len, out, out_len);
}

void lx_free(void *p) { free(p); }
