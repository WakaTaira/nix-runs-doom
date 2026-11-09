# Cross-compile doomgeneric for the RV32IM emulator with clang + lld (the scaffold).
# This is a build-only derivation: the evaluation side never refers to it and reads
# its hex output from ./result-doom (see `nix build .#doom-scaffold -o result-doom`).
#
# libc and the doomgeneric platform layer (DG_*) are host calls: the C headers and the
# ecall stubs are generated here from the table in lib/hostcall.nix, and nothing
# generated is kept in the repository. The doomgeneric sources are used unpatched.
#
# Output:
#   $out/doom.elf  the ELF executable (symbols kept)
#   $out/doom.hex  hex text of the ELF (the format lib/elf.nix reads)
#   $out/doom.dis  disassembly listing for debugging
{ pkgs, doomgeneric }:
let
  inherit (pkgs) lib;
  H = import ../lib/hostcall.nix;
  src = "${doomgeneric}/doomgeneric";

  # The standard object list of doomgeneric's Makefile (SRC_DOOM), without the
  # platform files doomgeneric_<platform>.c; DG_* come from the host-call stubs.
  makefileObjects =
    let
      lines = lib.splitString "\n" (builtins.readFile "${src}/Makefile");
      srcLine = lib.findFirst (
        l: lib.hasPrefix "SRC_DOOM = " l
      ) (throw "SRC_DOOM not found in Makefile") lines;
      words = lib.filter (w: w != "") (lib.splitString " " (lib.removePrefix "SRC_DOOM = " srcLine));
    in
    lib.filter (w: builtins.match "doomgeneric_.*" w == null) words;
  doomSources = map (o: lib.removeSuffix ".o" o + ".c") makefileObjects;

  include = pkgs.linkFarm "doom-hostcall-include" (
    lib.mapAttrsToList (file: text: {
      name = file;
      path = pkgs.writeText (baseNameOf file) text;
    }) H.headerFiles
  );

  # Replaces the main() of the excluded platform files: create, then tick forever.
  mainC = ''
    #include "doomgeneric.h"

    int main(int argc, char **argv)
    {
        doomgeneric_Create(argc, argv);
        for (;;)
            doomgeneric_Tick();
    }
  '';

  # .text is its own executable PT_LOAD; read-only data, data and bss share a
  # second, non-executable one. _end marks the final load address.
  linkerScript = ''
    ENTRY(_start)
    PHDRS
    {
      text PT_LOAD FLAGS(5);
      data PT_LOAD FLAGS(6);
    }
    SECTIONS
    {
      . = 0x10000;
      .text : { *(.text.start) *(.text*) } :text
      . = ALIGN(0x1000);
      .rodata : { *(.rodata*) *(.srodata*) } :data
      .data : { *(.data*) *(.sdata*) } :data
      .bss : { *(.sbss*) *(.bss*) *(COMMON) } :data
      _end = .;
    }
  '';

  generated = pkgs.linkFarm "doom-hostcall-src" [
    {
      name = "start.S";
      path = pkgs.writeText "start.S" H.startAsm;
    }
    {
      name = "hostcall_stubs.S";
      path = pkgs.writeText "hostcall_stubs.S" H.stubsAsm;
    }
    {
      name = "hostcall_varargs.c";
      path = pkgs.writeText "hostcall_varargs.c" H.stubsC;
    }
    {
      name = "main.c";
      path = pkgs.writeText "main.c" mainC;
    }
    {
      name = "link.ld";
      path = pkgs.writeText "link.ld" linkerScript;
    }
  ];

  cflags = [
    "--target=riscv32-unknown-elf"
    "-march=rv32im"
    "-mabi=ilp32"
    "-O2"
    "-ffreestanding"
    "-fno-builtin"
    "-nostdlib"
    "-DCMAP256"
    "-DDOOMGENERIC_RESX=320"
    "-DDOOMGENERIC_RESY=200"
    "-I${include}"
    "-I${src}"
  ];
in
pkgs.runCommand "doom-scaffold"
  {
    nativeBuildInputs = [
      pkgs.llvmPackages.clang-unwrapped
      pkgs.llvmPackages.bintools-unwrapped
      pkgs.lld
    ];
  }
  ''
    mkdir -p obj $out
    # -w: the unpatched upstream sources produce a flood of warnings.
    compile() {
      clang ${lib.escapeShellArgs cflags} -w -c "$1" -o "obj/$(basename "$1").o"
    }
    export -f compile
    printf '%s\n' \
      ${lib.escapeShellArgs (map (f: "${src}/${f}") doomSources)} \
      ${generated}/main.c ${generated}/hostcall_varargs.c \
      ${generated}/hostcall_stubs.S ${generated}/start.S \
      | xargs -P "$NIX_BUILD_CORES" -I{} bash -c 'compile "$1"' _ {}
    clang ${lib.escapeShellArgs cflags} -fuse-ld=lld -Wl,-T,${generated}/link.ld \
      -o $out/doom.elf obj/*.o
    llvm-objdump -d $out/doom.elf > $out/doom.dis
    od -An -v -tx1 $out/doom.elf | tr -d ' \n' > $out/doom.hex
  ''
