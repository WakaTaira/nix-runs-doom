# nix-runs-doom

[English](README.md)

`nix eval` だけで動く Doom です。1 回の Nix 評価の中で、Nix で書いた C コンパイラが [doomgeneric](https://github.com/ozkl/doomgeneric) の 80 個の C ファイルを Nix の関数にコンパイルし、同じく Nix で書いた libc とプラットフォーム層がそれを支え、ドライバがゲームを 1 フレームずつ進めて、24 bit カラーの半ブロック文字（`▀`）で端末に描きます。derivation のビルドも IFD も、計算を担う外部プロセスもありません。

## Quick start

Nix（flakes 有効）と Doom の WAD が必要です。shareware 版の `doom1.wad` は自由に配布されています。Doom のソースと WAD はこのリポジトリには含まれません。

```sh
nix run github:WakaTaira/nix-runs-doom#play -- /path/to/doom1.wad
```

clone した中では `nix run .#play -- /path/to/doom1.wad` でも同じです。WAD は一度だけ hex テキストに変換され、`~/.cache/nix-runs-doom` に保存されます。最初のフレームが出るまで、作者の環境で約 45 秒かかります。起動のたびに 80 ファイルをコンパイルするためです。

起動役（`toolchain/play.nix`）は短いシェルで、Doom の計算はしません。評価は端末を読めないので、端末を raw モードにしてキーをファイルへ書き、`nix eval -f . doom.play` を起動し、評価のログからフレームを画面へ写します。

| キー | 動作 |
|---|---|
| 矢印キー | 移動・旋回 |
| Ctrl または `x` | 撃つ |
| 空白 | 使う |
| Shift | 走る |
| Alt | 横移動 |
| Esc | メニュー |
| Enter | 決定 |
| Ctrl-C | 終了 |

複数キーの同時押しの持続と、Ctrl・Shift・Alt の単体入力には、キーの離しを送る端末が必要です。[kitty keyboard protocol](https://sw.kovidgoyal.net/kitty/keyboard-protocol/) に対応した端末か、Windows Terminal（win32-input-mode）です。起動役が端末に問い合わせて、使える方式を選びます。それ以外の端末では、キーは押した直後の 1 フレームだけ押された扱いになり、撃つときは `x` を使います。端末マルチプレクサの中では、離しのイベントが落ちることがあります。

起動役なしで動かす場合（環境変数は `CLAUDE.md` と `doom/default.nix` に書いてあります）:

```sh
export DOOM_SRC=$(nix eval --raw --impure --expr '(builtins.getFlake (toString ./.)).inputs.doomgeneric.outPath')/doomgeneric
export DOOM_WAD_HEX=~/doom1.wad.hex   # od -An -v -tx1 doom1.wad | tr -d ' \n' > ~/doom1.wad.hex
GC_INITIAL_HEAP_SIZE=4g nix eval --raw -f . doom.play < /dev/null
```

## How it works

```
Doom の C ソース（80 ファイル）
        |
        v
[ Nix の C コンパイラ: cc/ ]   前処理・字句・構文・型検査・コード生成・リンク
        |
        v
Nix の関数   （メモリを受け取り、メモリを返す）
        |
        v
[ ドライバ: doom/ ]   キー入力・仮想の時計・1 ステップ 1 フレーム
        |
        v
フレーム  ->  端末
```

- **コンパイラ（`cc/`）**: C のソースを Nix のソースに変換します。C の各関数は、メモリと引数を受け取って新しいメモリと結果を返す Nix の関数になり、生成したソースは同じ評価の中で import されます。受け付けるのは Doom が使う範囲の C で、C 全体ではありません。Doom が頼っていない部分については、速さのためにあえて C と違う動きにしています（`docs/design.md`）。
- **ホスト（`lib/libc.nix`、`scaffold/platform.nix`、`cc/host.nix`）**: libc の関数と doomgeneric の `DG_*` 呼び出しは、同じメモリを扱う Nix の関数です。
- **ドライバ（`doom/`）**: `doomgeneric_Create` を呼んだあと、1 フレームにつき `doomgeneric_Tick` を 1 回呼びます。キーを読み、時計を進め、画面バッファを端末の大きさに合わせた色付きテキストにして出力します。

評価の制約と、その回避方法です。

- **入力**: 純粋な評価はキーを待てず、FIFO を `builtins.readFile` で読むこともできません。一方、通常ファイルは `readFile` のたびに読み直されます。そこで起動役がキーをファイルへ追記し、ドライバが毎フレームの前に読みます。
- **時間**: 評価は時計を観測できません。Doom の時計は仮想で、ドライバが進めます。1 フレームあたり決まった数の tic（`DOOM_TICS`、既定は 5）を実行します。
- **出力**: 評価中に出力できるのは `builtins.trace` だけで、通常のログ形式ではカーソル移動が落とされます。起動役は Nix を `--log-format internal-json` で動かします。この形式では trace が 1 つのまま残るので、各フレームを前のフレームの上に描けます。
- **押しっぱなしのキー**: 端末は、kitty keyboard protocol か Windows Terminal の win32-input-mode の場合を除いて、キーの離しを通知しません。起動役は端末が対応していればそのどちらかを使い、そうでなければドライバが離しを補います。
- **メモリ**: ゲストのメモリは永続的な 4 段の trie（`lib/mem.nix`）です。書き込みは小さなノード 4 つのコピーで済み、古いメモリもそのまま使えます。

詳しくは `docs/design.md` を参照してください。

## Performance

作者の環境での実測です。

| 項目 | 値 |
|---|---|
| 起動から最初のフレームまで | 約 45 秒（80 ファイルのコンパイル） |
| 3D の場面、160 桁の端末 | 約 6 fps（1 フレーム約 0.17 秒） |
| 最大メモリ | 約 4.6 GB（`GC_INITIAL_HEAP_SIZE=4g` のとき） |

遅いです。1 フレームは、Doom が前提とする毎秒 35 tic には追いつかないので、1 フレームで複数の tic を進めています。時間を縮めるためにやったことです。

- 描画の内側のループ（`R_DrawColumn`、`R_DrawSpan`）を見つけ、1 バイトずつではなく `genList` とまとめ書きで一括計算します。
- 定数番地の読み書きは、リテラルの trie キーで行います。
- ループは段階的に大きくなるかたまりで畳み込み、短いループは早く終わるようにしています。
- ドライバは 3D の窓とステータスバーだけを、端末の大きさに合わせて描き、詰めた色を文字セルごとに合計します。
- 初期ヒープを大きくする（`GC_INITIAL_HEAP_SIZE=4g`）と GC の回数が減り、1 フレームが 8〜12% 速くなりました。

## Limitations

- 音はありません。`nix eval` には音を出す口がありません。
- マウスはありません。
- フレームレートは低めです（上記）。敵の多いマップではさらに遅くなります。
- 時計は仮想です。時間は壁時計ではなく、1 フレームごとに決まった量だけ進みます。
- Doom を終了すると、評価がエラーで終わります。`exit` が `throw` だからです。起動役はそこから終了コードを読み取り、0 なら正常終了として扱います。
- このコンパイラは Doom を動かすためのもので、一般の C コンパイラではありません（`docs/design.md` の "Deliberate deviations from C" を参照）。

## Tested on

| 環境 | 端末 | 結果 |
|---|---|---|
| NixOS-WSL（WSL2）、Nix 2.34.9 | Ghostty の Windows 向けフォーク（kitty keyboard protocol） | 遊べる。同時押しと Ctrl も効く |
| NixOS-WSL（WSL2）、Nix 2.34.9 | Windows Terminal（win32-input-mode） | 遊べる。同時押しと Ctrl も効く |
| NixOS（ノート PC） | Ghostty（kitty keyboard protocol） | 遊べる。まっさらな clone から確認 |

## Repository layout

- `cc/` — Nix 製の C コンパイラ（前処理・字句解析・構文解析・型検査・コード生成・リンク・ホストの接続）。
- `doom/` — ドライバ（doomgeneric のリンク、キー入力、時計、描画、フレームの出力）。
- `lib/` — 32 bit 演算、メモリの trie、libc、RV32IM エミュレータとアセンブラの eDSL。
- `scaffold/`、`toolchain/doom.nix` — clang でビルドした Doom をエミュレータで動かす基準の実行。コンパイルした Doom の答え合わせに使います。
- `toolchain/play.nix` — `nix run .#play` の起動役。
- `tests/` — 1649 件のテスト。`nix eval --raw -f . tests.check` で実行します。
- `bench/`、`examples/` — ベンチマークと小さなゲストプログラム。
- `docs/design.md` — 設計と、C からの意図的な逸脱。

Nix のコードは約 46,000 行です。`CLAUDE.md` は AI アシスタントへの指示書を兼ねた開発メモで、コマンドとファイルの一覧がすべて載っています。

## License

GPL-2.0-or-later です（`LICENSE`）。コンパイラの例・ベンチマーク・テストに、Doom の描画ループ（`R_DrawColumn`、`R_DrawSpan`）を元にした C とその訳が入っているため、リポジトリ全体を GPL にしています。`cc/` の C コンパイラ（`cc/examples/` を除く）は、MIT ライセンスでも使えます（`LICENSE-MIT`）。Doom のソースと WAD はこのリポジトリに含まれず、それぞれのライセンスに従います。

## Acknowledgements

次のプロジェクトを、アイデアの参考として調べました。コードは写していません。

- [psyclyx/nixboy](https://github.com/psyclyx/nixboy)（Nix 製の Game Boy エミュレータ）: `builtins.trace` によるフレームの流し込み、入力のタイムライン、hex 形式の ROM 読み込み。
- [eisbaw/nixcc](https://github.com/eisbaw/nixcc)（Nix 製の C コンパイラ）: 変更を持たない言語には、コンパイラのパイプラインが合うこと。
- [eisbaw/nix-riscv](https://github.com/eisbaw/nix-riscv)（Nix 製の RV32I エミュレータ）。

そして、動かしている中身そのものを作った方々に感謝します。

- id Software: Doom のソースコードの公開。
- [Chocolate Doom](https://www.chocolate-doom.org/): doomgeneric の土台になっているソースポート。
- [ozkl/doomgeneric](https://github.com/ozkl/doomgeneric): 少数のプラットフォーム関数だけで動く Doom の移植。これのおかげで実現できました。

プロジェクトの方針は人間（WakaTaira）が決め、実装の大半は AI（Claude Code）が書きました。人間がレビューと判断を担当しています。
