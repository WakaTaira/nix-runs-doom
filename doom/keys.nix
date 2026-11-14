# Decoding of terminal input into Doom key events. Pure functions only; the file is read
# by the driver (doom/run.nix).
#
#   ord      : one-character string -> integer (1..127 from lib/ascii.nix, else -1)
#   decode   : bytes -> { keys; rest; }
#   decodeFinal : bytes -> keys
#   poll     : { consumed; stalled; held; } -> text -> { state; events; }
#   decodeKitty : bytes -> { keys; rest; }
#   pollKitty   : { consumed; held; carried; trusted; } -> text -> { state; events; }
#   decodeWin32 : bytes -> { keys; rest; }
#   pollWin32   : { consumed; held; carried; } -> text -> { state; events; }
#
# bytes is a list of byte values (-1 allowed, for a byte of 0x80 or more); keys is a list
# of doomkeys.h numbers in order of appearance, duplicates included. decode and poll read
# the bytes of a terminal in its usual (legacy) mode, decodeKitty and pollKitty those of a
# terminal in the kitty keyboard protocol, decodeWin32 and pollWin32 those of a terminal in
# the win32-input-mode of Windows Terminal (see the end of this comment).
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
#
# The kitty keyboard protocol (https://sw.kovidgoyal.net/kitty/keyboard-protocol/) with
# the flags 11 (disambiguate 1, report event types 2, report all keys as escape codes 8)
# reports every press, repeat and release of every key, modifier keys alone included, as
# an escape sequence:
#   CSI code[:alternates] [; mods[:event]] [; text] u     CSI [1] [; mods[:event]] A/B/C/D
# with mods 1 + the bits of the active modifiers (shift 1, alt 2, ctrl 4, ...,
# caps_lock 64, num_lock 128) and event 1 press (the default), 2 repeat or 3 release.
# decodeKitty reads from the front and its keys are events { key; type; } (type 1, 2 or 3):
#   - A CSI is found as in decode. When its parameter bytes are digits, ':' and ';' only
#     and it has no intermediate, the first two subfields of the first two fields are
#     code, mods and event; other subfields and fields (alternate keys, text) are ignored,
#     and so are mods: a character typed with a modifier is the character's key, and the
#     modifier key sends its own events. With the final u, code 27 is KEY_ESCAPE, a code
#     below 128 is the key of that byte in decode (13 Enter, 9 Tab, 127 Backspace, 32 use,
#     x fire, other printable characters themselves), left and right shift (57441, 57447)
#     are KEY_RSHIFT 0xb6 (run), left and right control (57442, 57448) KEY_FIRE 0xa3 and
#     left and right alt (57443, 57449) KEY_RALT 0xb8 (strafe). The finals A/B/C/D, with
#     code absent or 1, are the arrows. An event other than 1, 2 and 3, any other code or
#     final, a parameter byte such as '?' or '>' (the replies of the terminal) and any CSI
#     with an intermediate are dropped whole; a byte that ends a CSI early is handled as
#     in decode.
#   - ESC O x is dropped, and so is any other ESC that does not start a CSI.
#   - A sequence cut off by the end of the input is not decoded; rest is its length.
#     pollKitty reads it again with the bytes of the next poll, however long it waits:
#     unlike in decode no lone ESC is settled, because the key Esc is CSI 27 u here, and
#     an ESC that never gets its sequence is dropped once the next bytes arrive.
#   - Any other byte, which a terminal that ignores flag 8 might send, is the key of decode
#     pressed and released at once (dropped when decode drops it).
#
# pollKitty trusts the terminal to report releases only from the first release event it
# sends (an event whose type the terminal wrote, `:3`). Some terminals accept the flags and
# answer the query with them, yet send presses only; a key would then stay down for ever
# and its next press would be ignored. Until a release has been seen, pollKitty makes up
# the releases as poll does (a key is down from the read that finds its press until the
# next read); the first reported release, usually that of the Enter that started the
# program, switches to the reported presses and releases described next.
#
# pollKitty decodes the part of the text after consumed (from the front when the text got
# shorter, as poll does) and turns the events into presses and releases with no made-up
# release: held lists the keys pressed for Doom, carried those of them whose release is
# put off. Before the new events, every key of carried is released. Then, in order, a press
# or a repeat of a key not held is a press; of a key held, it only takes the key out of
# carried. A release of a key not held is dropped; of a key pressed in this poll, it puts
# the key in carried, so that its release comes at the next poll; of any other key held, it
# is a release. A key pressed and released between two polls is thus held for one poll:
# i_input.c takes events up to and including the first release in one call, and a press
# and a release taken in the same tic cancel out in gamekeydown. A press never comes for a
# key held and a release never for a key not held, which keeps the shift count of i_input.c
# right. Keys are tracked by key number, so both shift keys are one key, and so are both
# control keys and x.
#
# The win32-input-mode of Windows Terminal (CSI ? 9001 h; microsoft/terminal,
# doc/specs/#4999 - Improved keyboard handling in Conpty.md) reports every key event of
# Windows, modifier keys alone included, as
#   CSI Vk ; Sc ; Uc ; Kd ; Cs ; Rc _
# with Vk the virtual-key code, Sc the scan code, Uc the character (UTF-16, decimal), Kd 1
# for a press (a repeat included) and 0 for a release, Cs the control key state and Rc the
# repeat count; an omitted field is 0, except Rc, which is 1. decodeWin32 reads from the
# front and its keys are events { key; type; } (type 1 press or 3 release, as in
# decodeKitty):
#   - A CSI is found as in decode. When its parameter bytes are digits and ';' only, it has
#     no intermediate and its final is '_', Vk, Uc and Kd give the event; Sc, Cs, Rc and
#     any field after the sixth are ignored, so a key typed with a modifier is the key, and
#     the modifier key sends its own events. The key is that of Vk when Vk names one: 37
#     left, 38 up, 39 right, 40 down, 13 KEY_ENTER, 27 KEY_ESCAPE, 9 KEY_TAB, 8
#     KEY_BACKSPACE, 32 KEY_USE, 16, 160 and 161 (shift, left, right) KEY_RSHIFT, 17, 162
#     and 163 (control) KEY_FIRE, 18, 164 and 165 (alt) KEY_RALT, the letters 65..90 the
#     lower-case numbers (88, x, is KEY_FIRE as in decode) and the digits 48..57
#     themselves. For any other Vk but 0, a Uc of 33..126 is the key of that byte in decode
#     (letters in lower case), so that '-' and '=' work on any layout; Vk wins where it
#     names a key, because a letter typed with control has a control character in Uc. Vk 0
#     (an event that only carries a character, such as pasted text), any other key, a Kd
#     other than 0 and 1, a parameter byte such as '?' or ':', any intermediate and any
#     other final are dropped whole; a byte that ends a CSI early is handled as in decode.
#   - ESC O x, any other ESC, a sequence cut off by the end of the input and any byte
#     outside a sequence are handled as in decodeKitty.
#
# pollWin32 trusts the terminal from the first read: Windows reports every release, so the
# presses and releases are those of pollKitty for a trusted terminal (held, carried, a
# press of a held key ignored, a release of a key not held dropped, the release of a key
# pressed in the same read put off to the next read). The release of the Enter that
# started the program, usually first in the file, is thus dropped.
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

  # scan reads the input as a chain of tokens, each found from its first byte alone:
  # tokenAt i is { keys; next; } with next the index of the following token (n at the end),
  # or null for a sequence cut off by the end of the input. The result lists the keys of
  # the tokens in order and rest, the length of the cut-off sequence at the end (0 if none).
  scan =
    n: tokenAt:
    let
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

  emit = keys: next: { inherit keys next; };

  truncated = {
    keys = [ ];
    next = null;
  };

  # The tokens of bytes by their first byte, each computed once by token.
  tokensOf = token: n: elemAt (genList token n);

  # The index of the final byte of the CSI whose ESC is at i (params and intermediates
  # skipped), and the index where its parameters end.
  csiEnd =
    bytes: i:
    let
      afterParams = skipRange bytes 48 63 (i + 2);
    in
    {
      inherit afterParams;
      final = skipRange bytes 32 47 afterParams;
    };

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
          k = (csiEnd bytes i).final;
          f = elemAt bytes k;
        in
        if k >= n then
          truncated
        else if f >= 64 && f <= 126 then
          emit (if k == i + 2 then keyList (arrowKey f) else [ ]) (k + 1)
        else
          emit [ ] k;
    in
    scan n (tokensOf token n);

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

  # Event types of the kitty keyboard protocol.
  typePress = 1;
  typeRelease = 3;

  # The modifier keys reported alone (flag 8): left and right shift, control and alt.
  modifierKeys = {
    "57441" = keyRShift;
    "57447" = keyRShift;
    "57442" = keyFire;
    "57448" = keyFire;
    "57443" = keyRAlt;
    "57449" = keyRAlt;
  };
  keyRShift = 182;
  keyRAlt = 184;

  # The key number of the code of a CSI u, or null when it is dropped.
  codeKey =
    code:
    if code == null then
      null
    else if code == 27 then
      keyEscape
    else if code < 128 then
      plainKey code
    else
      modifierKeys.${toString code} or null;

  # A decimal number that stops growing past 9 digits, so that no long parameter
  # overflows; no key code is that large.
  digitStep = v: d: if v > 99999999 then v else v * 10 + d;

  # The subfields of the parameter bytes of a CSI named by slots, an attribute set of names
  # by "<field>:<subfield>" (each null when absent or empty), or null when a byte is neither
  # a digit, ';' nor, if subfields is true, ':'. Every step is forced, so that long
  # parameters build no chain of thunks.
  csiFields =
    slots: subfields: params:
    let
      commit =
        s:
        let
          name = slots."${toString s.field}:${toString s.sub}" or null;
        in
        if name == null then s else s // { ${name} = s.num; };
      step =
        s: b:
        if s.bad then
          s
        else if b >= 48 && b <= 57 then
          s // { num = digitStep (if s.num == null then 0 else s.num) (b - 48); }
        else if b == 58 && subfields then
          commit s
          // {
            sub = s.sub + 1;
            num = null;
          }
        else if b == 59 then
          commit s
          // {
            field = s.field + 1;
            sub = 0;
            num = null;
          }
        else
          s // { bad = true; };
      # Every named subfield, null.
      absent = listToAttrs (
        map (name: {
          inherit name;
          value = null;
        }) (builtins.attrValues slots)
      );
      start = {
        field = 0;
        sub = 0;
        num = null;
        bad = false;
      }
      // absent;
      result = commit (
        foldl' (
          s: b:
          let
            s' = step s b;
          in
          builtins.deepSeq s' s'
        ) start params
      );
    in
    if result.bad then null else builtins.intersectAttrs absent result;

  # The code, mods and event of the parameter bytes of a CSI of the kitty protocol: the
  # first two subfields of the first two fields.
  kittyParams = csiFields {
    "0:0" = "code";
    "1:0" = "mods";
    "1:1" = "event";
  } true;

  # The events of a complete CSI with the parameter bytes params, no intermediate and the
  # final byte f: [ { key; type; } ] or [ ] when it is dropped.
  kittyEvents =
    params: f:
    let
      p = kittyParams params;
      key =
        if f == 117 then
          codeKey p.code
        else if p.code == null || p.code == 1 then
          arrowKey f
        else
          null;
      type = if p.event == null then typePress else p.event;
    in
    if p == null || key == null || type < 1 || type > 3 then
      [ ]
    else
      [
        {
          inherit key type;
          # The terminal wrote the event type itself (see pollKitty about trust).
          explicit = p.event != null;
        }
      ];

  # A byte outside any escape sequence is a press and a release at once.
  tap =
    k:
    if k == null then
      [ ]
    else
      [
        {
          key = k;
          type = typePress;
        }
        {
          key = k;
          type = typeRelease;
        }
      ];

  # The keys of the win32-input-mode by virtual-key code (see the header); letters and
  # digits are in win32VkKey.
  win32Keys = {
    "8" = keyBackspace;
    "9" = keyTab;
    "13" = keyEnter;
    "27" = keyEscape;
    "32" = keyUse;
    "37" = 172; # left
    "38" = 173; # up
    "39" = 174; # right
    "40" = 175; # down
    "16" = keyRShift;
    "160" = keyRShift;
    "161" = keyRShift;
    "17" = keyFire;
    "162" = keyFire;
    "163" = keyFire;
    "18" = keyRAlt;
    "164" = keyRAlt;
    "165" = keyRAlt;
  };

  # The key named by a virtual-key code, or null when it names none.
  win32VkKey =
    vk:
    if (vk >= 65 && vk <= 90) || (vk >= 48 && vk <= 57) then
      plainKey vk
    else
      win32Keys.${toString vk} or null;

  # The key of an event with the virtual-key code vk and the character uc, or null when it
  # is dropped.
  win32Key =
    vk: uc:
    let
      named = win32VkKey vk;
    in
    if vk == 0 then
      null
    else if named != null then
      named
    else if uc >= 33 && uc <= 126 then
      plainKey uc
    else
      null;

  # The virtual-key code, character and key-down flag of the parameter bytes of a CSI of
  # the win32-input-mode: its first, third and fourth fields.
  win32Params = csiFields {
    "0:0" = "vk";
    "2:0" = "uc";
    "3:0" = "kd";
  } false;

  orZero = v: if v == null then 0 else v;

  # The events of a complete CSI of the win32-input-mode with the parameter bytes params,
  # no intermediate and the final byte f: [ { key; type; } ] or [ ] when it is dropped.
  win32Events =
    params: f:
    let
      p = win32Params params;
      kd = orZero p.kd;
      key = win32Key (orZero p.vk) (orZero p.uc);
    in
    if f != 95 || p == null || key == null || (kd != 0 && kd != 1) then
      [ ]
    else
      [
        {
          inherit key;
          type = if kd == 1 then typePress else typeRelease;
        }
      ];

  # The events of bytes with the CSI without intermediates read by csiEvents (params -> f
  # -> events) and everything else as in decodeKitty.
  decodeEvents =
    csiEvents: bytes:
    let
      n = length bytes;

      token =
        i:
        let
          b = elemAt bytes i;
        in
        if b == 27 then escape i else emit (tap (plainKey b)) (i + 1);

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
            (if i + 2 >= n then truncated else emit [ ] (i + 3))
          else
            emit [ ] (i + 1);

      csi =
        i:
        let
          e = csiEnd bytes i;
          k = e.final;
          f = elemAt bytes k;
        in
        if k >= n then
          truncated
        else if f >= 64 && f <= 126 then
          emit (
            if k == e.afterParams then csiEvents (genList (j: elemAt bytes (i + 2 + j)) (k - i - 2)) f else [ ]
          ) (k + 1)
        else
          emit [ ] k;
    in
    scan n (tokensOf token n);

  decodeKittyMarked = decodeEvents kittyEvents;

  decodeWin32 = decodeEvents win32Events;

  # decodeKittyMarked without the mark `explicit` of its events.
  decodeKitty =
    bytes:
    let
      d = decodeKittyMarked bytes;
    in
    d // { keys = map (e: { inherit (e) key type; }) d.keys; };

  without = k: builtins.filter (x: x != k);

  # One event of a read applied to { held; carried; fresh; events; } (see the header).
  kittyStep =
    s: e:
    let
      k = e.key;
      isHeld = builtins.elem k s.held;
    in
    if e.type == typeRelease then
      if !isHeld then
        s
      else if builtins.elem k s.fresh then
        s // { carried = without k s.carried ++ [ k ]; }
      else
        s
        // {
          held = without k s.held;
          events = s.events ++ [ (release k) ];
        }
    else if isHeld then
      s // { carried = without k s.carried; }
    else
      s
      // {
        held = s.held ++ [ k ];
        fresh = s.fresh ++ [ k ];
        events = s.events ++ [ (press k) ];
      };

  # The events decoded with decodeWith from the part of text after consumed (from the
  # front when the text got shorter), and the count of bytes consumed after them.
  readFresh =
    decodeWith: consumed: text:
    let
      from = if stringLength text < consumed then 0 else consumed;
      fresh = bytesOfText (substring from (stringLength text - from) text);
      d = decodeWith fresh;
    in
    {
      inherit (d) keys;
      consumed = from + length fresh - d.rest;
    };

  # The presses and releases of the reported events of one read, from the key state
  # { held; carried; } (see the header): { held; carried; events; }.
  reportedPolled =
    state: decoded:
    let
      start = {
        held = builtins.filter (k: !(builtins.elem k state.carried)) state.held;
        carried = [ ];
        fresh = [ ];
        events = map release state.carried;
      };
    in
    foldl' (
      s: e:
      let
        s' = kittyStep s e;
      in
      builtins.deepSeq s' s'
    ) start decoded;

  pollKitty =
    state: text:
    let
      d = readFresh decodeKittyMarked state.consumed text;
      reported = reportedPolled state d.keys;

      # A terminal is trusted to report releases from the first release it reports.
      trusted =
        (state.trusted or false) || builtins.any (e: e.type == typeRelease && (e.explicit or false)) d.keys;

      # Until then releases are made up as in poll: the keys pressed in this read are
      # pressed (again), the keys held before and not pressed now are released.
      now = unique (map (e: e.key) (builtins.filter (e: e.type != typeRelease) d.keys));
      madeUp = {
        held = now;
        carried = [ ];
        events = map press now ++ map release (builtins.filter (k: !(builtins.elem k now)) state.held);
      };

      r = if trusted then reported else madeUp;
    in
    {
      state = {
        inherit (d) consumed;
        inherit (r) held carried;
        inherit trusted;
      };
      inherit (r) events;
    };

  pollWin32 =
    state: text:
    let
      d = readFresh decodeWin32 state.consumed text;
      r = reportedPolled state d.keys;
    in
    {
      state = {
        inherit (d) consumed;
        inherit (r) held carried;
      };
      inherit (r) events;
    };
in
{
  inherit
    ord
    decode
    decodeFinal
    poll
    decodeKitty
    pollKitty
    decodeWin32
    pollWin32
    ;
}
