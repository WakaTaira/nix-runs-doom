# Tests of the Doom platform layer: key decoding (doom/keys.nix), variable-size rendering
# (doom/render.nix), DG_GetKey (scaffold/platform.nix), the driver (doom/run.nix) on small
# guests written in C and linked with cc.linkSources, and exitText (cc/host.nix). No WAD
# and no Doom source are used. Expected values are worked out by hand from the rules at
# the top of each file; key numbers follow doomkeys.h (up 0xad = 173, down 0xaf = 175,
# right 0xae = 174, left 0xac = 172, use 0xa2 = 162, fire 0xa3 = 163).
let
  K = import ../doom/keys.nix;
  R = import ../doom/render.nix;
  Pic = import ../doom/picture.nix;
  Scaffold = import ../scaffold/render.nix;
  Cc = import ../cc;
  M = import ../lib/mem.nix;
  P = import ../scaffold/platform.nix {
    screenBufferAddr = 0;
    colorsAddr = 0;
  };
  inherit (builtins)
    bitAnd
    concatStringsSep
    elemAt
    foldl'
    fromJSON
    genList
    head
    length
    split
    stringLength
    substring
    ;

  t = name: got: expected: { inherit name got expected; };

  esc = fromJSON ''"\u001b"'';
  del = fromJSON ''"\u007f"'';
  ctl = n: fromJSON ''"\u000${toString n}"'';

  bytesOf = s: genList (i: K.ord (substring i 1 s)) (stringLength s);
  keysOf = s: (K.decode (bytesOf s)).keys;
  restOf = s: (K.decode (bytesOf s)).rest;

  # The events and states of successive polls over the given texts.
  pollAll =
    texts:
    (foldl'
      (
        acc: text:
        let
          r = K.poll acc.state text;
        in
        {
          state = r.state;
          out = acc.out ++ [ r ];
        }
      )
      {
        state = initial;
        out = [ ];
      }
      texts
    ).out;
  initial = {
    consumed = 0;
    stalled = 0;
    held = [ ];
  };
  press = key: {
    pressed = 1;
    inherit key;
  };
  release = key: {
    pressed = 0;
    inherit key;
  };
  eventsOf = texts: map (r: r.events) (pollAll texts);
  stateAfter = texts: (elemAt (pollAll texts) (length texts - 1)).state;

  # Long texts, which overflowed the evaluation stack of a recursive decoder: 200,000
  # single bytes (a, b, c, a, ...), ESC [ A repeated and cut to 200,000 bytes (66,666
  # arrows and a cut-off ESC [), and one CSI with 100,000 parameter bytes.
  repeat = s: n: concatStringsSep "" (genList (_: s) n);
  longPlain = concatStringsSep "" (genList (i: elemAt [ "a" "b" "c" ] (i - (i / 3) * 3)) 200000);
  longArrows = substring 0 200000 (repeat "${esc}[A" 66667);
  longParams = "${esc}[${repeat "1" 100000}Ab";

  # An artificial screen: pixel (x, y) has palette index (x + 2y) & 255, and palette entry
  # i is { r = i; g = 2i & 255; b = 3i & 255; }.
  screen = genList (i: bitAnd (i - (i / 320) * 320 + 2 * (i / 320)) 255) 64000;
  palette = genList (i: {
    r = i;
    g = bitAnd (2 * i) 255;
    b = bitAnd (3 * i) 255;
  }) 256;

  image80 = R.render {
    inherit screen palette;
    cols = 80;
    rows = 25;
  };
  sha = size: builtins.hashString "sha256" (R.render ({ inherit screen palette; } // size));
  lineCount = s: (length (split "\n" s) - 1) / 2;
  firstCell = "${esc}[38;2;4;9;13m${esc}[48;2;12;25;37m▀";

  # The artificial screen in memory at 0x200fd: not a multiple of 4 and three bytes before
  # a leaf boundary, so that rows start inside words and cross leaves. alignedMem holds
  # it at 0x20000.
  screenAddr = 131325;
  screenMem = M.storeRun M.empty screenAddr 64000 screen;
  alignedMem = M.storeRun M.empty 131072 64000 screen;
  fullRect = {
    x = 0;
    y = 0;
    width = 320;
    height = 200;
  };
  windowRect = {
    x = 80;
    y = 44;
    width = 160;
    height = 80;
  };
  memImage =
    rect: cols: rows:
    R.renderMem (
      {
        mem = screenMem;
        inherit
          screenAddr
          palette
          cols
          rows
          ;
      }
      // rect
    );
  memSha =
    rect: cols: rows:
    builtins.hashString "sha256" (memImage rect cols rows);

  # A cell and a line of the picture from the colors "r;g;b" of its two halves.
  cellOf = upper: lower: "${esc}[38;2;${upper}m${esc}[48;2;${lower}m▀";
  lineOf = cells: concatStringsSep "" cells + "${esc}[0m\n";

  # The color "r;g;b" of palette index i of the artificial palette.
  colorOf = i: "${toString i};${toString (bitAnd (2 * i) 255)};${toString (bitAnd (3 * i) 255)}";

  # The average color "r;g;b" of the box x0 <= x < x1, y0 <= y < y1 of the artificial
  # screen, summed straight from the list (the reference for the averaged pictures).
  boxAverage =
    x0: x1: y0: y1:
    let
      pixels = builtins.concatLists (
        genList (j: genList (i: elemAt palette (elemAt screen ((y0 + j) * 320 + x0 + i))) (x1 - x0)) (
          y1 - y0
        )
      );
      n = length pixels;
      avg = c: toString ((foldl' (a: p: a + p.${c}) 0 pixels) / n);
    in
    "${avg "r"};${avg "g"};${avg "b"}";

  # Doom's variables of doom/picture.nix at made-up addresses, and frame records over the
  # artificial screen with the variables set to the values in vars (missing ones are 0).
  picSymbols = {
    gamestate = 4096;
    gametic = 4100;
    automapactive = 4104;
    menuactive = 4108;
    viewwindowx = 4112;
    viewwindowy = 4116;
    scaledviewwidth = 4120;
    viewheight = 4124;
  };
  picFrame = vars: {
    mem = foldl' (m: n: M.storeWord m picSymbols.${n} vars.${n}) screenMem (builtins.attrNames vars);
    inherit screenAddr palette;
  };
  # A level on screen with the 160x80 window of screen size 5.
  levelVars = {
    gametic = 5;
    viewwindowx = 80;
    viewwindowy = 44;
    scaledviewwidth = 160;
    viewheight = 80;
  };
  picOf =
    windowed: vars:
    Pic.picture {
      symbols = picSymbols;
      inherit windowed;
      cols = 160;
      rows = 50;
    } (picFrame vars);
  barRect = {
    x = 0;
    y = 168;
    width = 320;
    height = 32;
  };
  fullImage = memImage fullRect 160 50;

  # The 160x80 window drawn 1:1 as 160x40 cells, worked out from the artificial screen:
  # cell (c, r) shows pixels (80 + c, 44 + 2r) and (80 + c, 45 + 2r).
  windowExpected = concatStringsSep "" (
    genList (
      r:
      lineOf (
        genList (
          c:
          cellOf (colorOf (bitAnd (80 + c + 2 * (44 + 2 * r)) 255)) (
            colorOf (bitAnd (80 + c + 2 * (45 + 2 * r)) 255)
          )
        ) 160
      )
    ) 40
  );

  # DG_GetKey of the platform layer over a memory whose words at 64 and 68 are all ones,
  # so that the word write of pressed and the byte write of key can be told apart.
  getKey = P.impls.DG_GetKey;
  keyArgs = [
    64
    68
  ];
  keyMem = M.storeWord (M.storeWord M.empty 64 4294967295) 68 4294967295;
  noKey = getKey {
    mem = keyMem;
    keys = [ ];
  } keyArgs;
  key1 = getKey {
    mem = keyMem;
    keys = [
      (press 173)
      (release 97)
    ];
  } keyArgs;
  key2 = getKey key1.world keyArgs;
  key3 = getKey key2.world keyArgs;
  keyWritten = r: [
    (M.loadWord r.world.mem 64)
    (M.loadByte r.world.mem 68)
    (M.loadByte r.world.mem 69)
  ];

  # A guest in the shape of doomgeneric: Create prints its arguments and draws the
  # argument count; each tick prints one letter (a for tick 1, ...) and draws the key
  # events it took, taking them as i_input.c does: until none is left or after the first
  # release. Screen byte 0 is the count of events, then pressed and key of each.
  guest = Cc.linkSources {
    units = [
      {
        name = "guest";
        src = ''
          int DG_GetKey(int *pressed, unsigned char *key);
          void DG_DrawFrame(void);
          int puts(const char *s);
          int putchar(int c);
          unsigned char *DG_ScreenBuffer;
          unsigned colors[256];
          unsigned char screen[64000];
          int ticks;
          void doomgeneric_Create(int argc, char **argv) {
            int i;
            for (i = 0; i < argc; i++) puts(argv[i]);
            DG_ScreenBuffer = screen;
            screen[0] = argc;
            DG_DrawFrame();
          }
          void doomgeneric_Tick(void) {
            int pressed;
            unsigned char key;
            int n = 0;
            ticks++;
            putchar(96 + ticks);
            putchar(10);
            while (DG_GetKey(&pressed, &key)) {
              screen[1 + 2 * n] = pressed;
              screen[2 + 2 * n] = key;
              n++;
              if (!pressed) break;
            }
            screen[0] = n;
            DG_DrawFrame();
          }
          void bye(void) { puts("bye"); }
        '';
      }
    ];
  };

  # The driver over the guest with the key texts of ticks 1, 2, ... (null: no input);
  # acc lists per call the tick, the output and the first 7 screen bytes of each frame.
  runGuest =
    args: texts:
    import ../doom/run.nix {
      linked = guest;
      inherit args;
      ticks = length texts;
      readKeys = tick: elemAt texts (tick - 1);
      onTick =
        info: acc:
        acc
        ++ [
          {
            inherit (info) tick out;
            frames = map (f: genList (elemAt f.screen) 7) info.frames;
          }
        ];
      init = [ ];
    };
  guestArgs = [
    "doom"
    "-x"
    "foo"
  ];
  keyRun = runGuest guestArgs [
    "a"
    "ab"
    "ab"
    null
    "ab${esc}[A"
  ];

  # The pending key events after each of 1 .. n ticks, for texts that hold two keys for
  # three ticks and then release both.
  heldTexts = [
    "ab"
    "abab"
    "ababab"
    "ababab"
    "ababab"
    "ababab"
  ];
  pendingAfter = n: length (runGuest [ "doom" ] (genList (elemAt heldTexts) n)).mem.host.keys;

  # A guest that takes key events only at odd ticks (1, 3, ...), as doomgeneric does under
  # the virtual clock, until none is left or after the first release, and keeps the state
  # of each key as gamekeydown does. Each tick draws one frame: screen byte 0 is the state
  # of key a (97), byte 1 the count of events taken, then pressed and key of each.
  oddGuest = Cc.linkSources {
    units = [
      {
        name = "odd";
        src = ''
          int DG_GetKey(int *pressed, unsigned char *key);
          void DG_DrawFrame(void);
          unsigned char *DG_ScreenBuffer;
          unsigned colors[256];
          unsigned char screen[64000];
          unsigned char down[256];
          int ticks;
          void doomgeneric_Create(int argc, char **argv) { DG_ScreenBuffer = screen; }
          void doomgeneric_Tick(void) {
            int pressed;
            unsigned char key;
            int n = 0;
            ticks++;
            if (ticks % 2 == 1) {
              while (DG_GetKey(&pressed, &key)) {
                down[key] = pressed;
                screen[2 + 2 * n] = pressed;
                screen[3 + 2 * n] = key;
                n++;
                if (!pressed) break;
              }
            }
            screen[0] = down[97];
            screen[1] = n;
            DG_DrawFrame();
          }
        '';
      }
    ];
  };

  # A guest with both buffers of doomgeneric: Create points DG_ScreenBuffer at out and
  # I_VideoBuffer at video. Every frame writes its number to byte 0 and its number + 100 to
  # byte 63999 of video, then copies video to DG_ScreenBuffer row by row, as I_FinishUpdate
  # does, and draws.
  videoUnit = {
    name = "video";
    src = ''
      void *memcpy(void *dst, const void *src, unsigned int n);
      void DG_DrawFrame(void);
      unsigned char *DG_ScreenBuffer;
      unsigned char *I_VideoBuffer;
      unsigned colors[256];
      unsigned char out[64000];
      unsigned char video[64000];
      int frames;
      void finish(void) {
        int y;
        frames++;
        I_VideoBuffer[0] = frames;
        I_VideoBuffer[63999] = frames + 100;
        for (y = 0; y < 200; y++)
          memcpy(DG_ScreenBuffer + 320 * y, I_VideoBuffer + 320 * y, 320);
        DG_DrawFrame();
      }
      void doomgeneric_Create(int argc, char **argv) {
        DG_ScreenBuffer = out;
        I_VideoBuffer = video;
        finish();
      }
      void doomgeneric_Tick(void) { finish(); }
    '';
  };
  videoGuest = Cc.linkSources { units = [ videoUnit ]; };
  videoSym = videoGuest.__data.symbols;

  # videoGuest with a variable fb_scaling of the value n, as i_video.c has.
  scaledGuest =
    n:
    Cc.linkSources {
      units = [
        videoUnit
        {
          name = "scaling";
          src = "int fb_scaling = ${toString n};";
        }
      ];
    };

  # The driver over a guest of the shape of videoGuest for 2 ticks; acc lists bytes 0 and
  # 63999 of each frame.
  videoRunOf =
    linked:
    import ../doom/run.nix {
      inherit linked;
      args = [ "doom" ];
      ticks = 2;
      readKeys = _: null;
      onTick =
        info: acc:
        acc
        ++ map (f: [
          (elemAt f.screen 0)
          (elemAt f.screen 63999)
        ]) info.frames;
      init = [ ];
    };
  videoRun = videoRunOf videoGuest;

  # A guest with the parts of Doom that the driver uses to set the view window:
  # R_SetViewSize records its arguments and counts its calls, Create sets screenSize from
  # screenblocks as M_Init does and draws one frame.
  viewGuest = Cc.linkSources {
    units = [
      {
        name = "view";
        src = ''
          void DG_DrawFrame(void);
          unsigned char *DG_ScreenBuffer;
          unsigned colors[256];
          unsigned char screen[64000];
          int screenblocks = 10;
          int screenSize;
          int detailLevel = 1;
          int setblocks;
          int setdetail;
          int calls;
          void R_SetViewSize(int blocks, int detail) {
            setblocks = blocks;
            setdetail = detail;
            calls++;
          }
          void doomgeneric_Create(int argc, char **argv) {
            DG_ScreenBuffer = screen;
            screenSize = screenblocks - 3;
            DG_DrawFrame();
          }
          void doomgeneric_Tick(void) { DG_DrawFrame(); }
        '';
      }
    ];
  };

  # The driver over linked with view for one tick.
  viewRunOf =
    linked: view:
    import ../doom/run.nix {
      inherit linked view;
      args = [ "doom" ];
      ticks = 1;
      readKeys = _: null;
      onTick = _: acc: acc;
      init = null;
    };

  # calls, setblocks, setdetail, screenblocks and screenSize after a run of viewGuest.
  viewState =
    view:
    map (n: M.loadWord (viewRunOf viewGuest view).mem viewGuest.__data.symbols.${n}) [
      "calls"
      "setblocks"
      "setdetail"
      "screenblocks"
      "screenSize"
    ];

  # The driver over oddGuest with the key texts of ticks 1, 2, ...; acc lists per tick
  # the state of key a, the count of events taken and the events.
  runOdd =
    texts:
    import ../doom/run.nix {
      linked = oddGuest;
      args = [ "doom" ];
      ticks = length texts;
      readKeys = tick: elemAt texts (tick - 1);
      onTick =
        info: acc: acc ++ map (f: genList (elemAt f.screen) (2 + 2 * elemAt f.screen 1)) info.frames;
      init = [ ];
    };

  # The texts of a key changed at every tick: a, ab, aba, abab, ...
  alternating = genList (
    i: concatStringsSep "" (genList (j: if bitAnd j 1 == 0 then "a" else "b") (i + 1))
  ) 42;
  pendingOdd = n: length (runOdd (genList (elemAt alternating) n)).mem.host.keys;

  # A run whose onTick throws at tick 0 and whose readKeys aborts: the run fails with the
  # throw, which tryEval catches, only if tick 0 is handed to onTick before the key file is
  # read for tick 1; in the other order the abort stops the whole evaluation of the tests.
  orderRun = import ../doom/run.nix {
    linked = guest;
    args = [ "doom" ];
    ticks = 1;
    readKeys = _: abort "doom run test: readKeys was called before onTick of tick 0";
    onTick = info: acc: if info.tick == 0 then throw "tick 0" else acc;
    init = null;
  };

  # A guest that counts tics from the clock as doomgeneric does: getTime is I_GetTime of
  # i_timer.c, (ms - basetime) * 35 / 1000 with basetime the first nonzero ms read, and
  # TryRunTics runs one tic per tic passed since its last call, at most 5 (the rest are
  # lost, as in BuildNewTic). Each tic takes key events until none is left or after the
  # first release and keeps the state of each key. Create sleeps 1 ms at a time until the
  # first tic has passed, as the first TryRunTics of D_DoomLoop does, and draws nothing; doomgeneric_Tick runs TryRunTics, sleeps nap ms and draws one frame:
  # screen byte 0 is the count of all tics, byte 1 the tics of this tick, then the state
  # of key a (97) after each of them. calls counts the calls of TryRunTics.
  clockGuest = Cc.linkSources {
    units = [
      {
        name = "clock";
        src = ''
          int DG_GetKey(int *pressed, unsigned char *key);
          void DG_DrawFrame(void);
          int DG_GetTicksMs(void);
          void DG_SleepMs(int ms);
          unsigned char *DG_ScreenBuffer;
          unsigned colors[256];
          unsigned char screen[64000];
          unsigned char down[256];
          unsigned basetime;
          int seen;
          int total;
          int now;
          int calls;
          int nap = 3;
          int getTime(void) {
            unsigned t = DG_GetTicksMs();
            if (basetime == 0) basetime = t;
            return ((t - basetime) * 35) / 1000;
          }
          void doomgeneric_Create(int argc, char **argv) {
            DG_ScreenBuffer = screen;
            seen = getTime();
            while (getTime() - seen <= 0) DG_SleepMs(1);
            seen = getTime();
          }
          void TryRunTics(void) {
            int pressed;
            unsigned char key;
            int t = getTime();
            int n = t - seen;
            calls++;
            seen = t;
            if (n > 5) n = 5;
            while (n > 0) {
              while (DG_GetKey(&pressed, &key)) {
                down[key] = pressed;
                if (!pressed) break;
              }
              total++;
              screen[2 + now] = down[97];
              now++;
              n--;
            }
          }
          void doomgeneric_Tick(void) {
            TryRunTics();
            DG_SleepMs(nap);
            screen[0] = total;
            screen[1] = now;
            now = 0;
            DG_DrawFrame();
          }
        '';
      }
    ];
  };

  # The driver over a clock guest with tics per tick and the key texts of ticks 1, 2, ...;
  # acc lists per tick the key events sent and, per frame, screen bytes 1 .. 1 + byte 1
  # (the tics of the tick and the state of key a after each).
  runClockOf =
    linked: tics: texts:
    import ../doom/run.nix {
      inherit linked tics;
      args = [ "doom" ];
      ticks = length texts;
      readKeys = tick: elemAt texts (tick - 1);
      onTick =
        info: acc:
        acc
        ++ [
          {
            inherit (info) events;
            frames = map (f: genList (i: elemAt f.screen (1 + i)) (1 + elemAt f.screen 1)) info.frames;
          }
        ];
      init = [ ];
    };
  runClock = runClockOf clockGuest;

  # The value of the global variable name of a clock run.
  globalOf = r: name: M.loadWord r.mem clockGuest.__data.symbols.${name};

  # The tics of each tick (tick 0 included), the count of all tics, the calls of
  # TryRunTics and the clock after three ticks without input.
  clockSummary =
    tics:
    let
      r = runClock tics [
        null
        null
        null
      ];
    in
    {
      perTick = map (e: map head e.frames) r.acc;
      total = globalOf r "total";
      calls = globalOf r "calls";
      ms = r.mem.host.ms;
    };

  # The clock guest with nap set to 60 ms by __init: more than a tic passes in each tick.
  nappingGuest = clockGuest // {
    __init = m: M.storeWord (clockGuest.__init m) clockGuest.__data.symbols.nap 60;
  };

  # The tic count of the formula of I_GetTime, with the basetime 1 of the driver.
  ticAt = ms: ((ms - 1) * 35) / 1000;
  inherit (runGuest [ "doom" ] [ ]) msOfTic;
  ticKs = [
    0
    1
    2
    35
    36
    70
    1000
  ];

  # The pending key events after each tick of a clock run with tics over texts that
  # release two keys at once at tick 2.
  pendingClock =
    tics:
    genList (
      n:
      length
        (runClock tics (
          genList (elemAt [
            "ab"
            "abc"
            "abcd"
          ]) (n + 1)
        )).mem.host.keys
    ) 3;

  throws = x: !(builtins.tryEval (builtins.deepSeq x x)).success;
in
[
  (t "doom keys: ord of an ASCII character"
    [ (K.ord "A") (K.ord "~") ]
    [
      65
      126
    ]
  )
  (t "doom keys: ord of a byte outside the table" (K.ord (substring 0 1 "é")) (-1))
  (t "doom keys: decode CSI arrows" (keysOf "${esc}[A${esc}[B${esc}[C${esc}[D") [
    173
    175
    174
    172
  ])
  (t "doom keys: decode SS3 arrows" (keysOf "${esc}OA${esc}OD") [
    173
    172
  ])
  (t "doom keys: decode SS3 other final is dropped" (keysOf "${esc}OPa") [ 97 ])
  (t "doom keys: decode lone ESC followed by a byte" (keysOf "${esc}a") [
    27
    97
  ])
  (t "doom keys: decode ESC before ESC" (keysOf "${esc}${esc}a") [
    27
    27
    97
  ])
  (t "doom keys: rest of ESC" (restOf esc) 1)
  (t "doom keys: rest of ESC [" (restOf "a${esc}[") 2)
  (t "doom keys: rest of ESC O" (restOf "${esc}O") 2)
  (t "doom keys: rest of ESC [ 1 ;" (restOf "${esc}[1;") 4)
  (t "doom keys: unfinished sequence yields no key" (keysOf "a${esc}[1;") [ 97 ])
  (t "doom keys: complete sequences leave no rest" (restOf "${esc}[A${esc}OA") 0)
  (t "doom keys: CSI with a tilde final is dropped" (keysOf "${esc}[3~a") [ 97 ])
  (t "doom keys: CSI H is dropped" (keysOf "${esc}[H") [ ])
  (t "doom keys: CSI with parameters is dropped even for A" (keysOf "${esc}[1;5A") [ ])
  (t "doom keys: CSI with an intermediate is dropped" (keysOf "${esc}[ A") [ ])
  (t "doom keys: CSI cut by a stray byte resumes at that byte" (keysOf "${esc}[1\n") [ 13 ])
  (t "doom keys: CSI cut by ESC resumes at the ESC" (keysOf "${esc}[1${esc}[A") [ 173 ])
  (t "doom keys: bytes of 0x80 or more are dropped" (keysOf "aéb") [
    97
    98
  ])
  (t "doom keys: Enter" (keysOf "\r\n") [
    13
    13
  ])
  (t "doom keys: Backspace" (keysOf "${ctl 8}${del}") [
    127
    127
  ])
  (t "doom keys: Tab" (keysOf "\t") [ 9 ])
  (t "doom keys: space is use" (keysOf " ") [ 162 ])
  (t "doom keys: x and X are fire" (keysOf "xX") [
    163
    163
  ])
  (t "doom keys: capitals are lower case" (keysOf "AZ") [
    97
    122
  ])
  (t "doom keys: other printable bytes are themselves" (keysOf "!1~") [
    33
    49
    126
  ])
  (t "doom keys: control bytes are dropped" (keysOf "${ctl 1}a${ctl 2}") [ 97 ])
  (t "doom keys: decodeFinal reads ESC as escape" (K.decodeFinal (bytesOf esc)) [ 27 ])
  (t "doom keys: decodeFinal reads the rest plainly" (K.decodeFinal (bytesOf "${esc}[A")) [
    27
    91
    97
  ])
  (t "doom keys: poll presses then releases"
    (eventsOf [
      "${esc}[A"
      "${esc}[A"
    ])
    [
      [ (press 173) ]
      [ (release 173) ]
    ]
  )
  (t "doom keys: poll state after a press" (stateAfter [ "${esc}[A" ]) {
    consumed = 3;
    stalled = 0;
    held = [ 173 ];
  })
  (t "doom keys: poll state after the release"
    (stateAfter [
      "${esc}[A"
      "${esc}[A"
    ])
    {
      consumed = 3;
      stalled = 0;
      held = [ ];
    }
  )
  (t "doom keys: poll held key presses again and is not released"
    (eventsOf [
      "a"
      "aa"
      "aaa"
    ])
    [
      [ (press 97) ]
      [ (press 97) ]
      [ (press 97) ]
    ]
  )
  (t "doom keys: poll releases only the key that stopped, press first"
    (eventsOf [
      "ab"
      "abb"
    ])
    [
      [
        (press 97)
        (press 98)
      ]
      [
        (press 98)
        (release 97)
      ]
    ]
  )
  (t "doom keys: poll removes duplicates" (eventsOf [ "aab" ]) [
    [
      (press 97)
      (press 98)
    ]
  ])
  (t "doom keys: poll settles a lone ESC one poll later"
    (eventsOf [
      esc
      esc
      esc
    ])
    [
      [ ]
      [ (press 27) ]
      [ (release 27) ]
    ]
  )
  (t "doom keys: poll state of a pending ESC" (stateAfter [ esc ]) {
    consumed = 0;
    stalled = 1;
    held = [ ];
  })
  (t "doom keys: poll completes a sequence that arrives later"
    (eventsOf [
      "${esc}["
      "${esc}[A"
    ])
    [
      [ ]
      [ (press 173) ]
    ]
  )
  (t "doom keys: poll reads from the end of the earlier text"
    (eventsOf [
      "a"
      "ab"
    ])
    [
      [ (press 97) ]
      [
        (press 98)
        (release 97)
      ]
    ]
  )
  (t "doom keys: poll starts over when the file got shorter"
    (eventsOf [
      "aaaaa"
      "b"
    ])
    [
      [ (press 97) ]
      [
        (press 98)
        (release 97)
      ]
    ]
  )
  (t "doom keys: poll state after the file got shorter"
    (stateAfter [
      "aaaaa"
      "b"
    ])
    {
      consumed = 1;
      stalled = 0;
      held = [ 98 ];
    }
  )
  (t "doom keys: poll of 200,000 single bytes" (K.poll initial longPlain) {
    events = [
      (press 97)
      (press 98)
      (press 99)
    ];
    state = {
      consumed = 200000;
      stalled = 0;
      held = [
        97
        98
        99
      ];
    };
  })
  (t "doom keys: poll of ESC [ A repeated over 200,000 bytes" (K.poll initial longArrows) {
    events = [ (press 173) ];
    state = {
      consumed = 199998;
      stalled = 2;
      held = [ 173 ];
    };
  })
  (t "doom keys: decode of ESC [ A repeated over 200,000 bytes"
    (
      let
        d = K.decode (bytesOf longArrows);
      in
      [
        (d.keys == genList (_: 173) 66666)
        d.rest
      ]
    )
    [
      true
      2
    ]
  )
  (t "doom keys: decode of a CSI with 100,000 parameter bytes" (K.decode (bytesOf longParams)) {
    keys = [ 98 ];
    rest = 0;
  })
  (t "doom render: fit 160x52"
    (R.fit {
      columns = 160;
      lines = 52;
    })
    {
      cols = 160;
      rows = 50;
    }
  )
  (t "doom render: fit with spare columns"
    (R.fit {
      columns = 200;
      lines = 52;
    })
    {
      cols = 160;
      rows = 50;
    }
  )
  (t "doom render: fit with spare lines"
    (R.fit {
      columns = 80;
      lines = 100;
    })
    {
      cols = 80;
      rows = 25;
    }
  )
  (t "doom render: fit limited by lines"
    (R.fit {
      columns = 200;
      lines = 12;
    })
    {
      cols = 32;
      rows = 10;
    }
  )
  (t "doom render: fit minimum"
    (R.fit {
      columns = 0;
      lines = 0;
    })
    {
      cols = 1;
      rows = 1;
    }
  )
  (t "doom render: fit of three columns in one row"
    (R.fit {
      columns = 3;
      lines = 52;
    })
    {
      cols = 3;
      rows = 1;
    }
  )
  (t "doom render: 160x50 equals scaffold/render.nix" (
    R.render {
      inherit screen palette;
      cols = 160;
      rows = 50;
    } == Scaffold { inherit screen palette; }
  ) true)
  (t "doom render: 80x25 output hash" (sha {
    cols = 80;
    rows = 25;
  }) "3fe5c87c909f0d2ce6882a845b15e9f2bd560d927eada702b2effe8a9de0d321")
  (t "doom render: 320x100 (1x1 boxes) output hash" (sha {
    cols = 320;
    rows = 100;
  }) "9aeaffc31d72dc7390cfa9042a771f12accc1e9a182931f1ca4ec5846245133e")
  (t "doom render: 1x1 (boxes beyond 4096 pixels) output hash" (sha {
    cols = 1;
    rows = 1;
  }) "b4404ad4868558ed9a6d6777d65a4a535e92ac4ff4f71b281068e66960e97438")
  (t "doom render: 7x1 (boxes beyond 4096 pixels) output hash" (sha {
    cols = 7;
    rows = 1;
  }) "1bc77daa4ca65d1be78010be4dda884027c47643dafbccbd415a45d959114bd5")
  (t "doom render: 8x1 (boxes within 4096 pixels) output hash" (sha {
    cols = 8;
    rows = 1;
  }) "8a24226574bad88d04089c1158329f7330a82daf36da548bcd2a5b3501cfcb98")
  (t "doom render: 80x25 has 25 lines" (lineCount image80) 25)
  (t "doom render: 80x25 first cell" (substring 0 (stringLength firstCell) image80) firstCell)
  (t "doom render: row ends with a reset and a newline" (substring (
    stringLength image80 - 5
  ) 5 image80) "${esc}[0m\n")
  (t "doom render: renderMem of the whole screen equals render"
    [
      (memSha fullRect 80 25)
      (memSha fullRect 320 100)
      (memSha fullRect 7 1)
      (memImage fullRect 160 50 == Scaffold { inherit screen palette; })
      (
        R.renderMem (
          {
            mem = alignedMem;
            screenAddr = 131072;
            inherit palette;
            cols = 80;
            rows = 25;
          }
          // fullRect
        ) == image80
      )
    ]
    [
      "3fe5c87c909f0d2ce6882a845b15e9f2bd560d927eada702b2effe8a9de0d321"
      "9aeaffc31d72dc7390cfa9042a771f12accc1e9a182931f1ca4ec5846245133e"
      "1bc77daa4ca65d1be78010be4dda884027c47643dafbccbd415a45d959114bd5"
      true
      true
    ]
  )
  (t "doom render: renderMem of a 160x80 window 1:1 as 160x40 cells"
    [
      (memImage windowRect 160 40 == windowExpected)
      (substring 0 (stringLength (cellOf "168;80;248" "170;84;254")) (memImage windowRect 160 40))
      (lineCount (memImage windowRect 160 40))
    ]
    [
      true
      (cellOf "168;80;248" "170;84;254")
      40
    ]
  )
  (t "doom render: renderMem of a 160x80 window as 80x20 cells of 2x2 pixels"
    (
      let
        s = memImage windowRect 80 20;
      in
      [
        (substring 0 (stringLength (cellOf "169;83;188" "173;91;8")) s)
        (lineCount s)
      ]
    )
    [
      (cellOf "169;83;188" "173;91;8")
      20
    ]
  )
  (t "doom render: renderMem of a window as one cell (boxes beyond 4096 pixels)" (memImage windowRect
    1
    1
  ) (lineOf [ (cellOf (boxAverage 80 240 44 84) (boxAverage 80 240 84 124)) ]))
  (t "doom render: renderMem of an uneven window as 4x3 cells"
    (memImage {
      x = 5;
      y = 7;
      width = 33;
      height = 21;
    } 4 3)
    (
      let
        # Columns 5..13, 13..21, 21..29, 29..38; rows 7..10..14, 14..17..21, 21..24..28.
        xs = [
          5
          13
          21
          29
          38
        ];
        line =
          y0: ym: y1:
          lineOf (
            genList (
              c:
              cellOf (boxAverage (elemAt xs c) (elemAt xs (c + 1)) y0 ym) (
                boxAverage (elemAt xs c) (elemAt xs (c + 1)) ym y1
              )
            ) 4
          );
      in
      line 7 10 14 + line 14 17 21 + line 21 24 28
    )
  )
  (t "doom picture: blocksFor of 80, 96, 160, 161, 320, 400 and 1 columns"
    (map Pic.blocksFor [
      80
      96
      160
      161
      320
      400
      1
    ])
    [
      3
      3
      5
      6
      10
      10
      3
    ]
  )
  (t "doom picture: the 3D view is the window 1:1 and the status bar under it"
    (
      let
        s = picOf true levelVars;
      in
      [
        (s == memImage windowRect 160 40 + memImage barRect 160 8)
        (lineCount s)
        (substring 0 (stringLength windowExpected) s == windowExpected)
      ]
    )
    [
      true
      48
      true
    ]
  )
  (t
    "doom picture: the whole screen with a menu, the automap, outside a level, before a tic, and without windowed"
    (map (p: p == fullImage) [
      (picOf true (levelVars // { menuactive = 1; }))
      (picOf true (levelVars // { automapactive = 1; }))
      (picOf true (levelVars // { gamestate = 1; }))
      (picOf true (levelVars // { gametic = 0; }))
      (picOf false levelVars)
    ])
    [
      true
      true
      true
      true
      true
    ]
  )
  (t "doom picture: screen size 11 is the window of the whole screen and no bar"
    (
      let
        s = picOf true (
          levelVars
          // {
            viewwindowx = 0;
            viewwindowy = 0;
            scaledviewwidth = 320;
            viewheight = 200;
          }
        );
      in
      [
        (s == fullImage)
        (lineCount s)
      ]
    )
    [
      true
      50
    ]
  )
  (t "doom picture: a tall window shrinks with the bar to fit the rows"
    (picOf true (
      levelVars
      // {
        viewwindowx = 112;
        viewwindowy = 4;
        scaledviewwidth = 96;
        viewheight = 160;
      }
    ))
    (
      memImage {
        x = 112;
        y = 4;
        width = 96;
        height = 160;
      } 56 46
      + memImage barRect 56 2
    )
  )
  (t "doom picture: the window needs Doom's variables only with windowed"
    (
      let
        bare =
          windowed:
          Pic.picture {
            symbols = { };
            inherit windowed;
            cols = 160;
            rows = 50;
          } (picFrame { });
      in
      [
        (bare false == fullImage)
        (throws (bare true))
      ]
    )
    [
      true
      true
    ]
  )
  (t "doom DG_GetKey: no event returns 0 and leaves the memory"
    [
      noKey.ret
      (noKey.world.mem == keyMem)
    ]
    [
      0
      true
    ]
  )
  (t "doom DG_GetKey: two events in order, then 0"
    [
      key1.ret
      (keyWritten key1)
      key2.ret
      (keyWritten key2)
      key2.world.keys
      key3.ret
      (key3.world.mem == key2.world.mem)
    ]
    [
      1
      [
        1
        173
        255
      ]
      1
      [
        0
        97
        255
      ]
      [ ]
      0
      true
    ]
  )
  (t "doom run: argv reaches Create and tick 0 has its frame and output" (elemAt keyRun.acc 0) {
    tick = 0;
    out = "doom\n-x\nfoo\n";
    frames = [
      [
        3
        0
        0
        0
        0
        0
        0
      ]
    ];
  })
  (t "doom run: each tick has its own frames, output and key events" (builtins.tail keyRun.acc) [
    {
      tick = 1;
      out = "a\n";
      frames = [
        [
          1
          1
          97
          0
          0
          0
          0
        ]
      ];
    }
    {
      tick = 2;
      out = "b\n";
      frames = [
        [
          2
          1
          98
          0
          97
          0
          0
        ]
      ];
    }
    {
      tick = 3;
      out = "c\n";
      frames = [
        [
          1
          0
          98
          0
          97
          0
          0
        ]
      ];
    }
    {
      tick = 4;
      out = "d\n";
      frames = [
        [
          0
          0
          98
          0
          97
          0
          0
        ]
      ];
    }
    {
      tick = 5;
      out = "e\n";
      frames = [
        [
          1
          1
          173
          0
          97
          0
          0
        ]
      ];
    }
  ])
  (t "doom run: result fields and emptied host frames and output"
    [
      keyRun.frameCount
      (genList (elemAt keyRun.last.screen) 3)
      keyRun.mem.host.frames
      keyRun.mem.host.out
      keyRun.mem.host.keys
    ]
    [
      6
      [
        1
        1
        173
      ]
      [ ]
      ""
      [ ]
    ]
  )
  (t "doom run: a frame record holds the memory of its frame and the address of the screen"
    [
      (keyRun.last.screenAddr == guest.__data.symbols.screen)
      (genList (i: M.loadByte keyRun.last.mem (keyRun.last.screenAddr + i)) 3)
    ]
    [
      true
      [
        1
        1
        173
      ]
    ]
  )
  (t "doom run: DG_ScreenBuffer points at I_VideoBuffer after Create, and the frames are the same"
    [
      (M.loadWord videoRun.mem videoSym.DG_ScreenBuffer == videoSym.video)
      videoRun.acc
      # Only the frame of Create was copied to out.
      (M.loadByte videoRun.mem videoSym.out)
      (M.loadByte videoRun.mem (videoSym.out + 63999))
    ]
    [
      true
      [
        [
          1
          101
        ]
        [
          2
          102
        ]
        [
          3
          103
        ]
      ]
      1
      101
    ]
  )
  (t "doom run: DG_ScreenBuffer points at I_VideoBuffer only when fb_scaling is 1"
    (map
      (
        n:
        let
          g = scaledGuest n;
          r = videoRunOf g;
        in
        [
          (M.loadWord r.mem g.__data.symbols.DG_ScreenBuffer == g.__data.symbols.video)
          r.acc
          (M.loadByte r.mem (g.__data.symbols.out + 63999))
        ]
      )
      [
        1
        2
      ]
    )
    [
      [
        true
        [
          [
            1
            101
          ]
          [
            2
            102
          ]
          [
            3
            103
          ]
        ]
        101
      ]
      [
        false
        [
          [
            1
            101
          ]
          [
            2
            102
          ]
          [
            3
            103
          ]
        ]
        103
      ]
    ]
  )
  (t "doom run: view sets the view window as the menu does, and null leaves it alone"
    [
      (viewState 5)
      (viewState 10)
      (viewState null)
    ]
    [
      [
        1
        5
        1
        5
        2
      ]
      [
        1
        10
        1
        10
        7
      ]
      [
        0
        0
        0
        10
        7
      ]
    ]
  )
  (t "doom run: view needs R_SetViewSize, screenblocks and detailLevel, and blocks from 3 to 10"
    [
      (throws (viewRunOf guest 5).frameCount)
      (throws (viewRunOf guest null).frameCount)
      (throws (viewRunOf viewGuest 2).frameCount)
      (throws (viewRunOf viewGuest 11).frameCount)
      (throws (viewRunOf viewGuest 3).frameCount)
    ]
    [
      true
      false
      true
      true
      false
    ]
  )
  (t "doom run: DG_ScreenBuffer is left as it is without I_VideoBuffer in the link"
    [
      (guest.__data.symbols ? I_VideoBuffer)
      (M.loadWord keyRun.mem guest.__data.symbols.DG_ScreenBuffer == guest.__data.symbols.screen)
    ]
    [ false true ]
  )
  (t "doom run: no tick runs Create only"
    (
      let
        r = runGuest guestArgs [ ];
      in
      [
        r.frameCount
        (length r.acc)
        (genList (elemAt r.last.screen) 1)
      ]
    )
    [
      1
      1
      [ 3 ]
    ]
  )
  (t "doom run: pending key events do not pile up over held and released keys"
    (genList (i: pendingAfter (i + 1)) 6)
    [
      0
      0
      0
      1
      0
      0
    ]
  )
  (t "doom run: a single press before an even tick is seen, then released"
    (runOdd [
      ""
      "a"
      "a"
      "a"
      "a"
    ]).acc
    [
      [
        0
        0
      ]
      [
        0
        0
      ]
      [
        1
        1
        1
        97
      ]
      [
        1
        0
      ]
      [
        0
        1
        0
        97
      ]
    ]
  )
  (t "doom run: a single press before an odd tick is seen, then released"
    (runOdd [
      "a"
      "a"
      "a"
      "a"
      "a"
    ]).acc
    [
      [
        1
        1
        1
        97
      ]
      [
        1
        0
      ]
      [
        0
        1
        0
        97
      ]
      [
        0
        0
      ]
      [
        0
        0
      ]
    ]
  )
  (t "doom run: pending key events stay at most 2 when the key changes at every tick" (genList (
    i: pendingOdd (i + 1)
  ) 42) (genList (i: if bitAnd i 1 == 0 then 0 else 2) 42))
  (t "doom run: a held key gives presses only at every take"
    (runOdd [
      "a"
      "aa"
      "aaa"
      "aaaa"
      "aaaaa"
      "aaaaaa"
    ]).acc
    [
      [
        1
        1
        1
        97
      ]
      [
        1
        0
      ]
      [
        1
        1
        1
        97
      ]
      [
        1
        0
      ]
      [
        1
        1
        1
        97
      ]
      [
        1
        0
      ]
    ]
  )
  (t "doom run: onTick of tick 0 comes before the key file is read for tick 1"
    (builtins.tryEval orderRun.acc).success
    false
  )
  (t "doom run: argument strings up to 4096 bytes"
    [
      (throws (runGuest [ (concatStringsSep "" (genList (_: "a") 4095)) ] [ ]).frameCount)
      (throws (runGuest [ (concatStringsSep "" (genList (_: "a") 4096)) ] [ ]).frameCount)
    ]
    [
      false
      true
    ]
  )
  (t "doom exitText: the output not yet shown follows the status"
    [
      (Cc.host.exitText (guest.bye keyRun.mem).host 3)
      (Cc.host.exitText keyRun.mem.host 1)
    ]
    [
      "libc: exit: 3\nbye\n"
      "libc: exit: 1"
    ]
  )
  (t "doom run: msOfTic of tic counts" (map msOfTic ticKs) [
    1
    30
    59
    1001
    1030
    2001
    28573
  ])
  (t "doom run: msOfTic is the least ms of its tic count"
    (map (k: [
      (ticAt (msOfTic k))
      (ticAt (msOfTic k - 1))
    ]) (builtins.tail ticKs))
    [
      [
        1
        0
      ]
      [
        2
        1
      ]
      [
        35
        34
      ]
      [
        36
        35
      ]
      [
        70
        69
      ]
      [
        1000
        999
      ]
    ]
  )
  (t "doom run: tics 0 leaves the clock to the guest's sleeps" (clockSummary 0) {
    perTick = [
      [ ]
      [ 0 ]
      [ 0 ]
      [ 0 ]
    ];
    total = 0;
    calls = 3;
    ms = 39;
  })
  (t "doom run: tics 0 runs the tics the guest's own sleeps passed"
    (
      let
        r = runClockOf nappingGuest 0 [
          null
          null
          null
        ];
      in
      [
        (map (e: map head e.frames) r.acc)
        r.mem.host.ms
      ]
    )
    [
      [
        [ ]
        [ 0 ]
        [ 2 ]
        [ 2 ]
      ]
      210
    ]
  )
  (t "doom run: tics 1 runs one tic and draws once per tick" (clockSummary 1) {
    perTick = [
      [ ]
      [ 1 ]
      [ 1 ]
      [ 1 ]
    ];
    total = 3;
    calls = 3;
    ms = 119;
  })
  (t "doom run: tics 5 runs five tics in doomgeneric_Tick alone" (clockSummary 5) {
    perTick = [
      [ ]
      [ 5 ]
      [ 5 ]
      [ 5 ]
    ];
    total = 15;
    calls = 3;
    ms = 462;
  })
  (t "doom run: tics 6 runs five tics in TryRunTics and one in doomgeneric_Tick" (clockSummary 6) {
    perTick = [
      [ ]
      [ 6 ]
      [ 6 ]
      [ 6 ]
    ];
    total = 18;
    calls = 6;
    ms = 547;
  })
  (t "doom run: tics 18 runs 5, 5, 5 and 3 tics per tick" (clockSummary 18) {
    perTick = [
      [ ]
      [ 18 ]
      [ 18 ]
      [ 18 ]
    ];
    total = 54;
    calls = 12;
    ms = 1576;
  })
  (t "doom run: tics counts from the current clock, which the guest also advances"
    (
      let
        r = runClockOf nappingGuest 2 [
          null
          null
          null
        ];
      in
      [
        (map (e: map head e.frames) r.acc)
        r.mem.host.ms
      ]
    )
    [
      [
        [ ]
        [ 2 ]
        [ 4 ]
        [ 4 ]
      ]
      376
    ]
  )
  (t "doom run: tics 3 holds a single press for its tick and releases it at the next"
    (runClock 3 [
      "a"
      "a"
      "a"
    ]).acc
    [
      {
        events = [ ];
        frames = [ ];
      }
      {
        events = [ (press 97) ];
        frames = [
          [
            3
            1
            1
            1
          ]
        ];
      }
      {
        events = [ (release 97) ];
        frames = [
          [
            3
            0
            0
            0
          ]
        ];
      }
      {
        events = [ ];
        frames = [
          [
            3
            0
            0
            0
          ]
        ];
      }
    ]
  )
  (t "doom run: tics 3 keeps a held key down with no release"
    (map (e: e.frames) (
      builtins.tail
        (runClock 3 [
          "a"
          "aa"
          "aaa"
        ]).acc
    ))
    (
      genList (_: [
        [
          3
          1
          1
          1
        ]
      ]) 3
    )
  )
  (t "doom run: pending key events after each tick with tics 1 and 2"
    [
      (pendingClock 1)
      (pendingClock 2)
    ]
    [
      [
        0
        1
        0
      ]
      [
        0
        0
        0
      ]
    ]
  )
  (t "doom run: tics above 5 needs TryRunTics, and tics must be a non-negative integer"
    [
      (throws (runClockOf guest 6 [ null ]).frameCount)
      (runClockOf guest 5 [ null ]).frameCount
      (throws (runClockOf guest 6 [ ]).frameCount)
      (throws (runClock (-1) [ ]).frameCount)
    ]
    [
      true
      2
      true
      true
    ]
  )
]
