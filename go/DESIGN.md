# Go 実装 設計メモ

## 全体の流れ

```
os.Args[1:]
  └─ run(args, stdout, stderr)
       ├─ parseArgs              # flag パッケージでオプション解析
       ├─ phaseLine("boot")
       ├─ detectFormat           # フォーマット判定
       ├─ parseFilter(expr)      # フィルタ文字列 → filterExpr (AST)
       ├─ openInput(path)        # ファイル / xz パイプを開く
       ├─ phaseLine("ready")
       └─ processInput
            └─ processCSV / processLTSV
                 ├─ parseLTSVLine / encoding/csv → orderedAttrs
                 ├─ ast.match(attrs) → bool
                 └─ true のとき fmt.Fprintln(stdout, inspectAttrs(attrs))
```

## ファイル構成

```
main.go       # 全実装（1 ファイル）
main_test.go  # go test によるユニットテスト
go.mod        # モジュール定義（外部依存なし）
bin/          # gitignore 対象（ビルド成果物）
```

単一ファイルで完結している。パッケージ分割は行っていない。

## レイヤー構造

### 1. タイミング（ベンチ用）

`time.Now()` で開始時刻を取得し、`time.Since(started).Nanoseconds()` で経過を計算する。
Go の `time.Time` は単調増加クロックを内包しており、`Since` は自動的に単調増加読みを使う。

```go
func phaseLine(phase string, started time.Time) string {
  elapsed := time.Since(started).Nanoseconds()
  return fmt.Sprintf("phase=%s t=%d elapsed_ns=%d", phase, elapsed, elapsed)
}
```

| フェーズ | 区間 |
|:---|:---|
| `boot`  | プロセス起動〜オプション解析・フォーマット判定完了 |
| `ready` | フィルタのコンパイルとファイルオープン完了（入力処理の開始点） |
| `done`  | 入力の読み取りと出力の完了 |

### 2. AST（インターフェースと構造体）

```go
type filterExpr interface {
  match(attrs orderedAttrs) bool
}

type filterItem struct { attr, op, value string; wildcard *wildcardPattern }
type filterAnd  struct { nodes []filterExpr }
type filterOr   struct { nodes []filterExpr }
type filterNot  struct { node filterExpr }
```

`filterExpr` インターフェースに `match` メソッドを持たせ、各構造体が実装する。

### 3. 順序付き属性（`orderedAttrs`）

Go の `map` はイテレーション順が不定であるため、`inspectAttrs` の出力を
入力行のフィールド順に揃えるために専用の順序付きコレクションを用意している。

```go
type orderedAttr  struct { key string; value *string }
type orderedAttrs struct { items []orderedAttr }

func (a orderedAttrs) get(key string) (*string, bool) {
  for _, item := range a.items {
    if item.key == key { return item.value, true }
  }
  return nil, false
}
```

`value *string` にすることで、`nil`（LTSV の空値）と空文字を区別している。

### 4. パーサ（`parseFilter`）

再帰下降の手書きパーサ。ファイル全体で最も複雑な部分。

```
parseFilter(expr)
  └─ parseFilterAt(expr, pos)     # "(...)" 1 ブロックを pos 指定で切り出す
       └─ parseFilterContent(str) # 先頭文字で & | ! item に振り分け
            ├─ parseFilterList    # & | の子ノードリストを収集
            └─ parseItem          # attr op value を抽出
                 └─ parseItemValue # 値デコード + wildcardPattern 構築
```

`parseFilterAt` はカッコ深さをカウントして対応する `)` の位置 `end` を探し、
`expr[pos+1 : end]` を `parseFilterContent` に渡す。位置 `end+1` を次の開始点として返す。

`parseItem` は正規表現を使わず、`=` `~` `>` `<` を先頭から線形探索して演算子位置を特定する。

### 5. ワイルドカードマッチング

`parseItemValue` が `*` を区切りにセグメントリストを構築する：

```go
type wildcardPattern struct {
  parts        []string
  leadingStar  bool
  trailingStar bool
}
```

`matches` メソッドはセグメントを左から消費し、位置 `pos` を追跡する：

| 条件 | 処理 |
|:---|:---|
| 先頭セグメント かつ `leadingStar=false` | `strings.HasPrefix` で先頭 anchor |
| 末尾セグメント かつ `trailingStar=false` | `strings.HasSuffix` で末尾 anchor |
| それ以外 | `strings.Index(actual[pos:], part)` で最初の出現位置を探索 |

空のセグメント（`**` や `*abc*` の両端）は事前に `nonEmpty` として除外する。

### 6. 近似一致（`~=`）

ローリング配列による Levenshtein 距離。`rune` スライスに変換してから計算することで
マルチバイト文字（UTF-8）を正しく扱う。閾値は `<= 2`。

```go
func levenshteinLTE(a, b string, maxDistance int) bool {
  ra, rb := []rune(a), []rune(b)
  if abs(len(ra)-len(rb)) > maxDistance { return false } // 早期終了

  prev, curr := make([]int, len(rb)+1), make([]int, len(rb)+1)
  // ...ローリング配列で各行を計算
  for i := 1; i <= len(ra); i++ {
    rowMin := curr[0]
    // ...
    if rowMin > maxDistance { return false } // 行単位の早期終了
    copy(prev, curr)
  }
  return prev[len(rb)] <= maxDistance
}
```

長さ差による早期終了と行単位の早期終了を両方実装している。

### 7. 入力ソース

`.xz` 拡張子なら `exec.Command("xz", "-dc", path)` を起動し、
`cmd.StdoutPipe()` で stdout を `bufio.Reader` に繋ぐ：

```go
cmd := exec.Command("xz", "-dc", path)
stdout, _ := cmd.StdoutPipe()
cmd.Stderr = stderr  // エラーメッセージ取得用
cmd.Start()
return &inputSource{reader: bufio.NewReader(stdout), cmd: cmd, ...}
```

`inputSource.close()` で `cmd.Wait()` を呼び、非ゼロ終了時は stderr の内容をエラーメッセージに含める。

### 8. CSV パーサ

行の読み取りには stdlib の `encoding/csv` を使用する。ヘッダ行の BOM（`\uFEFF`）は
`strings.TrimPrefix` で除去する。

```go
csvReader := csv.NewReader(reader)
headers, _ := csvReader.Read()
headers[0] = strings.TrimPrefix(headers[0], "\ufeff")
```

### 9. フォーマット自動検出

拡張子で判定する。不明な場合は LTSV にフォールバック（Ruby は CSV にフォールバック）。

1. `.csv` / `.csv.xz` → CSV
2. `.ltsv` / `.ltsv.xz` → LTSV
3. それ以外 → LTSV

### 10. 出力フォーマット（`inspectAttrs`）

Ruby の `inspect` 形式を手動で再現する。`isRubySymbolName` でキーが Ruby の識別子として
有効かどうかを判定し、形式を切り替える：

```go
func formatKey(key string) string {
  if isRubySymbolName(key) { return key + ": " }
  return fmt.Sprintf("%q => ", key)
}
func formatValue(value *string) string {
  if value == nil { return "nil" }
  return fmt.Sprintf("%q", *value)
}
```

`fmt.Sprintf("%q", s)` は Go の文字列引用形式（`"..."` + Go エスケープ）を出力するが、
基本的な ASCII 制御文字は Ruby の `inspect` と同じエスケープになる。

### 11. 引数パーサ

`flag.FlagSet` を使用。`--jit` / `--no-jit` / `--yjit` / `--yjit-stats` は
`fs.Bool("jit", false, "ignored")` のように登録して静かに無視する。

`flag.ContinueOnError` + `fs.SetOutput(io.Discard)` でエラー時に stderr への自動出力を抑制し、
エラーは `run` の呼び出し元に返す。

## Go 固有の注意点

| 事項 | 対応 |
|:---|:---|
| `map` の非決定的順序 | `orderedAttrs`（スライス）で挿入順を保持 |
| `nil` と空文字の区別 | `value *string` でキー不在・nil 値・空文字を区別 |
| rune vs byte | Levenshtein は `[]rune` に変換してから計算 |
| `time.Since` の単調性 | Go 1.9+ から `time.Time` に単調クロックが埋め込まれている |
| `flag` の `-` / `--` 両対応 | `flag` パッケージは `-flag` と `--flag` を同等に扱う |
| フォールバックフォーマット | 不明な拡張子は LTSV（Ruby は CSV） |

## ビルドとテスト

```bash
# ビルド
go build -o bin/ldap_filter .

# テスト
go test ./...

# 実行
./bin/ldap_filter FILTER INPUT
```
