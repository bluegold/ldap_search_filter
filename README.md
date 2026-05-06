# LDAP Search filter

LDAP Search Filter (RFC 4515) を読み取り、CSV / LTSV のログ行をフィルタして表示する実装を、複数の言語で試すためのリポジトリです。

## 概要

- フィルタ条件は RFC 4515 の文字列表現を使います
- 入力ログは 1 行ずつ評価します
- 条件に一致した行だけを表示します

## 参照資料

- [RFC 4515](rfc4515.txt)
- [Ruby サンプル実装](ruby/ldap_filter.rb)
- Ruby 依存定義は [ruby/Gemfile](ruby/Gemfile) にあります

Ruby 実装を bundle 経由で使う場合は、`ruby/` ディレクトリで `bundle install` してください。

## ディレクトリ構成

- `ruby/` - Ruby 実装のサンプル
- `typescript/` - TypeScript 実装
- `python/` - Python 実装
- `php/` - PHP 実装
- `csharp/` - C# / .NET 10 実装
- `csharp-aot/` - C# / .NET 10 NativeAOT 実装
- `zig/` - Zig 実装
- `rust/` - Rust 実装
- `go/` - Go 実装
- `go-switch/` - Go の struct + switch 実装
- `data/` - ベンチマーク用データ置き場

## `data/` について

`data/` 配下にはベンチマーク用の大きなデータを置く想定です。
サイズが大きいため、原則として git には含めません。

必要なデータは各自の作業環境に配置してください。

## 動作確認とベンチマーク

各実装の動作確認とパフォーマンス計測のために、Ruby 製のベンチマークドライバ `tools/bench.rb` を用意しています。

### ベンチマークツール (`tools/bench.rb`)

各言語の実装を同一のフィルタと入力データで実行し、標準出力の一致確認（Ruby 実装を正解とする）と実行時間の計測を自動で行います。

- **基本コマンド**:
  ```bash
  ruby tools/bench.rb --filter '(uid=foo)' --input data/access.log.xz
  ```
- **主なオプション**:
  - `--jit` / `--no-jit`: JIT 有効化の切り替え（実装が対応している場合）
  - `--verbose`: 各実装の標準出力をそのまま表示
  - `--timestamp`: 各実装が stderr に出力する `phase=...` を解析して表示。`ready` を `parse`、`done` を `processing` として集計します（`t` と `elapsed_ns` は同一視されます）。
- **ベンチマークの定義 (`tools/bench.yml`)**:
  - 各実装のビルド手順や実行コマンドを定義します。
  - `target` と `sources` を指定することで、ソース変更がない場合のビルド省略が可能です。
  - `size_target` を指定すると、ビルド後のバイナリサイズを表示できます。NativeAOT 等では publish ディレクトリを指定することで、ランタイムを含めたサイズを確認できます。

### 実装一覧

| 名前 | 言語 | 実行環境 / ビルド方法 | 特徴・備考 |
| :--- | :--- | :--- | :--- |
| `ruby` | Ruby | CRuby 3.3+ | 基準実装。`--yjit` などのフラグに対応 |
| `typescript` | TypeScript | Node.js | `tsc` でビルド |
| `typescript-bun`| TypeScript | Bun | `typescript` と同一ソース |
| `python` | Python | Python 3 | |
| `csharp` | C# | .NET 10 | |
| `csharp-aot` | C# | .NET 10 (NativeAOT) | `dotnet publish` による自己完結型バイナリ |
| `zig` | Zig | Zig 0.13+ | `ReleaseFast` 最適化 |
| `rust` | Rust | Rust (Cargo) | `--release` 最適化 |
| `go` | Go | Go | |
| `go-switch` | Go | Go | `struct + switch` による最適化版 |

### テストの実行

プロジェクト全体のテストは `just` を使用してまとめて実行できます。

```bash
just test
```

各言語ごとの個別テスト実行コマンド：

| 対象 | コマンド |
| :--- | :--- |
| **Ruby** | `cd ruby && bundle exec ruby -Itest test/test_ldap_filter.rb` |
| **TypeScript** | `cd typescript && npm test` |
| **Python** | `cd python && python3 -m unittest discover -s test -p 'test_*.py'` |
| **PHP** | `cd php && php test/test_ldap_filter.php` |
| **C#** | `cd csharp && dotnet run --project tests/LdapFilter.Tests.csproj -c Release` |
| **C# (AOT)** | `cd csharp-aot && ./test-smoke.sh` (ビルド後実行) |
| **Zig** | `cd zig && zig build test` |
| **Rust** | `cd rust && cargo test` |
| **Go** | `cd go && go test ./...` |
| **Go (Switch)** | `cd go-switch && go test ./...` |
| **Bench Tool** | `ruby tools/test/bench_test.rb` |

### 実行例

**ベンチマークツールの実行:**
```bash
ruby tools/bench.rb --filter '(uid=foo)' --input data/access.log.xz
```

**Ruby 実装の直接実行:**
```bash
cd ruby
bundle exec ruby ./ldap_filter.rb --jit --format ltsv '(host=*)' ../data/access.log.xz
```

**TypeScript 実装 (Node.js) の手動ビルドと実行:**
```bash
cd typescript
npx tsc -p tsconfig.json
node dist/index.js --format ltsv '(host=*)' ../data/access.log.xz
```

**PHP 実装の手動実行:**
```bash
php php/ldap_filter.php --format ltsv '(host=*)' data/access.log.xz
```


## LDAP フィルタの例

動作確認に使用できる、RFC 4515 に準拠したフィルタの例です。

- `(&(objectCategory=person)(objectClass=contact)(|(sn=Smith)(sn=Johnson)))`
    - `objectCategory` が `person` かつ `objectClass` が `contact` で、かつ `sn` が `Smith` または `Johnson` であるもの
- `(&(attr1=a)(&(attr2=b)(&(attr3=c)(attr4=d))))`
    - `attr1=a`, `attr2=b`, `attr3=c`, `attr4=d` のすべてを満たすもの（AND のネスト）
- `(|(cn=super)(!(ou=tmp))(&(cn=kaneko)(ou=hoge)))`
    - `cn` が `super` であるか、`ou` が `tmp` 以外であるか、または `cn` が `kaneko` かつ `ou` が `hoge` であるもの
- `(|(cn=super)(&(cn=kaneko)(ou=hoge)))`
    - `cn` が `super` であるか、または `cn` が `kaneko` かつ `ou` が `hoge` であるもの
- `(&(objectClass=Person)(|(sn=Jensen)(cn=Babs J*)))`
    - `objectClass` が `Person` で、かつ `sn` が `Jensen` または `cn` が `Babs J` で始まるもの

※ `!` (NOT) 演算子は RFC 4515 の規定により単一のフィルタのみを引数に取ります。複数の条件を否定したい場合は `(!(&(attr1=val1)(attr2=val2)))` のように `&` や `|` と組み合わせて記述します。

## 実装方針

- まず Ruby サンプルの挙動に合わせてください
- 仕様の確認が必要な場合は RFC 4515 を参照してください
- 各言語の実装は、読みやすさと比較しやすさを優先してください

## 期待する振る舞い

- `&` / `|` / `!` を含む論理式を扱えること
- `=` / `~=` / `>=` / `<=` を扱えること
- `*` を含む一致条件を扱えること
- CSV / LTSV の各行を評価して、真になった行を表示すること

## 追加する場合

新しい言語の実装を追加するときは、言語ごとにディレクトリを分けてください。
必要なら、その言語用の実行方法やテスト方法を各ディレクトリ内に置いてください。
