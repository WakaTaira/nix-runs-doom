# Tests of the Doom platform layer: key decoding (doom/keys.nix), variable-size rendering
# (doom/render.nix), DG_GetKey (scaffold/platform.nix), the driver (doom/run.nix) on small
# guests written in C and linked with cc.linkSources, and exitText (cc/host.nix). No WAD
# and no Doom source are used. Expected values are worked out by hand from the rules at
# the top of each file; key numbers follow doomkeys.h (up 0xad = 173, down 0xaf = 175,
# right 0xae = 174, left 0xac = 172, use 0xa2 = 162, fire 0xa3 = 163).
let
  K = import ../doom/keys.nix;
  R = import ../doom/render.nix;
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
  lineCount = s: (length (split "\n" s) - 1) / 2;
  firstCell = "${esc}[38;2;4;9;13m${esc}[48;2;12;25;37m▀";

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
  (t "doom render: 80x25 has 25 lines" (lineCount image80) 25)
  (t "doom render: 80x25 first cell" (substring 0 (stringLength firstCell) image80) firstCell)
  (t "doom render: row ends with a reset and a newline" (substring (
    stringLength image80 - 5
  ) 5 image80) "${esc}[0m\n")
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
]
