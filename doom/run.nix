# The driver of a linked doomgeneric (doom/link.nix), or of any linked program with the
# same entry points, on the host of cc/host.nix.
#
#   import ./run.nix { linked; args; ticks; readKeys; onTick; init; tics ? 0; view ? null;
#                      keyProto ? "legacy"; }
#     -> { mem; last; frameCount; acc; msOfTic; }
#
# linked    the result of a link with doomgeneric_Create (argc, argv), doomgeneric_Tick
#           (no arguments), both returning void, and __init; with tics > 5 also
#           TryRunTics (no arguments, returning void), else a throw. When its
#           __data.symbols has both DG_ScreenBuffer and I_VideoBuffer (and fb_scaling is
#           1 or absent), the driver sets the pointer DG_ScreenBuffer to the value of
#           I_VideoBuffer after doomgeneric_Create (see aliasScreen below)
# args      the argv strings; the strings go from 0x00100000, each ended by NUL (at
#           most 4096 bytes in all, NULs included, else a throw), and the array of
#           their addresses, ended by 0, to 0x00101000, below the data area
# ticks     the number of calls of doomgeneric_Tick (the ticks)
# tics      the tics of Doom to run per tick, a non-negative integer (else a throw).
#           With 0 the driver never touches the virtual clock mem.host.ms, which only
#           doomgeneric's DG_SleepMs advances: TryRunTics of d_loop.c then sleeps until a
#           tic has passed and builds it at one tick and runs it at the next, so a tic
#           runs at every other tick. With N >= 1, at each tick, after the key events are
#           put in mem.host.keys, the driver moves the clock forward to tic boundaries
#           (see advance below) so that Doom runs exactly N tics and then draws once.
#           Tics that Doom's own DG_SleepMs crossed since the previous tick (the screen
#           wipe sleeps until each tic) have passed too, and the first call of the tick
#           runs them as well, up to 5 tics in that call. -timedemo (singletics) ignores
#           the clock and runs one tic per call of TryRunTics: one per tick with N <= 5,
#           and ceil(N / 5) per tick above
# readKeys  tick -> the whole text of the key file just before that tick, or null for
#           no input; before a tick at which no key event is pending (mem.host.keys is
#           empty) the text is polled with doom/keys.nix (see keyProto) and the events
#           are put in mem.host.keys; while events are pending, readKeys is not called and
#           the key state is kept, so the bytes not read are decoded together at the next
#           poll.
#           With tics = 0 doomgeneric takes key events only at every other tick:
#           polling at every tick would queue the release of a single press with the
#           press itself, and the two would cancel out in one take. With tics >= 1 Doom
#           takes key events at each of the N tics of a tick (I_GetEvent, up to and
#           including the first release), so the queue is empty after a tick unless more
#           releases were queued than N, and the file is read before nearly every tick;
#           a single press stays held for the N tics of its tick and its release, made up
#           (legacy) or put off (kitty) by the next poll, comes at the first tic of the
#           next tick
# keyProto  how the key file is decoded, the same for both as to when it is polled:
#           "legacy" (the default; poll of doom/keys.nix, for a terminal in its usual
#           mode, with made-up releases) or "kitty" (pollKitty, for a terminal in the
#           kitty keyboard protocol: the presses and releases the terminal reports, the
#           release of a key pressed and released between two polls put off to the next
#           poll; until the terminal reports its first release, the releases are made up
#           as in legacy mode); anything else is a throw
# view      null, which leaves Doom's view window alone, or the screen size (blocks) of
#           the view window, an integer from 3 to 10 (else a throw): after
#           doomgeneric_Create the driver sets it as the menu would (see setView below),
#           which needs R_SetViewSize (blocks, detail, returning void) and the variables
#           screenblocks and detailLevel in the link, else a throw
# onTick    { tick; frames; out; events; } -> acc -> acc, called after
#           doomgeneric_Create (tick 0) and after each tick with the frame records drawn
#           in it (scaffold/platform.nix), the guest output added in it and the key
#           events put in mem.host.keys before it ([ ] at tick 0 and at a tick without a
#           poll); init is the first acc
#
# After each tick the host fields frames and out are emptied, so no frame record is kept
# from one tick to the next. The state carried over (the memory, the key state, acc and
# the last frame record) is forced at every tick, acc and the last frame record to weak
# head normal form: an onTick that keeps values computed from the frames forces them
# itself. The text of readKeys is forced before the tick and onTick is forced after it,
# so the output of onTick (builtins.trace) comes out in tick order during the evaluation.
#
# mem is the final memory, last the last frame record drawn (tick 0 included) or null,
# frameCount the number of frames drawn (tick 0 included) and acc the final acc. With
# ticks = 0 only doomgeneric_Create runs. msOfTic k is the least ms at which the tic
# count of I_GetTime is k, basetime included (see below), exposed for the tests.
{
  linked,
  args,
  ticks,
  readKeys,
  onTick,
  init,
  tics ? 0,
  view ? null,
  keyProto ? "legacy",
}:
let
  M = import ../lib/mem.nix;
  A = import ../lib/ascii.nix;
  Keys = import ./keys.nix;
  inherit (builtins)
    concatLists
    deepSeq
    div
    elemAt
    foldl'
    genList
    isInt
    length
    seq
    ;

  stringsBase = 1048576; # 0x00100000
  argvAddr = 1052672; # 0x00101000
  stringsLimit = argvAddr - stringsBase;

  # The bytes of each argument, ended by NUL.
  argBytes = map (s: A.bytesOf s ++ [ 0 ]) args;

  # The address of each argument string, then 0.
  argPointers =
    (foldl'
      (acc: bs: {
        at = acc.at + length bs;
        list = acc.list ++ [ acc.at ];
      })
      {
        at = stringsBase;
        list = [ ];
      }
      argBytes
    ).list
    ++ [ 0 ];

  # mem with the argument strings and the argv array.
  placeArgs =
    mem:
    let
      bytes = concatLists argBytes;
      n = length bytes;
      withStrings = M.storeRun mem stringsBase n bytes;
    in
    if n > stringsLimit then
      throw "doom: run: the arguments take ${toString n} bytes, more than ${toString stringsLimit}"
    else
      foldl' (m: i: M.storeWord m (argvAddr + 4 * i) (elemAt argPointers i)) withStrings (
        genList (i: i) (length argPointers)
      );

  # The state s with its fields forced (see the header).
  forced =
    s: seq s.mem (seq s.mem.host (seq s.mem.host.keys (deepSeq s.keyState (seq s.last (seq s.acc s)))));

  # The state after handing the frames and output in the host state of mem to onTick and
  # emptying them; st holds the key state, acc and the last frame record before.
  drain =
    tick: events: st: mem:
    let
      host = mem.host;
      inherit (host) frames;
    in
    forced {
      mem = mem // {
        host = host // {
          frames = [ ];
          out = "";
        };
      };
      inherit (st) keyState;
      last = if frames == [ ] then st.last else elemAt frames (length frames - 1);
      acc = onTick {
        inherit tick frames events;
        inherit (host) out;
      } st.acc;
    };

  # The memory and key state after polling the key file before tick, when no key event is
  # pending (see the header); the text is read before either is used.
  deliver =
    st: tick:
    let
      text = if st.mem.host.keys == [ ] then readKeys tick else null;
      polled =
        if text == null then
          {
            state = st.keyState;
            events = [ ];
          }
        else
          protocol.poll st.keyState text;
      host = st.mem.host;
    in
    deepSeq polled {
      mem = st.mem // {
        host = host // {
          keys = host.keys ++ polled.events;
        };
      };
      keyState = polled.state;
      inherit (polled) events;
    };

  # The first nonzero value Doom reads from the clock, which I_GetTime of i_timer.c
  # subtracts from every reading. The virtual clock starts at 0 and Doom reads it first
  # right after its first sleep of 1 ms during startup, so the value is 1. If that no longer
  # holds, only the tick after doomgeneric_Create runs one tic more or less than the
  # others; the later ticks are right, since the driver reads the clock back.
  basetime = 1;

  # The tic count of I_GetTime of i_timer.c at ms milliseconds: (ms - basetime) * 35 / 1000.
  ticAt = ms: div ((ms - basetime) * 35) 1000;

  # The least ms at which ticAt is k: the k-th tic boundary, computed from k alone so
  # that no rounding of 1000 / 35 ms per tic adds up.
  msOfTic = k: basetime + div (1000 * k + 34) 35;

  # The tics one call of TryRunTics of d_loop.c runs for sure when the clock has moved
  # that many tics past the last call. doomgeneric syncs as vanilla Doom does (new_sync
  # is 0, in the branch of D_StartNetGame without ORIGCODE) with ticdup 1. NetUpdate
  # builds one tic per tic passed, but BuildNewTic refuses once maketic is 5 ahead of
  # gametic, and the tics refused are lost because lasttime has already moved. From the
  # state a call leaves (no built tic waiting, or one, as after a waiting call), k <= 5
  # passed tics make realtics k and availabletics k, or k + 1 when k < 5, so counts is k
  # and the k tics run with no wait. A sixth passed tic would be refused and lost.
  ticsPerCall = 5;

  # The sizes of the runs of one tick: full runs of ticsPerCall, then the rest.
  runSizes =
    let
      n = div (tics + ticsPerCall - 1) ticsPerCall;
    in
    genList (i: if i < n - 1 then ticsPerCall else tics - ticsPerCall * (n - 1)) n;

  # mem with the clock at the boundary k tics past the tic count of its clock. The count
  # is read from the clock itself, which Doom also advances (DG_SleepMs), so the clock
  # never moves back.
  advance =
    k: mem:
    mem
    // {
      host = mem.host // {
        ms = msOfTic (ticAt mem.host.ms + k);
      };
    };

  tryRunTics =
    linked.TryRunTics
      or (throw "doom: run: tics = ${toString tics} needs TryRunTics in the link, to run more than ${toString ticsPerCall} tics in a tick");

  checkedTics =
    if !(isInt tics) || tics < 0 then
      throw "doom: run: tics is not a non-negative integer: ${builtins.toJSON tics}"
    else if tics > ticsPerCall then
      seq tryRunTics tics
    else
      tics;

  # The memory after one tick: with tics >= 1, every run but the last advances the clock
  # and calls TryRunTics, and the last advances it and calls doomgeneric_Tick, which
  # runs its tics and draws. Frame records drawn by any call stay in mem.host.frames.
  runTick =
    mem:
    if tics == 0 then
      linked.doomgeneric_Tick mem
    else
      let
        last = length runSizes - 1;
        before = foldl' (m: i: tryRunTics (advance (elemAt runSizes i) m)) mem (genList (i: i) last);
      in
      linked.doomgeneric_Tick (advance (elemAt runSizes last) before);

  step =
    st: tick:
    let
      d = deliver st tick;
    in
    drain tick d.events (st // { inherit (d) keyState; }) (runTick d.mem);

  inherit (linked.__data) symbols;

  # mem with the pointer DG_ScreenBuffer set to the value of I_VideoBuffer, when the link
  # has both variables (doomgeneric does; otherwise mem as it is). I_FinishUpdate of
  # doomgeneric's i_video.c copies the screen Doom draws on, I_VideoBuffer, to
  # DG_ScreenBuffer row by row with memcpy, 200 copies of 320 bytes per frame (CMAP256
  # with RESX 320 and RESY 200 gives 8 bits per pixel and fb_scaling 1, so every offset
  # is 0 and the copy is 1:1). With both pointers equal every copy has dst == src, which
  # the libc returns at once (copyMem in lib/libc.nix), and DG_DrawFrame reads the same
  # bytes the copy would have written. The values are final after doomgeneric_Create:
  # doomgeneric.c sets DG_ScreenBuffer only there (a malloc, before D_DoomMain), and
  # I_VideoBuffer is set only by I_InitGraphics (a Z_Malloc with PU_STATIC, never purged),
  # which D_DoomLoop calls at the end of D_DoomMain on every path; Z_Free in
  # I_ShutdownGraphics runs only on quitting. The frame Create itself draws is copied as
  # before. The 1:1 copy needs fb_scaling 1: with another value (a -scaling argument)
  # I_FinishUpdate writes fb_scaling times as many bytes and would write past I_VideoBuffer.
  # When the link also has fb_scaling (set by I_InitGraphics, inside doomgeneric_Create),
  # the pointer is set only when its value is 1, and any other value keeps the buffers apart.
  aliasScreen =
    mem:
    if
      symbols ? DG_ScreenBuffer
      && symbols ? I_VideoBuffer
      && (!(symbols ? fb_scaling) || M.loadWord mem symbols.fb_scaling == 1)
    then
      M.storeWord mem symbols.DG_ScreenBuffer (M.loadWord mem symbols.I_VideoBuffer)
    else
      mem;

  # The parts of the link that setView uses, or a throw that names them.
  viewParts =
    if linked ? R_SetViewSize && symbols ? screenblocks && symbols ? detailLevel then
      linked.R_SetViewSize
    else
      throw "doom: run: view = ${toString view} needs the function R_SetViewSize and the variables screenblocks and detailLevel in the link";

  checkedView =
    if isInt view && view >= 3 && view <= 10 then
      view
    else
      throw "doom: run: view is neither null nor an integer from 3 to 10: ${builtins.toJSON view}";

  # mem with the view window of Doom set to the screen size view (blocks), as the menu
  # does with the - and = keys (M_SizeDisplay of m_menu.c): screenblocks and the menu's
  # screenSize (blocks - 3, when the link has it) are written and R_SetViewSize is called
  # with the current detailLevel; it only records the request, which the next D_Display
  # carries out with R_ExecuteSetViewSize. Nothing overwrites the setting later: in
  # d_main.c, M_LoadDefaults (the configuration file), M_Init (screenSize from
  # screenblocks), R_Init (R_SetViewSize of the defaults) and the R_ExecuteSetViewSize of
  # D_DoomLoop all run inside doomgeneric_Create, and afterwards only the menu calls
  # R_SetViewSize and writes screenblocks (M_SizeDisplay, M_ChangeDetail), so a size the
  # player picks with - and = stays in effect. With view = null mem is left as it is.
  setView =
    mem:
    if view == null then
      mem
    else
      let
        blocks = checkedView;
        setSize = viewParts;
        withBlocks = M.storeWord mem symbols.screenblocks blocks;
        withSize =
          if symbols ? screenSize then M.storeWord withBlocks symbols.screenSize (blocks - 3) else withBlocks;
      in
      setSize withSize blocks (M.loadWord mem symbols.detailLevel);

  created = setView (
    aliasScreen (linked.doomgeneric_Create (placeArgs (linked.__init M.empty)) (length args) argvAddr)
  );

  # The poll of each key protocol and its key state before the first poll.
  protocols = {
    legacy = {
      inherit (Keys) poll;
      start = {
        consumed = 0;
        stalled = 0;
        held = [ ];
      };
    };
    kitty = {
      poll = Keys.pollKitty;
      start = {
        consumed = 0;
        held = [ ];
        carried = [ ];
        trusted = false;
      };
    };
  };

  protocol =
    protocols.${keyProto}
      or (throw "doom: run: keyProto is neither \"legacy\" nor \"kitty\": ${builtins.toJSON keyProto}");

  start = drain 0 [ ] {
    keyState = protocol.start;
    acc = init;
    last = null;
  } created;

  # foldl' does not force its initial value, so start (doomgeneric_Create and the onTick of
  # tick 0) is forced here, before the key file is read for tick 1. tics and keyProto are
  # checked first.
  final = seq checkedTics (seq protocol (seq start (foldl' step start (genList (i: i + 1) ticks))));
in
{
  inherit (final) mem last acc;
  inherit msOfTic;
  frameCount = final.mem.host.frameCount;
}
