# The doomgeneric platform layer (DG_*) as host calls, with the interface of
# lib/libc.nix (world: args: { world; ret; }), for the dispatch of lib/hostcall.nix.
#
#   import ./platform.nix { screenBufferAddr; colorsAddr; }
#     -> { world; impls; }
#
# screenBufferAddr is the address of the pointer variable DG_ScreenBuffer and
# colorsAddr the address of the palette `colors` (256 entries of 4 bytes, in memory
# B, G, R, A), both from the ELF symbol table. `world` holds the initial values of the
# fields this layer adds to the host-call world:
#   ms          virtual clock in milliseconds; only DG_SleepMs advances it
#   frameCount  number of DG_DrawFrame calls
#   frames      one record per DG_DrawFrame, oldest first:
#                 { instrs; screen; palette; }
#               instrs is the instruction count at the call (see `dispatch` in
#               lib/hostcall.nix for its precision), screen the 320x200 palette
#               indices (list of 64000 bytes) and palette 256 { r; g; b; }. screen and
#               palette are read lazily from the memory snapshot taken at the call.
#   keys        the pending key events, oldest first: { pressed; key; } (pressed 0 or 1,
#               key a number of doomkeys.h); DG_GetKey takes them from the front
{ screenBufferAddr, colorsAddr }:
let
  M = import ../lib/mem.nix;
  B = import ../lib/bits.nix;
  inherit (builtins)
    bitAnd
    div
    elemAt
    genList
    head
    seq
    tail
    ;

  width = 320;
  height = 200;
  screenBytes = width * height;

  result = world: ret: { inherit world ret; };
  nothing = world: _: result world 0;

  byteOf = w: k: bitAnd (div w (elemAt [ 1 256 65536 16777216 ] k)) 255;

  # The n bytes at address a; an aligned buffer is read a word at a time.
  readBytes =
    mem: a: n:
    if bitAnd a 3 == 0 && bitAnd n 3 == 0 then
      let
        words = genList (i: M.loadWordAt mem (div a 4 + i)) (div n 4);
      in
      genList (i: byteOf (elemAt words (div i 4)) (bitAnd i 3)) n
    else
      genList (i: M.loadByte mem (a + i)) n;

  # A frame record over the memory snapshot `mem`; the attribute values stay lazy.
  frameOf = mem: instrs: {
    inherit instrs;
    screen = readBytes mem (M.loadWord mem screenBufferAddr) screenBytes;
    palette = genList (
      i:
      let
        w = M.loadWord mem (colorsAddr + 4 * i);
      in
      {
        b = byteOf w 0;
        g = byteOf w 1;
        r = byteOf w 2;
      }
    ) 256;
  };
in
{
  world = {
    ms = 0;
    frameCount = 0;
    frames = [ ];
    keys = [ ];
  };

  impls = {
    DG_Init = nothing;
    DG_SetWindowTitle = nothing;

    DG_DrawFrame =
      world: _:
      let
        instrs = world.count;
      in
      seq instrs (
        result (
          world
          // {
            frameCount = world.frameCount + 1;
            frames = world.frames ++ [ (frameOf world.mem instrs) ];
          }
        ) 0
      );

    DG_SleepMs = world: a: result (world // { ms = world.ms + elemAt a 0; }) 0;

    DG_GetTicksMs = world: _: result world (B.u32 world.ms);

    # Takes the oldest pending key event, writing pressed (a word) and key (a byte) to
    # the two addresses and returning 1, or returns 0 and writes nothing when there is none.
    DG_GetKey =
      world: a:
      if world.keys == [ ] then
        result world 0
      else
        let
          event = head world.keys;
        in
        result (
          world
          // {
            mem = M.storeByte (M.storeWord world.mem (elemAt a 0) event.pressed) (elemAt a 1) event.key;
            keys = tail world.keys;
          }
        ) 1;
  };
}
