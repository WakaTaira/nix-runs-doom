# Tests of the pure parts of the Doom platform layer: key decoding (doom/keys.nix) and
# variable-size rendering (doom/render.nix). No WAD and no Doom source are used. Expected
# values are worked out by hand from the rules at the top of each file; key numbers follow
# doomkeys.h (up 0xad = 173, down 0xaf = 175, right 0xae = 174, left 0xac = 172, use
# 0xa2 = 162, fire 0xa3 = 163).
let
  K = import ../doom/keys.nix;
  R = import ../doom/render.nix;
  Scaffold = import ../scaffold/render.nix;
  inherit (builtins)
    bitAnd
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
  (t "doom render: fit of one column"
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
]
