# Tests for the C preprocessor (cc/pp.nix) and the preprocessed path of the compiler
# (cc.preprocess, cc.compileFile, cc.loadFile). Virtual files are given as an attribute
# set. Expected values follow C99 6.10, worked out by hand and checked against `gcc -E`
# and `clang -E`. Errors are checked to be thrown (tryEval does not show the message);
# each sits next to a valid variant of the same input.
let
  Cc = import ../cc;
  L = import ../cc/lex.nix;
  P = import ../cc/parse.nix;
  M = import ../lib/mem.nix;
  inherit (builtins)
    concatStringsSep
    deepSeq
    elemAt
    foldl'
    genList
    head
    length
    listToAttrs
    map
    tryEval
    ;

  t = name: got: expected: { inherit name got expected; };

  readOf = files: n: files.${n} or null;
  ppWith =
    args: files:
    Cc.preprocess (
      {
        main = "main.c";
        read = readOf files;
      }
      // args
    );
  ppFiles = ppWith { };
  # The spellings of the tokens of the file src, separated by spaces.
  pp =
    src:
    concatStringsSep " " (
      map (k: k.text) (ppFiles {
        "main.c" = src;
      })
    );
  throws = x: !(tryEval (deepSeq x x)).success;
  ppThrows = src: throws (pp src);
  posOf = k: "${k.file}:${toString k.line}:${toString k.col}";

  # The value returned by the function fn of the program in files (main.c first), called
  # with args on the memory after __data.init.
  runFiles =
    files: fn: args:
    let
      r = Cc.loadFile {
        main = "main.c";
        read = readOf files;
      };
    in
    (foldl' (g: a: g a) (r.${fn} (r.__data.init M.empty)) args).ret;
  run = src: runFiles { "main.c" = src; };
  compileThrows =
    src:
    throws (
      Cc.compileFile {
        main = "main.c";
        read = readOf { "main.c" = src; };
      }
    );

  # A chain of n files: main.c includes f1.h, which includes f2.h, ..., fn.h holds `x`.
  chain =
    n:
    listToAttrs (
      genList (i: {
        name = "f${toString (i + 1)}.h";
        value = if i + 1 == n then "x\n" else "#include \"f${toString (i + 2)}.h\"\n";
      }) n
    )
    // {
      "main.c" = "#include \"f1.h\"\n";
    };

  nums = n: genList toString n;
  lines = xs: concatStringsSep "\n" xs + "\n";
in
[
  # ---- Lines and comments ----
  (t "pp lines: backslash-newline joins lines, inside a token and a directive"
    [
      (pp "ab\\\ncd")
      (pp "#def\\\nine X 1 \\\n + 2\nX")
      (pp "\"a\\\nb\"")
    ]
    [
      "abcd"
      "1 + 2"
      "\"ab\""
    ]
  )
  (t "pp lines: comments are whitespace; `//` in a string is not a comment"
    [
      (pp "a /* x\n y */ b // c\nd")
      (pp "\"x // y\" z")
      (pp "x /* \" */ y")
      (pp "a/**/b")
    ]
    [
      "a b d"
      "\"x // y\" z"
      "x y"
      "a b"
    ]
  )
  (t "pp lines: whitespace around directives, a comment before `#`, the null directive"
    [
      (pp "  #  define  X  1  \nX")
      (pp "/* c */ # define Y 2\nY")
      (pp "#\nZ\n# /* c */\n")
      (pp "w /*\n*/ # define V 3\nV")
    ]
    [
      "1"
      "2"
      "Z"
      "w # define V 3 V"
    ]
  )
  (t "pp lines: trigraphs are not replaced (as in the GNU modes of gcc and clang)"
    [
      (pp "a ??( b ??) c")
      (pp "??=define X 1\nX")
    ]
    [
      "a ? ? ( b ? ? ) c"
      "? ? = define X 1 X"
    ]
  )
  (t "pp lines: positions after spliced lines and multi-line comments"
    (map posOf (ppFiles {
      "main.c" = "a \\\n  b /* x\n */ c\n  d";
    }))
    [
      "main.c:1:1"
      "main.c:2:3"
      "main.c:3:5"
      "main.c:4:3"
    ]
  )

  # ---- #include ----
  (t "pp include: \"\" looks in the including file's directory first, <> in includePaths only"
    (map
      (
        src:
        concatStringsSep " " (
          map (k: k.text) (
            ppWith { includePaths = [ "inc" ]; } {
              "main.c" = src;
              "a.h" = "here";
              "inc/a.h" = "inc";
            }
          )
        )
      )
      [
        "#include \"a.h\""
        "#include <a.h>"
      ]
    )
    [
      "here"
      "inc"
    ]
  )
  (t "pp include: includePaths in order; a file in a subdirectory includes relative to it"
    (map (k: k.text) (
      ppWith
        {
          includePaths = [
            "i1"
            "i2"
          ];
        }
        {
          "main.c" = "#include <b.h>\n#include <sub/x.h>\n";
          "i1/b.h" = "one";
          "i2/b.h" = "two";
          "i2/sub/x.h" = "#include \"y.h\"\n#include <y.h>\n";
          "i2/sub/y.h" = "near";
          "i1/y.h" = "far";
        }
    ))
    [
      "one"
      "near"
      "far"
    ]
  )
  (t "pp include: a guard keeps the second inclusion out; an unguarded file twice"
    [
      (concatStringsSep " " (
        map (k: k.text) (ppFiles {
          "main.c" = "#include \"g.h\"\n#include \"g.h\"\n";
          "g.h" = "#ifndef G_H\n#define G_H\ng\n#endif\n";
        })
      ))
      (concatStringsSep " " (
        map (k: k.text) (ppFiles {
          "main.c" = "#include \"u.h\"\n#include \"u.h\"\n";
          "u.h" = "u";
        })
      ))
    ]
    [
      "g"
      "u u"
    ]
  )
  (t "pp include: a missing file, `#include MACRO` and an empty name are errors"
    [
      (throws (ppFiles {
        "main.c" = "#include \"nope.h\"";
      }))
      (throws (ppFiles {
        "main.c" = "#define H \"a.h\"\n#include H\n";
        "a.h" = "a";
      }))
      (throws (ppFiles {
        "main.c" = "#include \"a.h\"\n";
        "a.h" = "a";
      }))
      (ppThrows "#include \"\"")
      (ppThrows "#include <>")
      (ppThrows "#include \"a.h\" junk")
    ]
    [
      true
      true
      false
      true
      true
      true
    ]
  )
  (t "pp include: nesting of 200 files is accepted, 201 is an error"
    [
      (map (k: k.text) (ppFiles (chain 200)))
      (throws (ppFiles (chain 201)))
      (throws (ppFiles {
        "main.c" = "#include \"main.c\"\n";
      }))
    ]
    [
      [ "x" ]
      true
      true
    ]
  )

  # ---- Object-like macros ----
  (t "pp object: chains, self-reference, mutual reference, empty replacement"
    [
      (pp "#define A B\n#define B C\n#define C 3\nA B C")
      (pp "#define x x\nx")
      (pp "#define a b\n#define b a\na b")
      (pp "#define E\n[E]")
      (pp "#define x 2 + x\nx")
    ]
    [
      "3 3 3"
      "x"
      "a b"
      "[ ]"
      "2 + x"
    ]
  )
  (t "pp object: redefinition must be the same (tokens and whitespace)"
    [
      (pp "#define X 1 + 2\n#define X 1 /* c */ +  2\nX")
      (ppThrows "#define X 1 + 2\n#define X 1+2\n")
      (ppThrows "#define X 1\n#define X 2\n")
      (ppThrows "#define F(a) a\n#define F(b) b\n")
      (ppThrows "#define F(a) a\n#define F a\n")
    ]
    [
      "1 + 2"
      true
      true
      true
      true
    ]
  )
  (t "pp object: #undef and redefinition, also inside a function body"
    [
      (pp "#define X 1\n#undef X\nX\n#define X 2\nX\n#undef NONE\n")
      (pp ''
        int f(void) {
        #define R 7
          return R;
        #undef R
        }
        R
      '')
    ]
    [
      "X 2"
      "int f ( void ) { return 7 ; } R"
    ]
  )
  (t "pp object: defines are predefined; `defined`, __FILE__ and __LINE__ cannot be (un)defined"
    [
      (concatStringsSep " " (
        map (k: k.text) (
          ppWith {
            defines = {
              N = "4";
              S = "1 + (N)";
            };
          } { "main.c" = "N S"; }
        )
      ))
      (posOf (head (ppWith { defines.N = "4"; } { "main.c" = "\n N"; })))
      (throws (ppWith { defines.N = "1\n2"; } { "main.c" = "N"; }))
      (throws (ppWith { defines."1x" = "1"; } { "main.c" = ""; }))
      (ppThrows "#define defined 1")
      (ppThrows "#undef __LINE__")
      (ppThrows "#define __FILE__ x")
      (ppThrows "#define 3 x")
    ]
    [
      "4 1 + ( 4 )"
      "main.c:2:2"
      true
      true
      true
      true
      true
      true
    ]
  )

  # ---- Function-like macros ----
  (t "pp function: 0, 1 and several arguments, empty arguments, nesting, parentheses and commas"
    [
      (pp "#define Z() z\n#define O(a) <a>\n#define T(a, b, c) a|b|c\nZ() O() O(1) T(1, , 3) T(,,)")
      (pp "#define O(a) <a>\nO(O(O(1)))")
      (pp "#define T(a, b) a|b\nT((1, 2), f(3, 4)) T(a[1], 2)")
    ]
    [
      "z < > < 1 > 1 | | 3 | |"
      "< < < 1 > > >"
      "( 1 , 2 ) | f ( 3 , 4 ) a [ 1 ] | 2"
    ]
  )
  (t "pp function: a call over lines; a name without `(` stays; wrong argument counts"
    [
      (pp "#define T(a, b) a|b\nT(1,\n  2\n)\nT\n(3, 4)")
      (pp "#define F(x) x\nint F; F = F (1);")
      (ppThrows "#define T(a, b) a|b\nT(1)")
      (ppThrows "#define T(a, b) a|b\nT(1, 2, 3)")
      (ppThrows "#define Z() z\nZ(1)")
      (ppThrows "#define F(x) x\nF(1")
    ]
    [
      "1 | 2 3 | 4"
      "int F ; F = 1 ;"
      true
      true
      true
      true
    ]
  )
  (t "pp function: arguments are expanded first (not for # and ##), then rescanned"
    [
      (pp "#define X 5\n#define S(x) #x\n#define XS(x) S(x)\nS(X) XS(X)")
      (pp "#define R(f, x) f(x)\n#define N(x) -x\nR(N, 2)")
      (pp "#define F G\n#define G(x) [x]\nF(1)")
      (pp "#define f(x) f(x)\nf(f(1))")
      (pp "#define f(x) g(x)\n#define g(x) f(x)\nf(1) g(2)")
    ]
    [
      "\"X\" \"5\""
      "- 2"
      "[ 1 ]"
      "f ( f ( 1 ) )"
      "f ( 1 ) g ( 2 )"
    ]
  )
  (t "pp function: variadic macros and malformed parameter lists are errors"
    [
      (ppThrows "#define V(...) __VA_ARGS__")
      (ppThrows "#define V(a, ...) a")
      (ppThrows "#define V(a) __VA_ARGS__")
      (ppThrows "#define V(a,) a")
      (ppThrows "#define V(a b) a")
      (ppThrows "#define V(a, a) a")
      (ppThrows "#define V(a")
      (pp "#define V (a) a\nV")
      (ppThrows "#define Q 'a")
      (ppThrows "#define Q(x) \"a")
      (ppThrows "#define Q '")
    ]
    [
      true
      true
      true
      true
      true
      true
      true
      "( a ) a"
      true
      true
      true
    ]
  )
  (t "pp function: a directive inside the arguments, and a call across a directive, are unsupported"
    [
      (ppThrows "#define F(x) x\nF(1,\n#define Y\n2)")
      (ppThrows "#define F(x) x\nF\n#define Y\n(1)")
      (pp "#define F(x) x\nF\n#define Y\n+(1)")
    ]
    [
      true
      true
      "F + ( 1 )"
    ]
  )

  # ---- # ----
  (t "pp stringify: whitespace between tokens becomes one space, none where there was none"
    [
      (pp "#define S(x) #x\nS(a+b) S(a + b) S( a  /* c */  b ) S(a\n  b)")
      (pp "#define S(x) #x\nS(\"a\\n\" '\\'' \"\\\\\") S(\"\\x\") S() S(  )")
      (pp "#define S(x) # x\n#define E\nS(E) S(S(1))")
    ]
    [
      "\"a+b\" \"a + b\" \"a b\" \"a b\""
      "\"\\\"a\\\\n\\\" '\\\\'' \\\"\\\\\\\\\\\"\" \"\\\"\\\\x\\\"\" \"\" \"\""
      "\"E\" \"S(1)\""
    ]
  )
  (t "pp stringify: `#` must be followed by a parameter in a function-like macro"
    [
      (ppThrows "#define S(x) #y")
      (ppThrows "#define S(x) x #")
      (pp "#define H # x\nH")
    ]
    [
      true
      true
      "# x"
    ]
  )

  # ---- Hide sets ----
  (t "pp hide sets: the rules of the names that a token must not expand"
    [
      (pp "#define A B\n#define B() A\nA()")
      (pp "#define f(a) a*g\n#define g(a) f(a)\nf(2)(9)")
      (pp "#define g(x) x\ng(g)(1)")
      (pp "#define AA BB\n#define BB() AA\nAA() AA")
    ]
    [
      "B"
      "2 * 9 * g"
      "g ( 1 )"
      "BB BB"
    ]
  )

  # ---- ## ----
  (t "pp paste: identifiers, numbers, empty arguments, three operands, operators"
    [
      (pp "#define C(a, b) a ## b\nC(x, y) C(1, 2) C(, y) C(x, ) C(, ) C(+, =) C(-, >) C(1, e) C(.,5)")
      (pp "#define C3(a, b, c) a ## b ## c\nC3(x, y, z) C3(, , z) C3(<, <, =) C3(, , )")
      (pp "#define J a ## b\nJ")
    ]
    [
      "xy 12 y x += -> 1e .5"
      "xyz z <<="
      "ab"
    ]
  )
  (t "pp paste: the operands are not expanded first; the result is rescanned"
    [
      (pp "#define C(a, b) a ## b\n#define ONE 1\n#define AB 42\nC(ONE, 2) C(A, B) C(1, C(2, 3))")
      (pp "#define hash_hash # ## #\n#define mkstr(a) # a\n#define in_between(a) mkstr(a)\n#define join(c, d) in_between(c hash_hash d)\njoin(x, y)")
    ]
    [
      "ONE2 42 1C ( 2 , 3 )"
      "\"x ## y\""
    ]
  )
  (t "pp paste: an invalid token and `##` at either end are errors"
    [
      (ppThrows "#define C(a, b) a ## b\nC(/, /)")
      (ppThrows "#define C(a, b) a ## b\nC(., .)")
      (ppThrows "#define C(a, b) a ## b\nC(+, -)")
      (ppThrows "#define C(a) ## a")
      (ppThrows "#define C(a) a ##")
      (pp "#define C(a, b) a ## b\nC(/, =)")
    ]
    [
      true
      true
      true
      true
      true
      "/="
    ]
  )

  # ---- Conditionals ----
  (t "pp if: operators, precedence and associativity"
    (map (e: pp "#if ${e}\nyes\n#else\nno\n#endif") [
      "1 + 2 * 3 == 7"
      "(1 + 2) * 3 == 9"
      "10 - 2 - 3 == 5"
      "-7 / 2 == -3 && -7 % 2 == -1"
      "1 << 4 == 16 && -16 >> 2 == -4"
      "(6 & 3) == 2 && (6 ^ 3) == 5 && (6 | 3) == 7 && ~0 == -1"
      "!0 && !!5 == 1 && +3 == 3"
      "1 < 2 && 2 > 1 && 2 <= 2 && 2 >= 3"
      "1 != 2 && 0 || 1"
      "1 ? 0 : 1 ? 1 : 1"
      "1 ? 2 : 3 == 2"
      "0x10 == 16 && 010 == 8 && 5L == 5 && 7ll == 7 && 'A' == 65 && '\\n' == 10"
      "9223372036854775807 > 0"
    ])
    [
      "yes"
      "yes"
      "yes"
      "yes"
      "yes"
      "yes"
      "yes"
      "no"
      "yes"
      "no"
      "yes"
      "yes"
      "yes"
    ]
  )
  (t "pp if: defined in both forms, undefined names are 0, macros are expanded"
    [
      (pp "#define D\n#if defined D && defined(D) && !defined UND && !defined ( UND )\nyes\n#endif")
      (pp "#if UND == 0 && int == 0\nyes\n#endif")
      (pp "#define N 3\n#define F(x) (x * 2)\n#if F(N) == 6\nyes\n#endif")
      (pp "#define V\n#ifdef V\na\n#endif\n#ifndef V\nb\n#endif\n#ifndef W\nc\n#endif")
    ]
    [
      "yes"
      "yes"
      "yes"
      "a c"
    ]
  )
  (t "pp if: nesting and #elif chains (nothing is evaluated after a true group)"
    [
      (pp "#if 1\n#if 0\na\n#elif 1\nb\n#else\nc\n#endif\n#endif")
      (pp "#if 0\na\n#elif 2 - 2\nb\n#elif 1\nc\n#elif 1 / 0\nd\n#else\ne\n#endif")
      (pp "#if 1\na\n#elif 1 / 0\nb\n#else\nc\n#endif")
      (pp "#if 0\n#if 1 / 0\n#elif 1\n#else\n#endif\nx\n#else\ny\n#endif")
    ]
    [
      "b"
      "c"
      "a"
      "y"
    ]
  )
  (t "pp if: a skipped group may hold anything except an unterminated comment"
    [
      (pp "#if 0\ndon't stop here\n` @ $ \\\n#bogus x\n#error stop\n#if 1/0\n#endif\n#include\n#endif\nok")
      (pp "#if 0\n/*\n#endif\n*/\n#else\nyes\n#endif")
      (pp "#if 0\n\"/*\"\n#endif\nyes")
      (pp "#if 0\n// \\\n#endif\n#endif\nyes")
      (pp "#if 0\n\"a\\\n#endif\"\n#endif\nyes")
      (ppThrows "#if 0\n/* open\n#endif\n")
    ]
    [
      "ok"
      "yes"
      "yes"
      "yes"
      "yes"
      true
    ]
  )
  (t "pp if: unbalanced directives and malformed expressions are errors" [
    (ppThrows "#endif")
    (ppThrows "#else")
    (ppThrows "#elif 1")
    (ppThrows "#if 1\n")
    (throws (ppFiles {
      "main.c" = "#if 1\n#include \"a.h\"\n";
      "a.h" = "#endif\n";
    }))
    (ppThrows "#if 1\n#else\n#else\n#endif")
    (ppThrows "#if 1\n#else\n#elif 1\n#endif")
    (ppThrows "#if\n#endif")
    (ppThrows "#if 1 2\n#endif")
    (ppThrows "#if (1\n#endif")
    (ppThrows "#if 1.0\n#endif")
    (ppThrows "#if \"s\"\n#endif")
    (ppThrows "#if defined\n#endif")
    (ppThrows "#if defined(X\n#endif")
    (ppThrows "#ifdef\n#endif")
    (ppThrows "#ifdef X Y\n#endif")
    (ppThrows "#if 1\n#endif X")
  ] (genList (_: true) 17))
  (t "pp if: unsigned literals, values of 2^63 or more, overflow and division by zero are errors"
    [
      (ppThrows "#if 1u\n#endif")
      (ppThrows "#if 0 && 1U\n#endif")
      (ppThrows "#if 9223372036854775808\n#endif")
      (ppThrows "#if 9223372036854775807 + 1\n#endif")
      (ppThrows "#if 1 << 63\n#endif")
      (ppThrows "#if 1 / 0\n#endif")
      (ppThrows "#if 1 % (2 - 2)\n#endif")
      (ppThrows "#define D defined X\n#if D\n#endif")
      (pp "#if 0 && 1 / 0\n#elif 1 || 1 / 0\na\n#endif\n#if 0 ? 1 / 0 : 1\nb\n#endif")
    ]
    [
      true
      true
      true
      true
      true
      true
      true
      true
      "a b"
    ]
  )

  # ---- Other directives ----
  (t "pp directives: #error, #pragma, #line and unknown ones in an active group"
    [
      (ppThrows "#error stop here")
      (ppThrows "#pragma once")
      (ppThrows "#line 10")
      (ppThrows "#include_next <a.h>")
      (ppThrows "#warning w")
      (ppThrows "#ident \"x\"")
      (ppThrows "#bogus")
      (ppThrows "# 12 \"f.c\"")
      (pp "#if 0\n#pragma once\n#line 10\n#warning w\n#endif\nok")
    ]
    [
      true
      true
      true
      true
      true
      true
      true
      true
      "ok"
    ]
  )
  (t "pp digraphs are unsupported in active text and directives, and as a directive"
    [
      (ppThrows "a <: 0 :>")
      (ppThrows "#define X <%")
      (ppThrows "%:define X")
      (ppThrows "#if 0\n%:endif\n#endif")
      (pp "#if 0\na <: b\n#endif\nok")
    ]
    [
      true
      true
      true
      true
      "ok"
    ]
  )

  # ---- __FILE__, __LINE__, __STDC__ ----
  (t "pp predefined: __FILE__ and __LINE__ in an included file, after a splice and in a macro"
    (map (k: k.text) (ppFiles {
      "main.c" =
        "__FILE__ __LINE__\n#include \"sub/h.h\"\n#define WHERE __FILE__ __LINE__\na \\\nb __LINE__\n\nWHERE\n__STDC__ __STDC_VERSION__";
      "sub/h.h" = "\n__FILE__ __LINE__\n";
    }))
    [
      "\"main.c\""
      "1"
      "\"sub/h.h\""
      "2"
      "a"
      "b"
      "5"
      "\"main.c\""
      "7"
      "1"
      "199901L"
    ]
  )
  (t "pp predefined: __LINE__ in a call over lines is the line of the outermost name"
    [
      (pp "#define F(x) x __LINE__\nF(\n__LINE__\n)")
      (pp "#define L __LINE__\n#define F(x) x\nF(L\n)")
    ]
    [
      "3 2"
      "3"
    ]
  )

  # ---- Positions ----
  (t "pp positions: tokens of an expansion are at the outermost macro name" (map posOf (ppFiles {
    "main.c" = "#include \"m.h\"\n  OUTER(z)\n";
    "m.h" = "#define INNER(a) a + 1\n#define OUTER(b) INNER(b) * 2\n";
  })) (genList (_: "main.c:2:3") 5))
  (t "pp positions: nodes of a preprocessed file carry the file of their tokens"
    (
      let
        unit = P.parseTokenList (
          let
            x = (import ../cc/pp.nix).preprocess {
              main = "main.c";
              read = readOf {
                "main.c" = "#include \"h.h\"\nint g;\n";
                "h.h" = "\n  int f(void);\n";
              };
            };
          in
          L.fromPp x.toks x.end
        );
      in
      map (i: "${i.name} ${posOf i}") unit.items
    )
    [
      "f h.h:2:7"
      "g main.c:2:5"
    ]
  )

  (t "pp positions: an error in an included file stops compileFile (message checked by hand)"
    (map
      (
        body:
        throws (
          Cc.compileFile {
            main = "main.c";
            read = readOf {
              "main.c" = "int x;\n#include \"h.h\"\n";
              "h.h" = "\nint g(void) { return ${body}; }\n";
            };
          }
        )
      )
      [
        "x"
        "y"
      ]
    )
    [
      false
      true
    ]
  )

  # ---- The two stages, the joining of strings, anonymous types ----
  (t "pp stages: preprocess keeps numbers and literals as written; compileFile checks them"
    [
      (pp "double d = 1.5e+3; char *s = \"\\q\";")
      (compileThrows "double d = 1.5e+3;")
      (compileThrows "char *s = \"\\q\";")
      (compileThrows "#define H #\nint H;")
      (compileThrows "int a = 'x;")
      (run "#define N 5\nint f(void) { return N + 1; }" "f" [ ])
    ]
    [
      "double d = 1.5e+3 ; char * s = \"\\q\" ;"
      true
      true
      true
      true
      6
    ]
  )
  (t "pp strings: adjacent literals are joined after expansion"
    [
      (pp "#define S \"b\"\n\"a\" S \"c\"")
      (run
        "#define S \"b\"\nint f(void) { return sizeof(\"a\" S \"c\"); }\nint g(void) { return (\"a\" S \"c\")[2]; }"
        "f"
        [ ]
      )
      (run "#define S \"b\"\nint g(void) { return (\"a\" S \"c\")[2]; }" "g" [ ])
    ]
    [
      "\"a\" \"b\" \"c\""
      4
      99
    ]
  )
  (t "pp anonymous types: two in one macro, and two at the same line and column of two headers"
    (
      let
        files = {
          "main.c" = ''
            #define TYPES typedef struct { int a; } A; typedef struct { int b; int c; } B;
            TYPES
            #include "h1.h"
            #include "h2.h"
            A ga; B gb; S1 s1; S2 s2;
            int sizes(void) { return sizeof(A) * 1000 + sizeof(B) * 100 + sizeof(S1) * 10 + sizeof(S2); }
            int members(void) { ga.a = 1; gb.b = 2; gb.c = 3; s1.p = 4; s2.q = 5; s2.r = 6; return ga.a + gb.b * gb.c + s1.p * s2.q * s2.r; }
          '';
          "h1.h" = "typedef struct { char p; } S1;\n";
          "h2.h" = "typedef struct { int q; int r; } S2;\n";
        };
      in
      [
        (runFiles files "sizes" [ ])
        (runFiles files "members" [ ])
      ]
    )
    [
      4818
      127
    ]
  )

  # ---- A program of several files ----
  (t "pp program: headers with typedefs, macros and prototypes, compiled and run"
    (
      let
        files = {
          "main.c" = ''
            #include "vec.h"
            #include "util/math.h"

            vec_t pts[N];

            int sum(int n) {
              int s = 0;
              for (int i = 0; i < n; i++) {
                pts[i].x = i;
                pts[i].y = SQUARE(i);
              }
              for (int i = 0; i < n; i++)
                s += dot(i, i);
              return s;
            }

            int dot(int i, int j) { return pts[i].x * pts[j].x + pts[i].y * pts[j].y; }
          '';
          "vec.h" = ''
            #ifndef VEC_H
            #define VEC_H
            #define N 8
            typedef struct { int x, y; } vec_t;
            int dot(int i, int j);
            #endif
          '';
          "util/math.h" = ''
            #ifndef MATH_H
            #define MATH_H
            #define SQUARE(v) ((v) * (v))
            #endif
          '';
        };
      in
      [
        (runFiles files "sum" [ 4 ])
        (runFiles files "sum" [ 8 ])
      ]
    )
    [
      112
      4816
    ]
  )

  # ---- Scale (the evaluation stack must not grow with these sizes) ----
  (t "pp scale: 5000 lines, 2000 macros defined and used, a chain of 2000 macros"
    [
      (length (ppFiles {
        "main.c" = lines (genList (i: "int v${toString i};") 5000);
      }))
      (
        let
          r = ppFiles {
            "main.c" =
              lines (genList (i: "#define M${toString i} ${toString i}") 2000)
              + concatStringsSep " " (genList (i: "M${toString i}") 2000);
          };
        in
        [
          (length r)
          (elemAt r 1999).text
        ]
      )
      (pp (
        lines ([ "#define C0 0" ] ++ genList (i: "#define C${toString (i + 1)} C${toString i}") 2000)
        + "C2000"
      ))
    ]
    [
      15000
      [
        2000
        "1999"
      ]
      "0"
    ]
  )
  (t "pp scale: 100 nested #if, 2000 tokens on a line and in #if, a call of 200 arguments"
    [
      (pp (lines (genList (_: "#if 1") 100) + "x\n" + lines (genList (_: "#endif") 100)))
      (length (ppFiles {
        "main.c" = concatStringsSep " + " (genList (_: "a") 1001);
      }))
      (pp ("#if " + concatStringsSep " + " (genList (_: "1") 1000) + " == 1000\nyes\n#endif"))
      (
        let
          params = concatStringsSep ", " (genList (i: "a${toString i}") 200);
          r = ppFiles {
            "main.c" = "#define F(${params}) a199 a0 a100\nF(${concatStringsSep ", " (nums 200)})";
          };
        in
        map (k: k.text) r
      )
    ]
    [
      "x"
      2001
      "yes"
      [
        "199"
        "0"
        "100"
      ]
    ]
  )
]
