# Rust 実装 設計メモ

## 全体の流れ

```
env::args()
  └─ run_with_io(&args, stdout, stderr)
       ├─ parse_args             # オプション解析
       ├─ phase_line("boot")
       ├─ detect_format          # フォーマット判定
       ├─ parse_filter(&filter)  # フィルタ文字列 → FilterExpr (AST)
       ├─ InputSource::open      # ファイル / xz パイプを開く
       ├─ phase_line("ready")
       ├─ process_input          # 行ごとに attrs → evaluate → 出力
       ├─ input_source.finish()  # xz プロセスの終了待ち
       └─ phase_line("done")
```

## ファイル構成

```
src/
  lib.rs    # 全ロジック（パーサ・評価器・入出力・CLI）
  main.rs   # エントリポイント（run_with_io 呼び出しのみ）
Cargo.toml  # 外部依存なし
tests/      # 統合テスト
```

`lib.rs` にすべてのロジックを集約し、`main.rs` は 14 行のシン・エントリポイント。
外部クレートへの依存は一切ない。

## レイヤー構造

### 1. タイミング（ベンチ用）

`Instant::now()` で開始時刻を取得し、`elapsed().as_nanos()` で経過ナノ秒を得る。

```rust
pub fn phase_line(phase: &str, started: Instant) -> String {
    let elapsed_ns = started.elapsed().as_nanos();
    format!("phase={} t={} elapsed_ns={}", phase, elapsed_ns, elapsed_ns)
}
```

| フェーズ | 区間 |
|:---|:---|
| `boot`  | プロセス起動〜オプション解析完了 |
| `ready` | フィルタコンパイル・ファイルオープン完了（入力処理の開始点） |
| `done`  | 入力の読み取りと出力の完了 |

### 2. AST 型

再帰 enum で AST を表現する。`Box` で再帰を可能にする：

```rust
pub enum FilterExpr {
    And(Vec<FilterExpr>),
    Or(Vec<FilterExpr>),
    Not(Box<FilterExpr>),
    Item(FilterItem),
}
```

`FilterItem` が持つ `ValueMatcher` は非公開 enum：

```rust
enum ValueMatcher {
    Presence,
    Exact(String),
    Wildcard(WildcardPattern),
}
```

`FilterOp` は `enum class { Eq, Approx, Ge, Le }` で演算子を型安全に表す。

### 3. `OrderedAttrs`

```rust
pub struct OrderedAttrs {
    items: Vec<(String, Option<String>)>,
}
```

`get` は `Option<Option<&str>>` を返す：

```rust
pub fn get(&self, key: &str) -> Option<Option<&str>> { ... }
```

- `None` → キーが存在しない
- `Some(None)` → キーは存在するが値が `null`（LTSV の空値）
- `Some(Some(&str))` → 値あり

この 3 値区別により presence filter と値比較を正確に処理できる。

### 4. パーサ（`Parser`）

文字カーソル方式。入力文字列を `chars: Vec<char>` に展開して `pos: usize` で追跡する：

```rust
struct Parser {
    chars: Vec<char>,
    pos: usize,
}
```

`char` スライスを使うことで UTF-8 を正しくコードポイント単位で処理できる。

```
parse_filter()
  └─ expect('(')
  └─ parse_filter_comp()
       ├─ peek() == '&' → parse_group_list() → FilterExpr::And
       ├─ peek() == '|' → parse_group_list() → FilterExpr::Or
       ├─ peek() == '!' → parse_filter() → FilterExpr::Not
       └─ else → parse_item() → FilterExpr::Item
  └─ expect(')')
```

`parse_item` は `take_until_operator()` で属性名を切り出し、演算子文字を消費し、
`take_until(')')` で値文字列を取得する。

### 5. ワイルドカードマッチング

`WildcardPattern` でセグメント情報を保持する：

```rust
struct WildcardPattern {
    parts: Vec<String>,
    leading_star: bool,
    trailing_star: bool,
}
```

`matches` メソッドはセグメントを左から消費：
- `leading_star=false` → `actual[pos..].starts_with(part)` で先頭 anchor
- `trailing_star=false` → `actual[pos..].ends_with(part)` で末尾 anchor
- 中間セグメントは `actual[pos..].find(part)` で左から検索

### 6. 近似一致（`~=`）

ローリング配列 + 行単位の早期終了。`char` で収集してから計算する：

```rust
fn levenshtein_distance_lte(a: &str, b: &str, max_distance: usize) -> bool {
    let a_chars: Vec<char> = a.chars().collect();
    let b_chars: Vec<char> = b.chars().collect();
    // ...
    if row_min > max_distance { return false; }
    std::mem::swap(&mut prev, &mut curr);
}
```

`std::mem::swap` でバッファを交換する。長さ差による早期終了も実装している。閾値は `<= 2`。

### 7. 入力ソース

`InputSource` 構造体が `Box<dyn BufRead>` を抽象化する：

```rust
struct InputSource {
    reader: Box<dyn BufRead>,
    child: Option<Child>,
}
```

`.xz` なら `Command::new("xz").args(["-dc", path]).stdout(Stdio::piped())` で起動し、
stdout を `BufReader` でラップする。`finish()` が `child.wait()` を呼んで終了コードを確認する。

### 8. CSV / LTSV パーサ

**CSV**（`parse_csv_line`）：`Peekable<Chars>` を使う手書き RFC 4180 状態機械。BOM は `trim_start_matches('\u{feff}')` で除去する。

**LTSV**（`parse_ltsv_line`）：`split('\t')` → `find(':')` で分割し、`unescape_ltsv_value` でエスケープを展開する。`normalize_ltsv_value` がアンエスケープ後の空文字を `None` に変換する。

### 9. フォーマット自動検出

拡張子で判定。不明な場合は LTSV にフォールバック（Ruby は CSV）。

1. `.csv` / `.csv.xz` → CSV
2. `.ltsv` / `.ltsv.xz` → LTSV
3. それ以外 → LTSV

### 10. 出力フォーマット

`escape_ruby_string` は `\\` と `\"` のみをエスケープする（制御文字は非対応）：

```rust
fn escape_ruby_string(text: &str) -> String {
    text.replace('\\', "\\\\").replace('"', "\\\"")
}
```

## Rust 固有の注意点

| 事項 | 対応 |
|:---|:---|
| `Box<FilterExpr>` | `Not` の再帰を可能にするための間接参照 |
| `Option<Option<&str>>` | キー不在・null 値・通常値の 3 値区別 |
| `Vec<char>` でのパース | UTF-8 コードポイント単位の安全な操作 |
| `Box<dyn BufRead>` | ファイルと xz パイプを同一の型で扱う |
| `std::mem::swap` | ローリング配列の交換をゼロコピーで行う |
| `xz` の stderr | `Stdio::null()` で破棄（エラーメッセージは "xz failed" のみ） |

## ビルドとテスト

```bash
# ビルド
cargo build --release

# テスト
cargo test

# 実行
./target/release/ldf FILTER INPUT
```
