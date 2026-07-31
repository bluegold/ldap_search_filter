# Ruby 実装 設計メモ

## 全体の流れ

```
argv
  └─ bootstrap_yjit!           # exec で YJIT 付き Ruby に切り替え（必要な場合）
       └─ LdapFilterCommand.run
            ├─ LdapFilterParser    # フィルタ文字列 → AST (LdapFilterNode)
            ├─ LdapFilterEvaluator # AST を保持
            └─ 入力ファイル（CSV / LTSV / .xz）
                 │  行ごとに attrs ハッシュへ変換
                 └─ evaluator.evaluate(attrs)
                      └─ node.evaluate(attrs) → true/false
                           └─ true のとき stdout.puts attrs.inspect
```

## ファイル構成

```
ldap_filter.rb          # エントリポイント（YJIT ブートストラップ）
lib/
  ldap_filter.rb        # 各モジュールの require
  ldap_filter/
    error.rb            # LdapFilterError（StandardError のサブクラス）
    node.rb             # AST ノード群
    parser.rb           # フィルタ文字列 → AST
    evaluator.rb        # AST + attrs → true/false
    ltsv.rb             # LTSV パーサ
    cli.rb              # LdapFilterCommand（CLI・ベンチ計測）
test/
  test_helper.rb
  test_ldap_filter.rb   # Minitest によるユニットテスト
```

## レイヤー構造

### 1. タイミング（ベンチ用）

`run` の先頭で `Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond)` を取得し、
`stderr` へフェーズ行を出力する。

```ruby
def self.phase_line(phase, start_ns, now_ns)
  elapsed_ns = now_ns - start_ns
  "phase=#{phase} t=#{elapsed_ns} elapsed_ns=#{elapsed_ns}"
end
```

| フェーズ | 区間 |
|:---|:---|
| `boot`  | プロセス起動〜オプション解析完了 |
| `ready` | フィルタのコンパイル完了（入力処理の開始点） |
| `done`  | 入力の読み取りと出力の完了 |

`t` と `elapsed_ns` はどちらもプロセス起動からの経過ナノ秒（単調増加クロック）。

### 2. YJIT ブートストラップ（エントリポイント）

`bootstrap_yjit!` が `ARGV` から `--jit` / `--no-jit` / `--yjit-stats` を取り出し、
必要なら `exec` で YJIT 有効な Ruby プロセスへ置き換える。

```ruby
ruby_args = [RbConfig.ruby]
ruby_args << "--yjit"         if yjit
ruby_args << "--disable-yjit" if yjit == false
ruby_args << "--yjit-stats"   if yjit_stats
ruby_args << $PROGRAM_NAME
ruby_args.concat(argv)
exec(*ruby_args)
```

`exec` で自身を置き換えるため、二重起動のオーバーヘッドは最小限。
`--jit` と `--no-jit` が同時に渡された場合は `ArgumentError` を発生させる。

### 3. AST ノード（`node.rb`）

すべてのノードは `LdapFilterNode` のサブクラスで `#evaluate(attrs)` を実装する。
生成後は `freeze` して不変にしている。

| クラス           | 役割                                |
|:-----------------|:------------------------------------|
| `LdapFilterItem` | 単一比較（`=` `~=` `>=` `<=`）      |
| `LdapFilterAnd`  | 論理 AND（`all?` で短絡評価）        |
| `LdapFilterOr`   | 論理 OR（`any?` で短絡評価）         |
| `LdapFilterNot`  | 論理 NOT（子は 1 つのみ）            |

`all?` / `any?` は Ruby の Enumerable で最初の `false` / `true` が出た時点で打ち切られる。

```ruby
# LdapFilterAnd
def evaluate(attrs)
  @children.all? { |child| child.evaluate(attrs) }
end
```

### 4. パーサ（`LdapFilterParser`）

位置カーソルを使う手書きの再帰下降パーサ。フィルタを 1 つずつ読み取り、
トップレベルで入力を最後まで消費したことを検証する。

```
parse(filter)
  └─ parse_filter（外側の括弧を検証）
       ├─ "&"       → parse_filter_list → LdapFilterAnd
       ├─ "|"       → parse_filter_list → LdapFilterOr
       ├─ "!"       → parse_filter → LdapFilterNot（子は 1 つのみ）
       └─ それ以外  → parse_item → LdapFilterItem
```

`parse_filter_list` は子フィルタを再帰的に読み取り、`&` / `|` の空リストを拒否する。
`!` は子を 1 つ読み取った後、直ちに閉じ括弧が続くことを検証する。
括弧の不整合や余分な入力は `LdapFilterError` を発生させる。

`parse_item` は属性名・演算子・値をカーソルで抽出する。空の assertion value は許可し、
不正な演算子やエスケープは `LdapFilterError` とする。

`\xx` はバイト列として蓄積した後、UTF-8 として復元する。無効な UTF-8 は拒否する。
これにより、例えば `\e3\81\82` は `あ` になる。

ワイルドカードを含む値（`*` 単体は presence filter）は、リテラル部分とワイルドカードを
分離して `Regexp` に変換する。正規表現は `\A` / `\z` で全体一致にする。
エスケープされた `\2a` はリテラルの `*` として扱う。

```ruby
pattern = segments.map { |part| Regexp.escape(part) }.join(".*")
regex = Regexp.new("\\A#{pattern}\\z")
```

通常文字を `Regexp.escape` し、ワイルドカードだけを `.*` として連結する。
ワイルドカードとリテラルの区別をデコード後の文字列に依存しないことで、
エスケープされたアスタリスクを正しく扱う。

### 5. 評価器（`LdapFilterEvaluator`）

パーサとノードを橋渡しするファサード。引数の型に応じてパース済みノードを取り出す：

```ruby
@rule =
  case filter
  when String      then parser.parse(filter); parser.result
  when LdapFilterNode then filter
  else                 filter&.result
  end
```

`keytype: :symbol` を指定するとパーサが属性名を `Symbol` に変換する。
CSV の `header_converters: :symbol` や LTSV の `symbolize_keys: true` と一致させることで、
キー比較に `String#==` ではなく `Symbol#==` が使われる（高速かつ一意性が保証される）。

```ruby
evaluator = LdapFilterEvaluator.new("(&(host=www.*)(status=200))", keytype: :symbol)
evaluator.evaluate({ host: "www.example.com", status: "200" })  # => true
```

### 6. 近似一致（`~=`）

`did_you_mean` に同梱される `DidYouMean::Levenshtein.distance` を使用する。
外部 gem なしで利用できる（Ruby 2.3+ で標準同梱）。閾値は 3 未満を一致とみなす。

```ruby
when "~="
  actual && DidYouMean::Levenshtein.distance(@value, actual) < 3
```

### 7. LTSV パーサ（`LTSV`）

タブ区切り・コロン分割で各行を `{ key: value }` ハッシュに変換するシンプルな実装。

```ruby
line.split("\t").each_with_object({}) do |entry, result|
  key, value = entry.split(":", 2)
  key = key.to_sym if symbolize_keys
  result[key] = normalize_value(unescape(value))
end
```

`unescape` は `\r` `\n` `\t` `\\` のエスケープシーケンスを展開する。
値が `nil` または空文字の場合は `normalize_value` が `nil` を返す。

### 8. 入力ソース

`.xz` で終わるパスは `Open3.popen3` で `xz -dc` をサブプロセス起動し、
その stdout を IO ストリームとして直接読む。それ以外は単純な `File.open`。

```ruby
stdin, out, stderr, wait_thr = Open3.popen3("xz", "-dc", input_path)
stdin.close
begin
  yield out
ensure
  out.close; stderr.close
  raise ArgumentError, "xz failed..." unless wait_thr.value.success?
end
```

### 9. フォーマット自動検出

`--format auto`（デフォルト）のとき：

1. 拡張子が `.csv` / `.csv.xz` → CSV
2. 拡張子が `.ltsv` / `.ltsv.xz` → LTSV
3. それ以外 → 先頭の非空行にタブが含まれれば LTSV、それ以外は CSV

### 10. 出力フォーマット

一致した行を `attrs.inspect` で 1 行ずつ書き出す。
Ruby のハッシュリテラル形式そのものが出力される：

| キーの形式 | 出力例 |
|:---|:---|
| Symbol キー | `{host: "example.com", status: "200"}` |
| 値が `nil` | `{host: "example.com", status: nil}` |

## Ruby 固有の注意点

| 事項 | 対応 |
|:---|:---|
| `exec` 後の `ARGV` 変更 | `bootstrap_yjit!` が事前に JIT フラグを削除してから渡す |
| `unescape` のバッファ確保 | `String.new(capacity: text.bytesize)` でコピーを最小化 |
| `~=` の外部依存 | `did_you_mean` は Ruby 同梱だが、ロードパスが変わると `require` が失要になる可能性がある |
| `Regexp` の生成コスト | フィルタのパース時に 1 度だけ生成し、`LdapFilterItem` に保持して使い回す |

## テスト

```bash
bundle exec ruby -Itest test/test_ldap_filter.rb
```

テストは Minitest。Parser・Evaluator・Command（CSV / LTSV）の 3 クラスで構成される。
ファイル入出力のテストは `Tempfile` と `StringIO` を組み合わせて行う。

## レビュー結果と対応状況

step1 では、パーサの仕様適合性に関する次の項目を対応済みとした。

- ワイルドカードの全体一致
- エスケープされた `*` とワイルドカードの区別
- UTF-8 エスケープの復元と不正値の拒否
- フィルタ文字列全体の消費検証

残っている項目は、Evaluator の API 整理、Symbol 化方針、ログ依存、名前空間化である。

### 優先度高

- **ワイルドカード正規表現が全体一致になっていない**
  - `Regexp.new(Regexp.escape(value).gsub("\\*", ".*"))` は `\\A` / `\\z` を持たないため、`(host=www.*)` が `xwww.example.com` にも一致する。
  - LDAP の substring filter は値全体に対する一致として扱い、正規表現を使う場合は `\\A` と `\\z` で囲む。
- **エスケープされた `*` とワイルドカードを区別できていない**
  - `\\2a` を先に `*` へデコードしてからワイルドカード化しているため、リテラルのアスタリスクがワイルドカードになる。
  - パース時にリテラル部分とワイルドカードを分離した構造を保持する必要がある。
- **フィルタ文字列全体の消費を検証していない**
  - 外側の括弧を剥がした後、最初のノードだけを解析するため、余分なフィルタや末尾文字列を拒否できない。
  - 最上位で、1 つのフィルタを解析した後に入力が残っていないことを検証する。
- **UTF-8 のエスケープ復元がバイト単位になっている**
  - `\\xx` を `Integer#chr` で個別の文字へ変換している。
  - RFC 4515 のエスケープは UTF-8 バイト列を表すため、連続したバイト列を UTF-8 として復元する必要がある。

### 優先度中

- **Parser が `@result` を持つ状態付き API になっている**
  - `parse` の戻り値とは別に `parser.result` を参照する設計になっている。
  - `parse` が AST を直接返す、状態を持たない API の方が Ruby らしく、再利用やテストもしやすい。
- **属性名を外部入力から Symbol 化している**
  - CSV ヘッダや LTSV キーを `to_sym` している。
  - 外部入力は文字列キーのまま扱う方が安全で、Symbol 化は固定された内部キーに限定する。
- **`evaluate` が常に Boolean を返さない**
  - 属性が存在しない場合、`~=` / `>=` / `<=` が `nil` を返す。
  - API の契約を明確にするため、`false` を返すようにする。
- **ログ経路で `to_yaml` を使うが `yaml` を明示的に require していない**
  - logger を指定した場合だけ実行時エラーになる可能性がある。
  - `require "yaml"` を追加するか、`inspect` など標準的な形式へ統一する。

### 優先度低

- **ライブラリのクラスと定数がトップレベルにある**
  - `LdapFilterNode` や `LTSV` などが他ライブラリと衝突し得る。
  - ライブラリとして公開する場合は `LdapFilter::` 名前空間へまとめる。
- **空の入力や不正な構文のエラー契約が一定していない**
  - 空フィルタなどで `LdapFilterError` 以外の例外になる可能性がある。
  - 構文エラーは専用例外へ統一する。

### 対応方針

まずワイルドカード・エスケープ・UTF-8・入力全体の検証を共通適合性テストとして追加する。その後、Parser の状態をなくし、属性キーと名前空間を見直す。
