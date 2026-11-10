# The second compiler input: the drawing routines of the spike workload written in the
# shape Doom uses. They take no arguments and read file-scope variables, and
# R_DrawColumn returns early. R_DrawSpan keeps both texture positions packed into one
# unsigned. Without a preprocessor, the address macros are written as casts of integer
# literals (addresses as in bench/spike/data.nix). The screen and the result word are
# the same as those of cc/examples/spike.nix for the same parameters.
''
  typedef unsigned char byte;
  typedef int fixed_t;

  byte *ylookup[200];
  int columnofs[320];
  int centery;

  int dc_x;
  int dc_yl;
  int dc_yh;
  fixed_t dc_iscale;
  fixed_t dc_texturemid;
  byte *dc_source;
  byte *dc_colormap;

  int ds_y;
  int ds_x1;
  int ds_x2;
  fixed_t ds_xfrac;
  fixed_t ds_yfrac;
  fixed_t ds_xstep;
  fixed_t ds_ystep;
  byte *ds_source;
  byte *ds_colormap;

  fixed_t FixedMul(fixed_t a, fixed_t b) { return ((long long)a * b) >> 16; }

  void R_DrawColumn(void) {
    int count = dc_yh - dc_yl;
    if (count < 0) return;
    byte *dest = ylookup[dc_yl] + columnofs[dc_x];
    fixed_t fracstep = dc_iscale;
    fixed_t frac = dc_texturemid + (dc_yl - centery) * fracstep;
    do {
      *dest = dc_colormap[dc_source[(frac >> 16) & 127]];
      dest += 320;
      frac += fracstep;
    } while (count--);
  }

  void R_DrawSpan(void) {
    unsigned position = ((ds_xfrac << 10) & 0xffff0000) | ((ds_yfrac >> 6) & 0x0000ffff);
    unsigned step = ((ds_xstep << 10) & 0xffff0000) | ((ds_ystep >> 6) & 0x0000ffff);
    byte *dest = ylookup[ds_y] + columnofs[ds_x1];
    int count = ds_x2 - ds_x1;
    unsigned xtemp;
    unsigned ytemp;
    unsigned spot;
    do {
      ytemp = (position >> 4) & 0x0fc0;
      xtemp = position >> 26;
      spot = xtemp | ytemp;
      *dest++ = ds_colormap[ds_source[spot]];
      position += step;
    } while (count--);
  }

  void init(void) {
    for (int i = 0; i < 200; i++) ylookup[i] = (byte *)0x00110000 + i * 320;
    for (int i = 0; i < 320; i++) columnofs[i] = i;
    centery = 100;
  }

  /* params: [0]=frames, [1]=columns, [2]=spans, [3]=muls */
  void unit(const int *params) {
    init();
    for (int f = 0; f < params[0]; f++) {
      for (int x = 0; x < params[1]; x++) {
        dc_x = x;
        dc_yl = 0;
        dc_yh = 199;
        dc_iscale = 0x8000;
        dc_texturemid = (x << 12) + 100 * 0x8000;
        dc_source = (byte *)0x00121000;
        dc_colormap = (byte *)0x00120000;
        R_DrawColumn();
      }
      for (int y = 0; y < params[2]; y++) {
        ds_y = y;
        ds_x1 = 160;
        ds_x2 = 319;
        ds_xfrac = y << 14;
        ds_yfrac = y << 16;
        ds_xstep = 0x10000;
        ds_ystep = 0x400;
        ds_source = (byte *)0x00122000;
        ds_colormap = (byte *)0x00120000;
        R_DrawSpan();
      }
      unsigned s = 0;
      for (int i = 0; i < params[3]; i++) s += FixedMul(i * 7919, 0x12345 + i);
      *(unsigned *)0x00123000 += s;
    }
  }
''
