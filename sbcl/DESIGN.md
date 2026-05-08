# SBCL 実装 設計メモ

## 全体の流れ

```
argv
  └─ parse-argv
       ├─ parse-filter → AST ノード (defstruct)
       └─ open-input → stream (plain / xz pipe)
                          └─ process-ltsv / process-csv
                               ├─ parse-ltsv-line / parse-csv-line → alist
                               ├─ filter-match (AST を再帰走査)
                               └─ write-attrs → stdout
```

## レイヤー構造

### 1. タイミング（ベンチ用）

`*start-time*` を `main` 冒頭で設定する。  
`save-lisp-and-die` はロード時の状態を凍結するため、**バイナリ起動後に初めて設定**する必要がある。

### 2. AST ノード（`defstruct`）

```
filter-and      → nodes (リスト)
filter-or       → nodes (リスト)
filter-not      → node
filter-item     → attr, op, value, wildcard
wildcard-pattern → parts (ベクタ), leading, trailing
```

CL の `defstruct` は型タグ付きオブジェクトを生成するので、`etypecase` でディスパッチできる。  
クラス（`defclass`）より軽量で構造体アクセスもインライン展開されやすい。

### 3. パーサー（手書き再帰下降）

- **`parse-filter-at`**：`(...)` ブロック 1 個を切り出す。カッコ深さをカウントして対応 `)` を探す。
- **`parse-filter-content`**：先頭文字で `& | ! item` に振り分ける。
- **`parse-item-value`**：`*` でセグメントに分割し `wildcard-pattern` を構築。

`parse-item-value` は `make-string-output-stream` / `get-output-stream-string` を使う。  
adjustable array + `coerce` を使うと `coerce` が同一オブジェクトを返す場合があり、  
fill-pointer リセット後にセグメントが空文字に化けるバグが生じるため。

### 4. マッチング

- **`filter-match`**：`etypecase` で AST を再帰走査。`every` / `some` で AND / OR を評価。
- **`wildcard-matches-p`**：segments を左から順に `search` で消費し、先頭・末尾は anchoring の有無に応じて特殊処理。
  - `leading=nil` → 先頭セグメントは文字列の先頭に anchor
  - `trailing=nil` → 末尾セグメントは文字列の末尾に anchor
  - その他セグメントは `search` で左から最短マッチ
- **`levenshtein-lte`**：ローリング配列（`rotatef prev curr`）で O(m×n) を省メモリに実装。`max-dist` 超えで早期終了。近似一致 (`~=`) の閾値は 2。

### 5. 入力ソース

`.xz` 拡張子なら `sb-ext:run-program` で `xz -dc` をサブプロセス起動し、  
その stdout を文字ストリームとして直接読む。それ以外は単純 `open`。

```lisp
(sb-ext:run-program "xz" (list "-dc" path)
                    :search t :output :stream :external-format :utf-8)
```

### 6. 出力フォーマット

Ruby の `inspect` 相当を再現：

| キーの形式 | 出力例 |
|:---|:---|
| `[A-Za-z_][A-Za-z0-9_]*`（シンボル相当） | `host: "example.com"` |
| それ以外 | `"key-with-dash" => "val"` |

## SBCL 固有の注意点

| 事項 | 対応 |
|:---|:---|
| `save-lisp-and-die` が `--format` 等のフラグを食う | `:save-runtime-options t` |
| 起動時刻がバイナリに凍結される | `*start-time*` を `main` 冒頭で設定 |
| `--jit` / `--no-jit` が positional 引数扱いになる | `parse-argv` で明示的に無視 |
| forward reference（相互再帰） | `declaim ftype` で先行宣言 |
| 最適化 | `(declaim (optimize (speed 3) (safety 1) (debug 0)))` をファイル冒頭に配置 |

## ビルド

```bash
sbcl --noinform --non-interactive \
  --load ldap_filter.lisp \
  --eval '(sb-ext:save-lisp-and-die "ldap_filter" :toplevel #'"'"'main :executable t :save-runtime-options t)'
```

生成バイナリ `ldap_filter` は約 39 MB（SBCL ランタイム込み）。

## テスト

```bash
# ユニットテスト
sbcl --noinform --non-interactive \
  --load ldap_filter.lisp --load test/test_ldap_filter.lisp

# スモークテスト（バイナリ必須）
bash test-smoke.sh
```
