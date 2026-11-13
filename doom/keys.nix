# Decoding of terminal input into Doom key events. Pure functions only; the file is read
# by the driver (doom/run.nix).
#
#   ord      : one-character string -> integer (1..127 from lib/ascii.nix, else -1)
#   decode   : bytes -> { keys; rest; }
#   decodeFinal : bytes -> keys
#   poll     : { consumed; stalled; held; } -> text -> { state; events; }
#
# bytes is a list of byte values (-1 allowed, for a byte of 0x80 or more); keys is a list
# of doomkeys.h numbers in order of appearance, duplicates included.
#
# decode reads from the front:
#   - ESC [ params(0x30..0x3f)* intermediates(0x20..0x2f)* final(0x40..0x7e) is a CSI.
#     With no parameter and no intermediate, the finals A/B/C/D are up 0xad, down 0xaf,
#     right 0xae and left 0xac; any other complete CSI is dropped whole. A byte that is
#     neither a parameter, an intermediate nor a final ends the sequence: everything
#     before it is dropped and decoding resumes at that byte.
#   - ESC O x (SS3) is an arrow for A/B/C/D and dropped otherwise.
#   - A sequence cut off by the end of the input (ESC, ESC O, ESC [ ... without a final)
#     is not decoded; rest is its length, counted from the ESC.
#   - Any other ESC is KEY_ESCAPE 27.
#   - 13 and 10 are KEY_ENTER 13, 127 and 8 are KEY_BACKSPACE 0x7f, 9 is KEY_TAB 9,
#     space is KEY_USE 0xa2, x and X are KEY_FIRE 0xa3, A..Z are the lower-case numbers,
#     the other 33..126 are themselves. Every other byte is dropped.
# decodeFinal reads an unfinished sequence as complete: ESC is KEY_ESCAPE and the other
# bytes follow the rules above, except for ESC.
#
# poll takes the whole text of the key file. A key is held from the poll that decodes the
# bytes that mean it until the next poll, because a terminal never reports a release (the
# driver, doom/run.nix, decides when to poll). events are
# the presses of the keys decoded now (duplicates removed, first appearance first), then
# the releases of the keys held before and not decoded now. A key held on purpose
# (repeated bytes) gets a press again each time and no release: i_input.c hands out one
# release per call, so a release placed first would cancel the next press of a held key.
# An unfinished sequence that has not grown since the previous poll is read with
# decodeFinal, so a lone ESC is settled one poll after it arrives. A text shorter than
# consumed means the file was emptied: reading starts again from the front. If the file
# is emptied and then written past the old length before the next poll, this cannot be
# noticed and the first bytes are skipped.
let
  inherit (builtins)
    concatMap
    elemAt
    foldl'
    genericClosure
    genList
    length
    listToAttrs
    substring
    stringLength
    ;

  ascii = import ../lib/ascii.nix;

  # The table of lib/ascii.nix, inverted; a character outside it (a byte of 0x80 or
  # more) is -1.
  codeTable = listToAttrs (
    genList (i: {
      name = ascii.chr (i + 1);
      value = i + 1;
    }) 127
  );

  ord = c: codeTable.${c} or (-1);

  keyEscape = 27;
  keyEnter = 13;
  keyBackspace = 127;
  keyTab = 9;
  keyUse = 162;
  keyFire = 163;
  arrows = {
    "65" = 173; # A: up
    "66" = 175; # B: down
    "67" = 174; # C: right
    "68" = 172; # D: left
  };

  # Key number of a byte outside any escape sequence, or null when it is dropped.
  plainKey =
    b:
    if b == 13 || b == 10 then
      keyEnter
    else if b == 127 || b == 8 then
      keyBackspace
    else if b == 9 then
      keyTab
    else if b == 32 then
      keyUse
    else if b == 120 || b == 88 then
      keyFire
    else if b >= 65 && b <= 90 then
      b + 32
    else if b >= 33 && b <= 126 then
      b
    else
      null;

  arrowKey = b: arrows.${toString b} or null;

  keyList = k: if k == null then [ ] else [ k ];

  # The items of a chain of integers from start, each the next of the one before, until
  # next gives null. genericClosure builds the list iteratively, so neither the depth of
  # the evaluation stack nor the copying grows with its length.
  chain =
    start: next:
    genericClosure {
      startSet = [ { key = start; } ];
      operator =
        item:
        let
          j = next item.key;
        in
        if j == null then [ ] else [ { key = j; } ];
    };

  lastOf = l: elemAt l (length l - 1);

  # The index of the first byte at or after i that is not in lo..hi.
  skipRange =
    bytes: lo: hi: i:
    let
      inRange = j: j < length bytes && elemAt bytes j >= lo && elemAt bytes j <= hi;
    in
    if inRange i then (lastOf (chain i (j: if inRange (j + 1) then j + 1 else null))).key + 1 else i;

  # decode reads the input as a chain of tokens, each found from its first byte alone:
  # token i is { keys; next; } with next the index of the following token (n at the end),
  # or null for a sequence cut off by the end of the input.
  decode =
    bytes:
    let
      n = length bytes;

      token =
        i:
        let
          b = elemAt bytes i;
        in
        if b == 27 then escape i else emit (keyList (plainKey b)) (i + 1);

      emit = keys: next: { inherit keys next; };

      truncated = {
        keys = [ ];
        next = null;
      };

      escape =
        i:
        if i + 1 >= n then
          truncated
        else
          let
            c = elemAt bytes (i + 1);
          in
          if c == 91 then
            csi i
          else if c == 79 then
            ss3 i
          else
            emit [ keyEscape ] (i + 1);

      ss3 = i: if i + 2 >= n then truncated else emit (keyList (arrowKey (elemAt bytes (i + 2)))) (i + 3);

      csi =
        i:
        let
          afterParams = skipRange bytes 48 63 (i + 2);
          k = skipRange bytes 32 47 afterParams;
          f = elemAt bytes k;
        in
        if k >= n then
          truncated
        else if f >= 64 && f <= 126 then
          emit (if k == i + 2 then keyList (arrowKey f) else [ ]) (k + 1)
        else
          emit [ ] k;

      # The tokens by their first byte, each computed once.
      tokens = genList token n;
      tokenAt = elemAt tokens;

      # The start of the token after the one at i, or null after the last one.
      nextStart =
        i:
        let
          j = (tokenAt i).next;
        in
        if j == null || j >= n then null else j;

      starts = if n == 0 then [ ] else map (item: item.key) (chain 0 nextStart);

      last = lastOf starts;
    in
    {
      keys = concatMap (i: (tokenAt i).keys) starts;
      rest = if starts == [ ] || (tokenAt last).next != null then 0 else n - last;
    };

  decodeFinal = concatMap (b: keyList (if b == 27 then keyEscape else plainKey b));

  # Duplicates removed, first appearance first.
  unique = foldl' (acc: k: if builtins.elem k acc then acc else acc ++ [ k ]) [ ];

  bytesOfText = text: genList (i: ord (substring i 1 text)) (stringLength text);

  press = key: {
    pressed = 1;
    inherit key;
  };
  release = key: {
    pressed = 0;
    inherit key;
  };

  poll =
    state: text:
    let
      reset = stringLength text < state.consumed;
      consumed = if reset then 0 else state.consumed;
      stalled = if reset then 0 else state.stalled;
      fresh = bytesOfText (substring consumed (stringLength text - consumed) text);
      freshLength = length fresh;
      d = decode fresh;
      settle = d.rest > 0 && freshLength == stalled;
      decoded = if settle then decodeFinal fresh else d.keys;
      rest = if settle then 0 else d.rest;
      now = unique decoded;
      gone = builtins.filter (k: !(builtins.elem k now)) state.held;
    in
    {
      state = {
        consumed = consumed + freshLength - rest;
        stalled = rest;
        held = now;
      };
      events = map press now ++ map release gone;
    };
in
{
  inherit
    ord
    decode
    decodeFinal
    poll
    ;
}
