# The driver of a linked doomgeneric (doom/link.nix), or of any linked program with the
# same entry points, on the host of cc/host.nix.
#
#   import ./run.nix { linked; args; ticks; readKeys; onTick; init; }
#     -> { mem; last; frameCount; acc; }
#
# linked    the result of a link with doomgeneric_Create (argc, argv), doomgeneric_Tick
#           (no arguments), both returning void, and __init
# args      the argv strings; the strings go from 0x00100000, each ended by NUL (at
#           most 4096 bytes in all, NULs included, else a throw), and the array of
#           their addresses, ended by 0, to 0x00101000, below the data area
# ticks     the number of calls of doomgeneric_Tick
# readKeys  tick -> the whole text of the key file just before that tick, or null for
#           no input; before a tick at which no key event is pending (mem.host.keys is
#           empty) the text is polled with doom/keys.nix and the events are put in
#           mem.host.keys; while events are pending, readKeys is not called and the key
#           state is kept, so the bytes not read are decoded together at the next poll.
#           Under the virtual clock doomgeneric takes key events only at every other
#           tick: polling at every tick would queue the release of a single press with
#           the press itself, and the two would cancel out in one take
# onTick    { tick; frames; out; events; } -> acc -> acc, called after
#           doomgeneric_Create (tick 0) and after each tick with the frame records drawn
#           in it (scaffold/platform.nix), the guest output added in it and the key
#           events put in mem.host.keys before it ([ ] at tick 0 and at a tick without a
#           poll); init is the first acc
#
# After each call the host fields frames and out are emptied, so no frame record is kept
# from one tick to the next. The state carried over (the memory, the key state, acc and
# the last frame record) is forced at every tick, acc and the last frame record to weak
# head normal form: an onTick that keeps values computed from the frames forces them
# itself. The text of readKeys is forced before the tick and onTick is forced after it,
# so the output of onTick (builtins.trace) comes out in tick order during the evaluation.
#
# mem is the final memory, last the last frame record drawn (tick 0 included) or null,
# frameCount the number of frames drawn (tick 0 included) and acc the final acc. With
# ticks = 0 only doomgeneric_Create runs.
{
  linked,
  args,
  ticks,
  readKeys,
  onTick,
  init,
}:
let
  M = import ../lib/mem.nix;
  A = import ../lib/ascii.nix;
  Keys = import ./keys.nix;
  inherit (builtins)
    concatLists
    deepSeq
    elemAt
    foldl'
    genList
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
          Keys.poll st.keyState text;
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

  step =
    st: tick:
    let
      d = deliver st tick;
    in
    drain tick d.events (st // { inherit (d) keyState; }) (linked.doomgeneric_Tick d.mem);

  created = linked.doomgeneric_Create (placeArgs (linked.__init M.empty)) (length args) argvAddr;

  start = drain 0 [ ] {
    keyState = {
      consumed = 0;
      stalled = 0;
      held = [ ];
    };
    acc = init;
    last = null;
  } created;

  # foldl' does not force its initial value, so start (doomgeneric_Create and the onTick of
  # tick 0) is forced here, before the key file is read for tick 1.
  final = seq start (foldl' step start (genList (i: i + 1) ticks));
in
{
  inherit (final) mem last acc;
  frameCount = final.mem.host.frameCount;
}
