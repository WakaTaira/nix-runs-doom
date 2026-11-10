# Tests for the Doom extension instructions (custom-0). Each case group is a function
# of the runner (see tests/paths.nix) returning a list of tests; add new groups to
# `groups`. Every case runs both without and with a code region.
let
  A = import ../lib/asm.nix;
  B = import ../lib/bits.nix;
  C = import ../lib/cpu.nix;
  M = import ../lib/mem.nix;
  P = import ./paths.nix;
  Spike = import ../bench/spike;
  SpikeData = import ../bench/spike/data.nix;
  Cc = import ../cc;
  inherit (builtins)
    bitAnd
    concatMap
    foldl'
    genList
    toString
    ;

  # FIXMUL: x3 = fixmul(x1, x2), with x1 = a and x2 = b given as signed or unsigned
  # integers and the expected value normalized to the unsigned 32-bit form.
  fixmulCases =
    run:
    let
      exec =
        a: b:
        run {
          mem = M.storeWord (M.storeWord M.empty 0 (A.fixmul 3 1 2)) 4 A.ebreak;
          regs = {
            "1" = B.u32 a;
            "2" = B.u32 b;
          };
          code = {
            base = 0;
            size = 8;
          };
          maxSteps = 10;
        };

      op = name: a: b: expected: {
        name = "xdoom: fixmul ${name}";
        got = C.getReg (exec a b) 3;
        expected = B.u32 expected;
      };
    in
    [
      (op "3.0 * 2.0" 196608 131072 393216)
      (op "-3.0 * 2.0" (-196608) 131072 (-393216))
      (op "-1 * 1 floors to -1" 4294967295 1 4294967295)
      (op "INT_MAX * INT_MAX" 2147483647 2147483647 4294901760) # (0x7FFFFFFF^2 >> 16) mod 2^32
    ];

  groups = [ fixmulCases ];

  # --- Execution-strategy spike (bench/spike) ---
  # These tests do not depend on the runner (the variants bring their own CPU setup),
  # so they are appended outside `bothPaths`.
  spikeParams = {
    frames = 1;
    columns = 4;
    spans = 4;
    muls = 16;
  };

  # Independent model of the reference C: every pixel and the result computed
  # directly (all intermediate values are non-negative, so >> is div).
  spikeModel =
    {
      frames,
      columns,
      spans,
      muls,
    }:
    let
      mod = a: n: a - a / n * n;
      cmap = i: mod (i * 7 + 3) 256;
      colsrc = i: mod (i * 13) 256;
      flat = i: mod (i * 31 + i / 64) 256;
      colPixel = x: r: cmap (colsrc (mod ((x * 4096 + r * 32768) / 65536) 128));
      spanPixel =
        y: k:
        cmap (
          flat (bitAnd ((y * 65536 + k * 1024) / 1024) 4032 + bitAnd ((y * 16384 + k * 65536) / 65536) 63)
        );
      pixel =
        i:
        let
          r = i / 320;
          c = i - r * 320;
        in
        if frames > 0 && c >= 160 && r < spans then
          spanPixel r (c - 160)
        else if frames > 0 && c < columns then
          colPixel c r
        else
          0;
      sum = foldl' (s: i: s + (i * 7919) * (74565 + i) / 65536) 0 (genList (i: i) muls);
    in
    {
      screen = genList pixel 64000;
      result = mod (frames * sum) 4294967296;
      inherit spanPixel;
    };

  spikeWant = spikeModel spikeParams;

  spikeCase =
    name: variant:
    let
      mem = variant.run (SpikeData.image spikeParams);
    in
    [
      {
        name = "xdoom: spike ${name} screen matches the model";
        got = SpikeData.screenBytes mem == spikeWant.screen;
        expected = true;
      }
      {
        name = "xdoom: spike ${name} result matches the model";
        got = SpikeData.result mem;
        expected = spikeWant.result;
      }
    ];

  # The draw input (cc/examples/draw.nix): file-scope variables are initialized first.
  drawVariant = {
    run =
      mem:
      let
        f = Cc.load Cc.examples.draw.src;
      in
      f.unit (f.__data.init mem) SpikeData.PARAMS;
  };

  # Draw the span of row `y` (the values `unit` puts into the variables) with the compiled
  # R_DrawSpan alone and compare its 160 pixels (screen x = 160..319) with the model.
  drawSpanRowCase =
    y:
    let
      f = Cc.load Cc.examples.draw.src;
      sym = f.__data.symbols;
      set = mem: kv: M.storeWord mem sym.${kv.name} kv.value;
      mem0 = f.init (f.__data.init (SpikeData.image spikeParams));
      mem1 = foldl' set mem0 [
        {
          name = "ds_y";
          value = y;
        }
        {
          name = "ds_x1";
          value = 160;
        }
        {
          name = "ds_x2";
          value = 319;
        }
        {
          name = "ds_xfrac";
          value = y * 16384;
        }
        {
          name = "ds_yfrac";
          value = y * 65536;
        }
        {
          name = "ds_xstep";
          value = 65536;
        }
        {
          name = "ds_ystep";
          value = 1024;
        }
        {
          name = "ds_source";
          value = SpikeData.FLAT;
        }
        {
          name = "ds_colormap";
          value = SpikeData.CMAP;
        }
      ];
      mem = f.R_DrawSpan mem1;
    in
    {
      name = "xdoom: draw R_DrawSpan row ${toString y} matches the model";
      got = genList (k: M.loadByte mem (SpikeData.SCREEN + y * 320 + 160 + k)) 160;
      expected = genList (k: spikeWant.spanPixel y k) 160;
    };

  spikeCases =
    spikeCase "rv" (import ../bench/spike/rv.nix { })
    ++ spikeCase "rvx" (import ../bench/spike/rvx.nix)
    ++ spikeCase "nix" (import ../bench/spike/nix.nix)
    ++ spikeCase "cc" {
      run = mem: (Cc.load Cc.examples.spike.src).unit mem SpikeData.PARAMS;
    }
    ++ spikeCase "draw" drawVariant
    ++ [
      (drawSpanRowCase 62)
      (drawSpanRowCase 63)
      {
        name = "xdoom: draw gate at exactly 1.25 passes";
        got = Spike.drawGate 1.25;
        expected = "DRAW GATE: pass";
      }
      {
        name = "xdoom: draw gate at 1.26 fails";
        got = Spike.drawGate 1.26;
        expected = "DRAW GATE: fail";
      }
      {
        name = "xdoom: spike verdict at exactly 2.0 is option 3";
        got = Spike.verdict 2.0;
        expected = "VERDICT: option 3";
      }
      {
        name = "xdoom: spike verdict at 1.99 is option 1";
        got = Spike.verdict 1.99;
        expected = "VERDICT: option 1";
      }
      {
        name = "xdoom: cc gate at exactly 1.25 passes";
        got = Spike.ccGate 1.25;
        expected = "CC GATE: pass";
      }
      {
        name = "xdoom: cc gate at 1.26 fails";
        got = Spike.ccGate 1.26;
        expected = "CC GATE: fail";
      }
    ];
in
P.bothPaths (run: concatMap (g: g run) groups) ++ spikeCases
