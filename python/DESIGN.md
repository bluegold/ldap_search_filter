# Python 実装 設計メモ

## 全体の流れ

```
argv
  └─ run_with_io(argv)
       ├─ phase_line("boot")       # argparse の前に計測開始
       ├─ argparse.ArgumentParser  # オプション解析
       ├─ detect_format            # フォーマット判定
       ├─ parse_filter(expr)       # フィルタ文字列 → FilterExpr (AST)
       ├─ open_input(path)         # ファイル / lzma.open
       ├─ CSVなら header 読み取り
       ├─ phase_line("ready")      # 入力処理の開始点
       ├─ 行ごとに attrs → evaluate → 出力
       └─ phase_line("done")
```

## ファイル構成

```
ldap_filter.py       # 全実装（1 ファイル）
test/
  test_ldap_filter.py
```

## レイヤー構造

### 1. タイミング（ベンチ用）

`time.perf_counter_ns()` で単調増加クロックをナノ秒整数で取得する。

```python
def phase_line(phase: str, started_ns: int) -> str:
    elapsed_ns = time.perf_counter_ns() - started_ns
    return f"phase={phase} t={elapsed_ns} elapsed_ns={elapsed_ns}"
```

| フェーズ | 区間 |
|:---|:---|
| `boot`  | プロセス起動直後（`argparse` の前） |
| `ready` | CSV ヘッダ読み取り完了・入力処理の開始点 |
| `done`  | 入力の読み取りと出力の完了 |

`boot` を `argparse` より先に出すため、`started_ns` の取得と `boot` の出力はオプション解析の前に行う。
これは他のほとんどの実装（Ruby・Go・Rust など）とは異なる点。

### 2. AST ノード

`@dataclass(frozen=True)` を使ったイミュータブルなノード群。`frozen=True` により `__hash__` が自動生成される。

```python
@dataclass(frozen=True)
class FilterAnd(FilterExpr):
    children: tuple[FilterExpr, ...]

    def evaluate(self, attrs: OrderedAttrs) -> bool:
        return all(child.evaluate(attrs) for child in self.children)
```

| クラス       | 役割 |
|:------------|:---|
| `FilterAnd`  | 論理 AND（`all()` で短絡評価） |
| `FilterOr`   | 論理 OR（`any()` で短絡評価） |
| `FilterNot`  | 論理 NOT |
| `FilterItem` | 単一比較（`=` `~=` `>=` `<=`） |

`tuple` でなく `list` を使うと `frozen=True` でエラーになるため、子ノードは `tuple[FilterExpr, ...]` で保持する。

### 3. `_MISSING` センチネル

`OrderedAttrs.get` は「キー不在」と「値が `None`」を区別するため、
モジュールレベルのシングルトン `_MISSING = object()` を使う：

```python
def get(self, key: str):
    for candidate, value in self.items:
        if candidate == key:
            return value
    return _MISSING
```

呼び出し側は `actual is _MISSING` でキー不在を判定する。
`Optional[str]` の `None` と区別できるため、LTSV の空値（`None`）と存在しないキーを正しく扱える。

### 4. パーサ（`FilterParser`）

位置カーソル `self.pos` を持つクラスで再帰下降。`_peek()` / `_expect()` で現在位置の文字を操作する。
PHP・C++ と同じアプローチ。

```
parse()
  └─ _parse_filter()
       ├─ "&" → _parse_subfilters() → FilterAnd
       ├─ "|" → _parse_subfilters() → FilterOr
       ├─ "!" → _parse_filter() → FilterNot
       └─ else → _parse_item() → FilterItem
```

`_parse_item()` は `)` が来るまで文字を読み進め、集めた文字列を `_ITEM_RE` で分解する。

### 5. ワイルドカードマッチング

`ItemMatcher` dataclass でマッチング情報を保持する：

```python
@dataclass(frozen=True)
class ItemMatcher:
    kind: str          # "presence" | "exact" | "wildcard"
    parts: tuple[str, ...] = ()
    leading_star: bool = False
    trailing_star: bool = False
```

`wildcard_matches()` トップレベル関数がセグメントを左から消費：
- `leading_star=False` → `actual[pos:].startswith(part)` で先頭 anchor
- `trailing_star=False` → `actual[pos:].endswith(part)` で末尾 anchor
- 中間セグメントは `actual.find(part, pos)` で左から検索

### 6. 近似一致（`~=`）

ローリング配列による Levenshtein 距離。`list` でスワップし、行の最小値が閾値を超えたら早期終了する：

```python
prev, curr = curr, prev   # ローリングスワップ
```

`a_chars = list(a)` でコードポイント単位に分割してから計算することで、マルチバイト文字を正しく扱う。閾値は `<= 2`。

### 7. 入力ソース

`.xz` 拡張子なら `lzma.open(path, "rt", encoding="utf-8")` でそのまま開く。
サブプロセスを起動する必要がなく、Python 標準ライブラリだけで完結する。

```python
def open_input(path: str):
    if path.lower().endswith(".xz"):
        return lzma.open(path, "rt", encoding="utf-8", newline="")
    return open(path, "rt", encoding="utf-8", newline="")
```

### 8. CSV パーサ

Python 標準の `csv.reader` を使用。1 行ずつ `csv.reader([line])` に渡して解析する。

```python
def parse_csv_line(line: str) -> list[str]:
    reader = csv.reader([line])
    return next(reader)
```

BOM は `line.lstrip("\ufeff")` で除去する。

### 9. フォーマット自動検出

拡張子で判定。不明な場合は LTSV にフォールバック（Ruby は CSV）。

1. `.csv` / `.csv.xz` → CSV
2. `.ltsv` / `.ltsv.xz` → LTSV
3. それ以外 → LTSV

### 10. 出力フォーマット

`json.dumps(text)[1:-1]` で Ruby の文字列エスケープを近似する：

```python
def escape_ruby_string(text: str) -> str:
    return json.dumps(text)[1:-1]
```

`json.dumps` の結果から前後の `"` を取り除く。JSON エスケープと Ruby エスケープは基本的な制御文字で一致する。

### 11. 引数パーサ

`argparse.ArgumentParser` を使用。`--jit` / `--no-jit` は `add_mutually_exclusive_group()` で登録して静かに無視する。

## Python 固有の注意点

| 事項 | 対応 |
|:---|:---|
| `boot` の位置 | `argparse` より先に出力（他の実装と異なる） |
| `_MISSING` センチネル | `None` と「キー不在」を区別するためのシングルトン |
| `frozen=True` + `tuple` | `list` は `frozen=True` の dataclass に使えないため子ノードは `tuple` |
| `lzma.open` | xz 解凍にサブプロセス不要（Python 標準ライブラリで完結） |
| `list(a)` でコードポイント分割 | `str` のインデックスアクセスはコードポイント単位のため `list` 化は実質不要だが明示的に行う |

## テスト

```bash
python test/test_ldap_filter.py
```
