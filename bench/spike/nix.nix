# Spike variant `nix` (option 3): the reference C of the spike translated into Nix
# functions the way a straightforward C-to-Nix compiler would, with no hand
# optimization. The translation rules are fixed:
#   - a C function becomes a Nix function taking the memory trie and its arguments
#     and returning the new memory ({ mem; ret; } when it also returns a value);
#   - locals that do not live across a loop iteration become `let` bindings;
#   - every loop (for, do/while) becomes a call of the single helper `loop`;
#   - memory goes through lib/mem.nix, 32-bit arithmetic through lib/bits.nix, and
#     values wrap modulo 2^32 only where C wraps them.
# Representation: `int` is a plain (signed) Nix integer, pointers and `unsigned`
# are unsigned 32-bit values. `long long` maps to the Nix integer directly.
let
  M = import ../../lib/mem.nix;
  B = import ../../lib/bits.nix;
  D = import ./data.nix;
  inherit (builtins)
    attrValues
    bitAnd
    div
    foldl'
    genList
    removeAttrs
    seq
    ;

  # --- Runtime support emitted by the compiler ---

  # `int << n` and `int >> n` (arithmetic, floor) for a variable shift amount n.
  # A constant shift is lowered inline instead: `x << k` to `x * 2^k` (signed
  # overflow is undefined in C, so no wrap) and `x >> k` to the floor division
  # `div (x - bitAnd x (2^k - 1)) 2^k`.
  shlInt = x: n: B.toSigned (B.shl (B.u32 x) n);
  sraInt = x: n: B.toSigned (B.sra (B.u32 x) n);

  # Shared loop driver, shaped like `run` in lib/cpu.nix. `vars` holds every
  # variable the loop carries (always including mem). Each iteration runs `body`
  # while `cond` holds; `body` may set `exit = true` to leave after the current
  # iteration (break). Iterations are folded 64 at a time, every carried variable
  # is forced after each chunk to keep thunk chains short, and the recursion is
  # per chunk.
  chunkLen = 64;
  chunkTicks = genList (_: null) chunkLen;
  forceVars = v: foldl' (acc: x: seq x acc) v (attrValues v);
  loop =
    cond: body: vars:
    let
      tick =
        v: _:
        if v.exit then
          v
        else if cond v then
          body v
        else
          v // { exit = true; };
      go =
        v:
        let
          e = forceVars (foldl' tick v chunkTicks);
        in
        if e.exit then e else go e;
    in
    removeAttrs (go (vars // { exit = false; })) [ "exit" ];

  # --- Translated functions ---

  # fixed_t FixedMul(fixed_t a, fixed_t b) { return ((long long)a * b) >> 16; }
  # The 64-bit shift floors; the conversion back to int keeps the low 32 bits.
  FixedMul =
    mem: a: b:
    let
      p = a * b;
    in
    {
      inherit mem;
      ret = B.toSigned (B.u32 (div (p - bitAnd p 65535) 65536));
    };

  # do { *dest = cmap[src[(frac >> 16) & 127]]; dest += 320; frac += step; } while (--count);
  R_DrawColumn =
    mem: dest: src: cmap: frac: step: count:
    (loop (_: true)
      (
        v:
        let
          mem' = M.storeByte v.mem v.dest (
            M.loadByte v.mem (
              B.add cmap (M.loadByte v.mem (B.add src (bitAnd (div (v.frac - bitAnd v.frac 65535) 65536) 127)))
            )
          );
          dest' = B.add v.dest 320;
          frac' = v.frac + step;
          count' = v.count - 1;
        in
        v
        // {
          mem = mem';
          dest = dest';
          frac = frac';
          count = count';
          exit = count' == 0;
        }
      )
      {
        inherit
          mem
          dest
          frac
          count
          ;
      }
    ).mem;

  # do {
  #   int spot = ((yfrac >> 10) & 4032) + ((xfrac >> 16) & 63);
  #   *dest++ = cmap[src[spot]];
  #   xfrac += xstep; yfrac += ystep;
  # } while (--count);
  R_DrawSpan =
    mem: dest: src: cmap: xfrac: yfrac: xstep: ystep: count:
    (loop (_: true)
      (
        v:
        let
          spot =
            bitAnd (div (v.yfrac - bitAnd v.yfrac 1023) 1024) 4032
            + bitAnd (div (v.xfrac - bitAnd v.xfrac 65535) 65536) 63;
          mem' = M.storeByte v.mem v.dest (M.loadByte v.mem (B.add cmap (M.loadByte v.mem (B.add src spot))));
          dest' = B.add v.dest 1;
          xfrac' = v.xfrac + xstep;
          yfrac' = v.yfrac + ystep;
          count' = v.count - 1;
        in
        v
        // {
          mem = mem';
          dest = dest';
          xfrac = xfrac';
          yfrac = yfrac';
          count = count';
          exit = count' == 0;
        }
      )
      {
        inherit
          mem
          dest
          xfrac
          yfrac
          count
          ;
      }
    ).mem;

  # params[k] for `const int *params`.
  paramAt =
    mem: params: k:
    B.toSigned (M.loadWord mem (B.add params (4 * k)));

  # void unit(const int *params) { for (f ...) { columns; spans; muls; *RESULT += s; } }
  unit =
    mem: params:
    (loop (v: v.f < paramAt v.mem params 0)
      (
        v:
        let
          # for (int x = 0; x < params[1]; x++)
          #   R_DrawColumn(SCREEN + x, COLSRC, CMAP, x << 12, 0x8000, 200);
          afterColumns =
            (loop (w: w.x < paramAt w.mem params 1)
              (
                w:
                w
                // {
                  mem = R_DrawColumn w.mem (B.add D.SCREEN w.x) D.COLSRC D.CMAP (w.x * 4096) 32768 200;
                  x = w.x + 1;
                }
              )
              {
                inherit (v) mem;
                x = 0;
              }
            ).mem;

          # for (int y = 0; y < params[2]; y++)
          #   R_DrawSpan(SCREEN + y * 320 + 160, FLAT, CMAP, y << 14, y << 16, 0x10000, 0x400, 160);
          afterSpans =
            (loop (w: w.y < paramAt w.mem params 2)
              (
                w:
                w
                // {
                  mem = R_DrawSpan w.mem (B.add (B.add D.SCREEN (w.y * 320)) 160) D.FLAT D.CMAP (w.y * 16384) (
                    w.y * 65536
                  ) 65536 1024 160;
                  y = w.y + 1;
                }
              )
              {
                mem = afterColumns;
                y = 0;
              }
            ).mem;

          # unsigned s = 0;
          # for (int i = 0; i < params[3]; i++) s += FixedMul(i * 7919, 0x12345 + i);
          afterMuls =
            loop (w: w.i < paramAt w.mem params 3)
              (
                w:
                let
                  r = FixedMul w.mem (w.i * 7919) (74565 + w.i);
                in
                w
                // {
                  inherit (r) mem;
                  s = B.add w.s r.ret;
                  i = w.i + 1;
                }
              )
              {
                mem = afterSpans;
                i = 0;
                s = 0;
              };

          # *RESULT += s;
          afterResult = M.storeWord afterMuls.mem D.RESULT (
            B.add (M.loadWord afterMuls.mem D.RESULT) afterMuls.s
          );
        in
        v
        // {
          mem = afterResult;
          f = v.f + 1;
        }
      )
      {
        inherit mem;
        f = 0;
      }
    ).mem;

  # Run unit(PARAMS) on an image built by data.nix.
  run = mem: unit mem D.PARAMS;
in
{
  inherit
    loop
    FixedMul
    R_DrawColumn
    R_DrawSpan
    unit
    run
    ;
}
