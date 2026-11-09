# Memory-layout benchmark: compares persistent trie layouts for the memory of the
# emulator at the memory-interface level (no CPU). The layouts live in
# bench/memlayouts/ and expose the same interface as lib/mem.nix.
#
# Usage (one evaluation per cell, from the repository root; take the median of
# 3 runs; cpuTime is read from the stats file, max RSS is printed by time):
#   NIX_SHOW_STATS=1 NIX_SHOW_STATS_PATH=/tmp/memlayout.json \
#     /run/current-system/sw/bin/time -f '%M KiB maxrss' \
#     nice -n 19 taskset -c 0-15 nix eval -f bench/memlayout.nix result \
#       --argstr layout l3 --argstr workload wide --arg ops 200000
#   jq '{cpuTime, heap: .gc.heapSize, gc: .time.gc}' /tmp/memlayout.json
#
# Correctness cross-check of every layout against lib/mem.nix (prints "ok"):
#   nice -n 19 taskset -c 0-15 nix eval --raw -f bench/memlayout.nix check
#
# Full emulator benchmark with another layout: in a scratch copy of the
# repository (never in the repository itself), replace lib/mem.nix with a
# one-line import of the layout, then run the usual budget measurement:
#   echo "import $PWD/bench/memlayouts/l4w.nix" > /tmp/copy/lib/mem.nix
#   cd /tmp/copy && NIX_SHOW_STATS=1 NIX_SHOW_STATS_PATH=/tmp/emu.json \
#     nice -n 19 taskset -c 0-15 nix eval -f . bench.run
#   NIX_SHOW_STATS_PATH=/tmp/emu.json nice -n 19 taskset -c 0-15 nix eval --raw -f . bench.report
#
# Maximum RSS under the default GC settings is dominated by the initial GC heap
# (about 450 MiB once a run allocates enough, even for the null layout). To
# compare the size of the retained trie, run `fill` with GC_INITIAL_HEAP_SIZE=8M.
#
# Arguments:
#   layout   : l5 (lib/mem.nix), l3, l4, l4w, or null (no memory; measures the
#              loop and address arithmetic, to be subtracted as a baseline)
#   workload : narrow   - `ops` word stores, then `ops` word loads, cycling over 4 KB
#              wide     - the same, at pseudo-random word addresses over 6 MiB,
#                         starting from empty memory
#              fill     - one word store to every word of the 6 MiB region
#              frame    - fill, then `ops` sequential word stores and `ops` loads
#                         over a 64 KB buffer inside the region (framebuffer-like);
#                         its cost per operation is (frame - fill) / (2 * ops)
#              widefull - fill, then the wide workload on the populated region;
#                         its cost per operation is (widefull - fill) / (2 * ops)
#   ops      : number of stores (and of loads), default 200000 (`--arg ops N`)
#   loads    : false skips the load phase (`--arg loads false`), to separate the
#              store cost from the load cost
#
# Stores and loads go through storeWord / loadWord with word-aligned byte
# addresses, which is the path taken by the emulator's SW and LW.
{
  layout ? "l5",
  workload ? "narrow",
  ops ? 200000,
  loads ? true,
}:
let
  inherit (builtins)
    foldl'
    genList
    bitAnd
    div
    seq
    elemAt
    length
    ;

  mask32 = 4294967295;

  # A layout with no memory: stores return the memory unchanged and loads return 0,
  # but both still force their address and value, as the real layouts do.
  nullLayout = {
    empty = 0;
    storeWord =
      m: a: v:
      seq a (seq v m);
    loadWord = m: a: seq a 0;
  };

  layouts = {
    l5 = import ./memlayouts/l5.nix;
    l3 = import ./memlayouts/l3.nix;
    l4 = import ./memlayouts/l4.nix;
    l4w = import ./memlayouts/l4w.nix;
    null = nullLayout;
  };

  M = layouts.${layout} or (throw "unknown layout ${layout}");

  # foldl' f init [0 .. n-1], generated in chunks of 1024 so that no list of n
  # elements is ever held (keeps the maximum RSS dominated by the memory trie).
  forN =
    n: f: init:
    let
      chunk = 1024;
      chunks = div (n + chunk - 1) chunk;
      inner =
        acc: j:
        let
          lo = j * chunk;
          len = if n - lo < chunk then n - lo else chunk;
        in
        foldl' f acc (genList (k: lo + k) len);
    in
    foldl' inner init (genList (j: j) chunks);

  # --- Address streams (byte addresses, word-aligned) ---
  narrowBase = 65536;
  narrowAddr = i: narrowBase + 4 * bitAnd i 1023;

  # The 6 MiB region assumed as Doom's working set.
  regionBase = 1048576;
  regionWords = 1572864;

  # Multiplicative hash of i (upper 21 of 32 bits), reduced to a word of the region.
  wideAddr =
    i:
    regionBase
    +
      4
      * (
        let
          h = div (bitAnd (i * 2654435761) mask32) 2048;
        in
        h - div h regionWords * regionWords
      );

  # 64 KB framebuffer inside the region, written and read sequentially.
  frameBase = regionBase + 4194304;
  frameAddr = i: frameBase + 4 * bitAnd i 16383;

  # --- Phases ---
  storeAll = addr: m0: forN ops (m: i: M.storeWord m (addr i) i) m0;
  # Loads visit the stored addresses in reverse order.
  loadAll = addr: m: forN ops (acc: i: bitAnd (acc + M.loadWord m (addr (ops - 1 - i))) mask32) 0;

  storeLoad =
    addr: m0:
    let
      m1 = storeAll addr m0;
    in
    if loads then loadAll addr m1 else seq m1 0;

  filled = forN regionWords (m: i: M.storeWord m (regionBase + 4 * i) i) M.empty;
  # Depend on a few words so that the result requires the whole fill. The seq makes
  # the null layout run its fill loop too, since its loads ignore the memory.
  filledChecksum =
    m:
    seq m (
      foldl' (acc: a: acc + M.loadWord m a) 0 [
        regionBase
        (regionBase + 4 * (regionWords - 1))
        frameBase
      ]
    );

  workloads = {
    narrow = storeLoad narrowAddr M.empty;
    wide = storeLoad wideAddr M.empty;
    fill = filledChecksum filled;
    frame = seq filled (storeLoad frameAddr filled);
    widefull = seq filled (storeLoad wideAddr filled);
  };

  # --- Correctness cross-check ---
  # A deterministic mix of byte, half and word stores (aligned and unaligned,
  # including the top of the address space and a page boundary), then every
  # accessor is compared against lib/mem.nix.
  checkOps = genList (i: {
    kind = bitAnd i 3;
    a = elemAt checkAddrs (bitAnd (i * 7) 15) + bitAnd (div i 4) 7;
    v = bitAnd (i * 2654435761 + 12345) mask32;
  }) 400;
  checkAddrs = [
    0
    4092
    16380
    16384
    65536
    1048572
    1048576
    4194300
    16777212
    16777216
    67108860
    67108864
    268435452
    2147483644
    4294967280
    4294967288
  ];
  applyOps =
    L:
    foldl' (
      m: o:
      if o.kind == 0 then
        L.storeByte m o.a o.v
      else if o.kind == 1 then
        L.storeHalf m o.a o.v
      else
        L.storeWord m o.a o.v
    ) L.empty checkOps;
  probe = genList (
    i: elemAt checkAddrs (div i 24) + bitAnd i 15 - (if elemAt checkAddrs (div i 24) == 0 then 0 else 4)
  ) (24 * length checkAddrs);
  observe =
    L:
    let
      m = applyOps L;
    in
    map (a: [
      (L.loadByte m a)
      (L.loadHalf m a)
      (L.loadWord m a)
      (L.loadWordAt m (div a 4))
    ]) (builtins.filter (a: a >= 0 && a <= mask32 - 3) probe);
  reference = observe layouts.l5;
  check =
    let
      bad = builtins.filter (n: observe layouts.${n} != reference) [
        "l3"
        "l4"
        "l4w"
      ];
    in
    if bad == [ ] then "ok" else throw "layouts disagree with lib/mem.nix: ${toString bad}";
in
{
  result = workloads.${workload} or (throw "unknown workload ${workload}");
  inherit check;
}
