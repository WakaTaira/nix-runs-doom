# Host calls: libc, compiler-runtime and doomgeneric platform (DG_*) functions that a
# clang-built guest calls but whose bodies live in the emulator (in Nix).
#
# `table` is the single source of truth. Each element is
#   { name; num; args; ret; variadic ? false; }
# with args/ret drawn from "int", "ptr", "i64" and "void". The guest-side C headers
# and stubs (built only inside toolchain/doom.nix) and the emulator-side dispatch are
# both derived from it.
#
# Calling convention (guest side, standard ilp32 soft-float):
#   - A non-variadic stub leaves its arguments where the caller put them (a0..a5),
#     sets a7 = num and executes ecall. "int" and "ptr" take one register; "i64"
#     (also used for double) takes the next two registers, low word first, with no
#     even-register alignment. At most six argument registers are used.
#   - The result is returned in a0; an "i64" result in a0 (low) and a1 (high).
#   - A variadic stub is C: it calls va_start and passes the va_list (a pointer to the
#     argument save area under ilp32) to the "v"-prefixed entry, whose args are the
#     variadic entry's fixed args followed by one "ptr". In the save area an int
#     takes 4 bytes; long long and double take 8 bytes aligned to 8. The variadic
#     entry's own num is never used by an ecall.
#
# Program entry (`startAsm`): the emulator sets sp = 0x08000000, builds argv on the
# stack and enters _start with a0 = argc, a1 = argv. _start calls main and exits
# with main's return value through the existing a7 = 93 exit call.
let
  inherit (builtins)
    attrNames
    concatStringsSep
    elem
    elemAt
    filter
    foldl'
    genList
    hasAttr
    length
    listToAttrs
    map
    match
    replaceStrings
    toString
    ;

  fn = name: num: args: ret: {
    inherit
      name
      num
      args
      ret
      ;
  };
  vfn =
    name: num: args: ret:
    fn name num args ret // { variadic = true; };

  # Values of the predefined FILE * handles. They are small non-NULL constants so
  # that the host can recognize them without a symbol lookup.
  stdHandles = {
    stdin = 1;
    stdout = 2;
    stderr = 3;
  };

  table = [
    # string.h / strings.h (1000-1099)
    (fn "memset" 1000 [ "ptr" "int" "int" ] "ptr")
    (fn "memcpy" 1001 [ "ptr" "ptr" "int" ] "ptr")
    (fn "memmove" 1002 [ "ptr" "ptr" "int" ] "ptr")
    (fn "strlen" 1003 [ "ptr" ] "int")
    (fn "strcmp" 1004 [ "ptr" "ptr" ] "int")
    (fn "strncmp" 1005 [ "ptr" "ptr" "int" ] "int")
    (fn "strcasecmp" 1006 [ "ptr" "ptr" ] "int")
    (fn "strncasecmp" 1007 [ "ptr" "ptr" "int" ] "int")
    (fn "strcpy" 1008 [ "ptr" "ptr" ] "ptr")
    (fn "strncpy" 1009 [ "ptr" "ptr" "int" ] "ptr")
    (fn "strdup" 1010 [ "ptr" ] "ptr")
    (fn "strchr" 1011 [ "ptr" "int" ] "ptr")
    (fn "strrchr" 1012 [ "ptr" "int" ] "ptr")
    (fn "strstr" 1013 [ "ptr" "ptr" ] "ptr")

    # ctype.h (1100-1199)
    (fn "toupper" 1100 [ "int" ] "int")
    (fn "tolower" 1101 [ "int" ] "int")
    (fn "isspace" 1102 [ "int" ] "int")
    (fn "isprint" 1103 [ "int" ] "int")

    # stdlib.h (1200-1299); atof returns a double
    (fn "atoi" 1200 [ "ptr" ] "int")
    (fn "atof" 1201 [ "ptr" ] "i64")
    (fn "abs" 1202 [ "int" ] "int")
    (fn "malloc" 1203 [ "int" ] "ptr")
    (fn "calloc" 1204 [ "int" "int" ] "ptr")
    (fn "realloc" 1205 [ "ptr" "int" ] "ptr")
    (fn "free" 1206 [ "ptr" ] "void")
    (fn "exit" 1207 [ "int" ] "void")
    (fn "getenv" 1208 [ "ptr" ] "ptr")
    (fn "system" 1209 [ "ptr" ] "int")

    # stdio.h (1300-1399)
    (vfn "printf" 1300 [ "ptr" ] "int")
    (fn "vprintf" 1301 [ "ptr" "ptr" ] "int")
    (vfn "fprintf" 1302 [ "ptr" "ptr" ] "int")
    (fn "vfprintf" 1303 [ "ptr" "ptr" "ptr" ] "int")
    (vfn "snprintf" 1304 [ "ptr" "int" "ptr" ] "int")
    (fn "vsnprintf" 1305 [ "ptr" "int" "ptr" "ptr" ] "int")
    (vfn "sscanf" 1306 [ "ptr" "ptr" ] "int")
    (fn "vsscanf" 1307 [ "ptr" "ptr" "ptr" ] "int")
    (fn "puts" 1308 [ "ptr" ] "int")
    (fn "putchar" 1309 [ "int" ] "int")
    (fn "fopen" 1310 [ "ptr" "ptr" ] "ptr")
    (fn "fclose" 1311 [ "ptr" ] "int")
    (fn "fread" 1312 [ "ptr" "int" "int" "ptr" ] "int")
    (fn "fwrite" 1313 [ "ptr" "int" "int" "ptr" ] "int")
    (fn "fseek" 1314 [ "ptr" "int" "int" ] "int")
    (fn "ftell" 1315 [ "ptr" ] "int")
    (fn "fflush" 1316 [ "ptr" ] "int")
    (fn "remove" 1317 [ "ptr" ] "int")
    (fn "rename" 1318 [ "ptr" "ptr" ] "int")

    # sys/stat.h / unistd.h (1400-1499)
    (fn "mkdir" 1400 [ "ptr" "int" ] "int")
    (fn "isatty" 1401 [ "int" ] "int")
    (fn "usleep" 1402 [ "int" ] "int")

    # doomgeneric platform layer (1500-1599)
    (fn "DG_Init" 1500 [ ] "void")
    (fn "DG_DrawFrame" 1501 [ ] "void")
    (fn "DG_SleepMs" 1502 [ "int" ] "void")
    (fn "DG_GetTicksMs" 1503 [ ] "int")
    (fn "DG_GetKey" 1504 [ "ptr" "ptr" ] "int")
    (fn "DG_SetWindowTitle" 1505 [ "ptr" ] "void")

    # math.h (1600-1699); double travels as "i64"
    (fn "fabs" 1600 [ "i64" ] "i64")

    # Compiler runtime: 64-bit integer division (1700-1709)
    (fn "__divdi3" 1700 [ "i64" "i64" ] "i64")
    (fn "__moddi3" 1701 [ "i64" "i64" ] "i64")
    (fn "__udivdi3" 1702 [ "i64" "i64" ] "i64")
    (fn "__umoddi3" 1703 [ "i64" "i64" ] "i64")

    # Compiler runtime: soft floating point requested by the link (1710-1799);
    # float travels as "int" and double as "i64"
    (fn "__addsf3" 1710 [ "int" "int" ] "int")
    (fn "__mulsf3" 1711 [ "int" "int" ] "int")
    (fn "__divsf3" 1712 [ "int" "int" ] "int")
    (fn "__fixsfsi" 1713 [ "int" ] "int")
    (fn "__floatsisf" 1714 [ "int" ] "int")
    (fn "__extendsfdf2" 1715 [ "int" ] "i64")
    (fn "__truncdfsf2" 1716 [ "i64" ] "int")
    (fn "__ltdf2" 1717 [ "i64" "i64" ] "int")
  ];

  # C type used for an abstract type inside the generated stubs.
  cType = {
    int = "int";
    ptr = "void *";
    i64 = "long long";
    void = "void";
  };

  regWords = t: if t == "i64" then 2 else 1;

  isVariadic = e: e.variadic or false;

  # { "<key e>" = e; } for a list of entries.
  indexBy =
    key: list:
    listToAttrs (
      map (e: {
        name = key e;
        value = e;
      }) list
    );

  # Validation of the table; `checked` is the table itself once every rule holds.
  checked =
    let
      types = attrNames cType;
      badType = e: filter (t: !(elem t types)) (e.args ++ [ e.ret ]) != [ ];
      dup = key: length (attrNames (indexBy key table)) != length table;
      byName = indexBy (e: e.name) table;
      vName = e: "v" + e.name;
      vOk =
        e:
        e.args != [ ]
        && hasAttr (vName e) byName
        && !(isVariadic byName.${vName e})
        && byName.${vName e}.args == e.args ++ [ "ptr" ]
        && byName.${vName e}.ret == e.ret;
      problems =
        map (e: "${e.name}: unknown type") (filter badType table)
        ++ map (e: "${e.name}: void argument") (filter (e: elem "void" e.args) table)
        ++ map (e: "${e.name}: num below 1000") (filter (e: e.num < 1000) table)
        ++ map (e: "${e.name}: more than six argument registers") (
          filter (e: foldl' (n: t: n + regWords t) 0 e.args > 6) table
        )
        ++ map (e: "${e.name}: no fixed argument or no matching v${e.name}") (
          filter (e: isVariadic e && !(vOk e)) table
        )
        ++ (if dup (e: toString e.num) then [ "duplicate num" ] else [ ])
        ++ (if dup (e: e.name) then [ "duplicate name" ] else [ ]);
    in
    if problems == [ ] then
      table
    else
      throw "lib/hostcall.nix: invalid table: ${concatStringsSep "; " problems}";

  # One assembly stub per non-variadic entry. Each lives in its own section and
  # carries symbol type and size so the ELF symbol table lists it as a function.
  asmStub = e: ''
        .section .text.hostcall.${e.name},"ax",@progbits
        .globl ${e.name}
        .type ${e.name}, @function
        .p2align 2
    ${e.name}:
        li a7, ${toString e.num}
        ecall
        ret
        .size ${e.name}, . - ${e.name}
  '';

  params = args: concatStringsSep ", " (if args == [ ] then [ "void" ] else map (t: cType.${t}) args);
  namedParams =
    args: concatStringsSep ", " (genList (i: "${cType.${elemAt args i}} a${toString i}") (length args));
  argNames = args: genList (i: "a${toString i}") (length args);

  # A variadic entry in C: va_start, then call the v-prefixed entry with the va_list.
  # The prototypes use the abstract C types; this translation unit never includes
  # the generated libc headers, so they do not clash with the standard prototypes.
  varStub =
    e:
    let
      last = "a${toString (length e.args - 1)}";
      call = "v${e.name}(${concatStringsSep ", " (argNames e.args ++ [ "ap" ])})";
      isVoid = e.ret == "void";
    in
    ''
      ${cType.${e.ret}} v${e.name}(${params (e.args ++ [ "ptr" ])});
      ${cType.${e.ret}} ${e.name}(${namedParams e.args}, ...)
      {
          __builtin_va_list ap;
          __builtin_va_start(ap, ${last});
          ${if isVoid then "${call};" else "${cType.${e.ret}} r = ${call};"}
          __builtin_va_end(ap);
          ${if isVoid then "" else "return r;"}
      }
    '';

  # The libc headers. `prelude` holds types, macros and objects; `protos` maps a
  # table entry name to its standard C prototype (types matter to the compiler:
  # size_t is unsigned and double is not an integer, which the abstract table types
  # cannot express). Every prototype must name a table entry, and `...` must agree
  # with the entry's variadic flag; the parameter and return types must map onto the
  # entry's args and ret.
  headers = {
    "string.h" = {
      prelude = "#include <stddef.h>";
      protos = {
        memset = "void *memset(void *s, int c, size_t n)";
        memcpy = "void *memcpy(void *dst, const void *src, size_t n)";
        memmove = "void *memmove(void *dst, const void *src, size_t n)";
        strlen = "size_t strlen(const char *s)";
        strcmp = "int strcmp(const char *a, const char *b)";
        strncmp = "int strncmp(const char *a, const char *b, size_t n)";
        strcpy = "char *strcpy(char *dst, const char *src)";
        strncpy = "char *strncpy(char *dst, const char *src, size_t n)";
        strdup = "char *strdup(const char *s)";
        strchr = "char *strchr(const char *s, int c)";
        strrchr = "char *strrchr(const char *s, int c)";
        strstr = "char *strstr(const char *s, const char *needle)";
      };
    };
    "strings.h" = {
      prelude = "#include <stddef.h>";
      protos = {
        strcasecmp = "int strcasecmp(const char *a, const char *b)";
        strncasecmp = "int strncasecmp(const char *a, const char *b, size_t n)";
      };
    };
    "ctype.h" = {
      prelude = "";
      protos = {
        toupper = "int toupper(int c)";
        tolower = "int tolower(int c)";
        isspace = "int isspace(int c)";
        isprint = "int isprint(int c)";
      };
    };
    "stdlib.h" = {
      prelude = ''
        #include <stddef.h>
        #define EXIT_SUCCESS 0
        #define EXIT_FAILURE 1'';
      protos = {
        atoi = "int atoi(const char *s)";
        abs = "int abs(int x)";
        malloc = "void *malloc(size_t n)";
        calloc = "void *calloc(size_t count, size_t n)";
        realloc = "void *realloc(void *p, size_t n)";
        free = "void free(void *p)";
        exit = "void exit(int status) __attribute__((noreturn))";
        getenv = "char *getenv(const char *name)";
        atof = "double atof(const char *s)";
        system = "int system(const char *command)";
      };
    };
    "stdio.h" = {
      prelude = ''
        #include <stddef.h>
        #include <stdarg.h>
        typedef struct __hostcall_FILE FILE;
        #define stdin ((FILE *)${toString stdHandles.stdin})
        #define stdout ((FILE *)${toString stdHandles.stdout})
        #define stderr ((FILE *)${toString stdHandles.stderr})
        #define EOF (-1)
        #define SEEK_SET 0
        #define SEEK_CUR 1
        #define SEEK_END 2'';
      protos = {
        printf = "int printf(const char *fmt, ...)";
        vprintf = "int vprintf(const char *fmt, va_list ap)";
        fprintf = "int fprintf(FILE *f, const char *fmt, ...)";
        vfprintf = "int vfprintf(FILE *f, const char *fmt, va_list ap)";
        snprintf = "int snprintf(char *buf, size_t n, const char *fmt, ...)";
        vsnprintf = "int vsnprintf(char *buf, size_t n, const char *fmt, va_list ap)";
        sscanf = "int sscanf(const char *s, const char *fmt, ...)";
        vsscanf = "int vsscanf(const char *s, const char *fmt, va_list ap)";
        puts = "int puts(const char *s)";
        putchar = "int putchar(int c)";
        fopen = "FILE *fopen(const char *path, const char *mode)";
        fclose = "int fclose(FILE *f)";
        fread = "size_t fread(void *buf, size_t size, size_t count, FILE *f)";
        fwrite = "size_t fwrite(const void *buf, size_t size, size_t count, FILE *f)";
        fseek = "int fseek(FILE *f, long offset, int whence)";
        ftell = "long ftell(FILE *f)";
        fflush = "int fflush(FILE *f)";
        remove = "int remove(const char *path)";
        rename = "int rename(const char *from, const char *to)";
      };
    };
    "sys/types.h" = {
      prelude = ''
        #include <stddef.h>
        typedef int ssize_t;
        typedef long off_t;
        typedef unsigned int mode_t;'';
      protos = { };
    };
    "sys/stat.h" = {
      prelude = "#include <sys/types.h>";
      protos = {
        mkdir = "int mkdir(const char *path, mode_t mode)";
      };
    };
    "unistd.h" = {
      prelude = "#include <sys/types.h>";
      protos = {
        isatty = "int isatty(int fd)";
        usleep = "int usleep(unsigned int usec)";
      };
    };
    "fcntl.h" = {
      prelude = "#include <sys/types.h>";
      protos = { };
    };
    "errno.h" = {
      prelude = ''
        extern int errno;
        #define ENOENT 2
        #define EEXIST 17
        #define EISDIR 21
        #define EINVAL 22'';
      protos = { };
    };
    "math.h" = {
      prelude = "";
      protos = {
        fabs = "double fabs(double x)";
      };
    };
    "inttypes.h" = {
      prelude = "#include <stdint.h>";
      protos = { };
    };
    "assert.h" = {
      prelude = "#define assert(e) ((void)0)";
      protos = { };
    };
  };

  # The standard headers that the toolchain takes from clang and that the C compiler of
  # cc/ needs besides the generated ones. va_list is __builtin_va_list, which cc/ knows as
  # a type of its own (a list of the variable arguments, see cc/parse.nix).
  stdHeaderFiles = {
    "limits.h" = ''
      #ifndef OWN_LIMITS_H
      #define OWN_LIMITS_H
      #define CHAR_BIT 8
      #define SHRT_MAX 32767
      #define SHRT_MIN (-32767 - 1)
      #define INT_MAX 2147483647
      #define INT_MIN (-2147483647 - 1)
      #define UINT_MAX 4294967295U
      #endif
    '';
    "stdarg.h" = ''
      #ifndef OWN_STDARG_H
      #define OWN_STDARG_H
      typedef __builtin_va_list va_list;
      #define va_start(ap, last) __builtin_va_start(ap, last)
      #define va_arg(ap, type) __builtin_va_arg(ap, type)
      #define va_end(ap) __builtin_va_end(ap)
      #define va_copy(dest, src) __builtin_va_copy(dest, src)
      #endif
    '';
    "stdbool.h" = ''
      #ifndef OWN_STDBOOL_H
      #define OWN_STDBOOL_H
      #define bool _Bool
      #define true 1
      #define false 0
      #define __bool_true_false_are_defined 1
      #endif
    '';
    "stddef.h" = ''
      #ifndef OWN_STDDEF_H
      #define OWN_STDDEF_H
      typedef unsigned int size_t;
      typedef int ptrdiff_t;
      typedef int wchar_t;
      #define NULL ((void *)0)
      #endif
    '';
    "stdint.h" = ''
      #ifndef OWN_STDINT_H
      #define OWN_STDINT_H
      typedef signed char int8_t;
      typedef unsigned char uint8_t;
      typedef short int16_t;
      typedef unsigned short uint16_t;
      typedef int int32_t;
      typedef unsigned int uint32_t;
      typedef long long int64_t;
      typedef int intptr_t;
      typedef unsigned int uintptr_t;
      #endif
    '';
  };

  byName = indexBy (e: e.name) checked;
  byNum = indexBy (e: toString e.num) checked;

  # --- Emulator-side dispatch ---

  # Argument registers a0..a5 by index.
  argRegs = genList (i: toString (10 + i)) 6;

  # Arguments of entry e read from the registers: one u32 per "int" / "ptr", one
  # { lo; hi; } from two consecutive registers per "i64".
  readArgs =
    regs: e:
    let
      go =
        i: ts:
        if ts == [ ] then
          [ ]
        else
          let
            t = builtins.head ts;
            reg = k: regs.${elemAt argRegs k};
          in
          if t == "i64" then
            [
              {
                lo = reg i;
                hi = reg (i + 1);
              }
            ]
            ++ go (i + 2) (builtins.tail ts)
          else
            [ (reg i) ] ++ go (i + 1) (builtins.tail ts);
    in
    go 0 e.args;

  # Registers after returning `ret` of type t: a0, or a0 (low) and a1 (high) for "i64";
  # unchanged for "void".
  writeRet =
    regs: t: ret:
    if t == "void" then
      regs
    else if t == "i64" then
      regs
      // {
        "10" = ret.lo;
        "11" = ret.hi;
      }
    else
      regs // { "10" = ret; };

  # The ecall handler for `mkState { host = { call = dispatch impls; world; }; }` of
  # lib/cpu.nix. `impls.<name>` has the lib/libc.nix interface
  # (world: args: { world; ret; }).
  #
  # The world passed to an implementation is `state.host.world` (everything that is not
  # machine state: brk, files, errnoAddr and wad of lib/libc.nix, plus any fields of
  # other implementations such as the platform layer) together with the machine's
  # `mem` and `out` and the instruction count `count`. The count is the one at the
  # start of the current 64-step batch of lib/cpu.nix, so it lags by fewer than 64
  # instructions. Afterwards mem and out go back into the state and the remaining
  # fields into `state.host.world`. Every world field is forced to weak head normal
  # form and the small libc fields completely, so that no thunk keeps old worlds alive.
  #
  # The exit entry halts the machine like the a7 = 93 exit call.
  dispatch =
    impls: s:
    let
      a7 = s.regs."17";
      e =
        byNum.${toString a7}
        or (throw "lib/hostcall.nix: unknown host call a7=${toString a7} at pc=${toString s.pc}");
      args = readArgs s.regs e;
      impl = impls.${e.name} or (throw "lib/hostcall.nix: no implementation of host call ${e.name}");
      world0 = s.host.world // {
        inherit (s) mem out count;
      };
      r = impl world0 args;
      w = r.world;
      rest = removeAttrs w [
        "mem"
        "out"
        "count"
      ];
      forced = foldl' (acc: k: builtins.seq rest.${k} acc) true (attrNames rest);
      small = builtins.deepSeq [
        (w.brk or null)
        (w.files or null)
        (w.errnoAddr or null)
      ] true;
    in
    if e.name == "exit" then
      s
      // {
        halted = true;
        exitCode = elemAt args 0;
      }
    else
      builtins.seq forced (
        builtins.seq small (
          builtins.seq w.out (
            s
            // {
              inherit (w) mem out;
              regs = writeRet s.regs e.ret r.ret;
              host = s.host // {
                world = rest;
              };
            }
          )
        )
      );

  # Abstract table type of a C type text: pointers (and va_list, a pointer under ilp32) are "ptr", 64-bit types (and
  # double) "i64", void "void", everything else "int".
  abstractType =
    t:
    if match ".*(\\*|va_list).*" t != null then
      "ptr"
    else if match ".*(double|long long).*" t != null then
      "i64"
    else if match " *void *" t != null then
      "void"
    else
      "int";

  # Split the text between the parentheses of a prototype into the abstract types of
  # its fixed parameters; `...` is dropped and `void` alone means no parameters.
  protoArgs =
    text:
    let
      inner = elemAt (match "[^(]*\\((.*)\\)[^)]*" text) 0;
      parts = filter (p: match " *" p == null && match " *\\.\\.\\. *" p == null) (
        filter builtins.isString (builtins.split "," inner)
      );
    in
    if match " *void *" inner != null then [ ] else map abstractType parts;

  # Abstract return type: the text before the function name.
  protoRet =
    name: text:
    let
      m = match "(.*[^A-Za-z0-9_])${name} *\\(.*" text;
    in
    abstractType (if m == null then text else elemAt m 0);

  # Throws unless the C prototype `text` of entry `e` agrees with the table's args and
  # ret (for a variadic entry, the table's args are the fixed parameters); returns
  # true otherwise.
  checkProto =
    file: name: text: e:
    let
      got = protoArgs text;
      ret = protoRet name text;
      show = ts: "(${concatStringsSep ", " ts})";
    in
    if got != e.args then
      throw "lib/hostcall.nix: ${file}: arguments of ${name} are ${show got} but the table has ${show e.args}"
    else if ret != e.ret then
      throw "lib/hostcall.nix: ${file}: return type of ${name} is ${ret} but the table has ${e.ret}"
    else
      true;

  # Text of one generated header, after checking its prototypes against the table.
  headerText =
    file:
    let
      h = headers.${file};
      guard = "HOSTCALL_" + replaceStrings [ "/" "." ] [ "_" "_" ] file;
      check =
        name:
        let
          variadicProto = match ".*\\.\\.\\..*" h.protos.${name} != null;
        in
        if !(hasAttr name byName) then
          throw "lib/hostcall.nix: ${file} declares ${name}, which is not in the table"
        else if variadicProto != isVariadic byName.${name} then
          throw "lib/hostcall.nix: ${file}: variadic mismatch for ${name}"
        else
          builtins.seq (checkProto file name h.protos.${name} byName.${name}) "${h.protos.${name}};";
    in
    ''
      /* Generated from lib/hostcall.nix. */
      #ifndef ${guard}
      #define ${guard}
      ${h.prelude}
      ${concatStringsSep "\n" (map check (attrNames h.protos))}
      #endif
    '';

  headerFiles = listToAttrs (
    map (file: {
      name = file;
      value = headerText file;
    }) (attrNames headers)
  );
in
{
  # The validated table, the FILE * handle values, and the entries by name and by
  # number for the emulator-side dispatch.
  table = checked;
  inherit
    checkProto
    stdHandles
    byName
    byNum
    dispatch
    ;

  # { "<path>.h" = text; } for every generated header.
  inherit headerFiles;

  # The standard headers for the C compiler of cc/ (not given to the toolchain, which has
  # clang's), and those together with the generated ones.
  inherit stdHeaderFiles;
  ccHeaderFiles = headerFiles // stdHeaderFiles;

  # The types of the entries whose double arguments and results the C compiler of cc/
  # passes as they are (Nix floats), "f64", where the table has the soft-float "i64" of
  # the toolchain; cc/host.nix applies them to the table (the toolchain, the stubs and
  # dispatch keep the table as it is).
  ccFloatTypes = {
    atof = {
      args = [ "ptr" ];
      ret = "f64";
    };
    fabs = {
      args = [ "f64" ];
      ret = "f64";
    };
  };

  # The variables that the host provides to C code linked by cc/link.nix
  # ([ { name; size; align; } ], see cc/host.nix): errno, which stubsC defines for the
  # toolchain.
  hostData = [
    {
      name = "errno";
      size = 4;
      align = 4;
    }
  ];

  # Assembly stubs for every non-variadic entry.
  stubsAsm = concatStringsSep "\n" (map asmStub (filter (e: !(isVariadic e)) checked));

  # C stubs for the variadic entries, plus the definition of errno.
  stubsC = ''
    /* Generated from lib/hostcall.nix. */
    int errno;
  ''
  + concatStringsSep "\n" (map varStub (filter isVariadic checked));

  # Program entry: call main(argc, argv) and exit with its result (a7 = 93).
  startAsm = ''
        .section .text.start,"ax",@progbits
        .globl _start
        .type _start, @function
    _start:
        call main
        li a7, 93
        ecall
        .size _start, . - _start
  '';
}
