# Benchmark: cost of loading a WAD-sized binary (hex text) in pure Nix evaluation.
#
# Usage (one evaluation per method and size; HEXLOAD_FILE is a continuous lowercase hex file):
#   head -c 4194304 /dev/urandom | od -An -v -tx1 | tr -d ' \n' > /tmp/wad4m.hex
#   export HEXLOAD_FILE=/tmp/wad4m.hex
#   HEXLOAD_METHOD=image NIX_SHOW_STATS=1 NIX_SHOW_STATS_PATH=/tmp/stats.json \
#     command time -f '%M KiB maxrss' nix eval -f bench/hexload.nix full
#   HEXLOAD_METHOD=image NIX_SHOW_STATS=1 NIX_SHOW_STATS_PATH=/tmp/stats.json \
#     command time -f '%M KiB maxrss' nix eval -f bench/hexload.nix scatter
#   jq '{cpuTime, heap: .gc.heapSize}' /tmp/stats.json
#
# HEXLOAD_METHOD is one of: image, list, words (full only), mem (full only).
# Attributes: `full` (read every byte/word once and fold a checksum, including decoding),
# `scatter` (10,000 scattered byte reads, including any decoding), `methods` (all of them).
let
  M = import ../lib/mem.nix;
  inherit (builtins)
    substring
    stringLength
    genList
    foldl'
    listToAttrs
    elemAt
    div
    bitAnd
    getEnv
    readFile
    ;

  file = getEnv "HEXLOAD_FILE";
  method = getEnv "HEXLOAD_METHOD";
  hex = readFile file;
  size = div (stringLength hex) 2;
  nWords = div size 4;

  hexDigit = i: substring i 1 "0123456789abcdef";
  byteTable = listToAttrs (
    genList (n: {
      name = hexDigit (div n 16) + hexDigit (bitAnd n 15);
      value = n;
    }) 256
  );
  byte = off: byteTable.${substring (2 * off) 2 hex};

  # Order-sensitive 32-bit checksum.
  mix = acc: v: bitAnd (acc * 31 + v) 4294967295;

  # 10,000 scattered offsets (the stride is coprime to any power-of-two size).
  offsets = genList (i: bitAnd (i * 104729 + 13) (size - 1)) 10000;

  # (a) lazy image accessor, as mkImage in lib/elf.nix.
  image = {
    full = foldl' (acc: i: mix acc (byte i)) 0 (genList (i: i) size);
    scatter = foldl' (acc: o: mix acc (byte o)) 0 offsets;
  };

  # (b) eager decode into a list of bytes.
  bytes = genList byte size;
  list = {
    full = foldl' mix 0 bytes;
    scatter = foldl' (acc: o: mix acc (elemAt bytes o)) 0 offsets;
  };

  # (c) list of 32-bit little-endian words (the hex text is already byte-ordered).
  wordAt =
    i:
    let
      s = substring (8 * i) 8 hex;
      b = k: byteTable.${substring (2 * k) 2 s};
    in
    b 0 + 256 * b 1 + 65536 * b 2 + 16777216 * b 3;
  words = genList wordAt nWords;
  wordsM = {
    full = foldl' mix 0 words;
  };

  # (d) load every word into the memory trie, then read back a few words.
  trie = foldl' (m: i: M.storeWordAt m i (wordAt i)) M.empty (genList (i: i) nWords);
  mem = {
    full = mix (M.loadWordAt trie 0) (M.loadWordAt trie (nWords - 1));
  };

  methods = {
    inherit image list mem;
    words = wordsM;
  };
in
{
  inherit methods;
  full = methods.${method}.full;
  scatter = methods.${method}.scatter;
}
