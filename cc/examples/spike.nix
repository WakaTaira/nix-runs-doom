# The reference C of the execution-strategy spike (M0, bench/spike) as compiler input.
# Without a preprocessor, the address macros are written as casts of integer literals
# (addresses as in bench/spike/data.nix).
''
  typedef unsigned char byte;
  typedef int fixed_t;

  fixed_t FixedMul(fixed_t a, fixed_t b) { return ((long long)a * b) >> 16; }

  void R_DrawColumn(byte *dest, const byte *src, const byte *cmap,
                    fixed_t frac, fixed_t step, int count) {
    do { *dest = cmap[src[(frac >> 16) & 127]]; dest += 320; frac += step; } while (--count);
  }

  void R_DrawSpan(byte *dest, const byte *src, const byte *cmap,
                  fixed_t xfrac, fixed_t yfrac, fixed_t xstep, fixed_t ystep, int count) {
    do {
      int spot = ((yfrac >> 10) & 4032) + ((xfrac >> 16) & 63);
      *dest++ = cmap[src[spot]];
      xfrac += xstep; yfrac += ystep;
    } while (--count);
  }

  /* params: [0]=frames, [1]=columns, [2]=spans, [3]=muls */
  void unit(const int *params) {
    for (int f = 0; f < params[0]; f++) {
      for (int x = 0; x < params[1]; x++)
        R_DrawColumn((byte *)0x00110000 + x, (byte *)0x00121000, (byte *)0x00120000,
                     x << 12, 0x8000, 200);
      for (int y = 0; y < params[2]; y++)
        R_DrawSpan((byte *)0x00110000 + y * 320 + 160, (byte *)0x00122000,
                   (byte *)0x00120000, y << 14, y << 16, 0x10000, 0x400, 160);
      unsigned s = 0;
      for (int i = 0; i < params[3]; i++) s += FixedMul(i * 7919, 0x12345 + i);
      *(unsigned *)0x00123000 += s;
    }
  }
''
