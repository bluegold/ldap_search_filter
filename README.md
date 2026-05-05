# ldf

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

- `tools/bench.rb` で各実装を同じフィルタ・同じ入力で実行できます
- 入力が `.xz` の場合は、ツール側で一時展開します
- 実装一覧と build 手順は `tools/bench.yml` に書きます
- `build` に `target` と `sources` を書くと、`target` が `sources` より新しい場合は build を省略します
- `build` に `size_target` を書くと、`ok` / `up to date` の後ろにそのサイズを表示します。AOT では publish ディレクトリを指すと runtime を含めたサイズを見られます
- `--jit` / `--no-jit` で JIT の有無を指定できます
- ドライバが入力ファイル名から `csv` / `ltsv` を決めて、実装に `--format` を渡します
- 既定では Ruby 実装を基準に stdout を比較し、あわせて実行時間も表示します
- `--verbose` を付けると、各実装の stdout をそのまま表示します
- `--timestamp` を付けると、各実装の stderr に出た `phase=...` を解析して benchmark 行の下に表示します
- `phase` の `t` と `elapsed_ns` は同じ意味なので、bench では `elapsed_ns` だけ使います
- 表示上は `ready` を `parse`、`done` を `processing` として出します
- Ruby 実装は `--format auto|csv|ltsv` を受け付けます
- Ruby 実装は `stderr` に `phase=boot` / `phase=ready` / `phase=done` を出します
- Ruby 実装は起動前フラグとして `--jit` / `--no-jit` / `--yjit` / `--no-yjit` / `--yjit-stats` を受け付けます
- TypeScript 実装は `--jit` / `--no-jit` を受け取りますが、現時点では no-op です
- TypeScript 実装は `node` と `bun` の両方で実行できます
- `tools/bench.yml` では TypeScript の `node` 実行を `typescript`、`bun` 実行を `typescript-bun` として定義しています
- TypeScript 実装は `tools/bench.rb` で `tsc -p tsconfig.json` を build として実行してから、`node dist/index.js ...` または `bun dist/index.js ...` を使います
- Python 実装は `tools/bench.yml` では `python` として定義しています
- Python 実装は `tools/bench.rb` で `python3 python/ldap_filter.py ...` を使います
- C# 実装は .NET 10 で動きます
- `tools/bench.yml` では C# 実装を `csharp` として定義しています
- C# 実装は `tools/bench.rb` で `dotnet build -c Release` を build として実行してから、`dotnet csharp/bin/Release/net10.0/LdapFilter.dll ...` を使います
- C# NativeAOT 実装は `tools/bench.yml` では `csharp-aot` として定義しています
- C# NativeAOT 実装は `tools/bench.rb` で `dotnet publish -c Release -r linux-x64 -p:PublishAot=true -p:SelfContained=true` を build として実行してから、`csharp-aot/bin/Release/net10.0/linux-x64/publish/LdapFilter.Aot ...` を使います
- Zig 実装は `tools/bench.yml` では `zig` として定義しています
- Zig 実装は `tools/bench.rb` で `zig build -Doptimize=ReleaseFast` を build として実行してから、`zig/zig-out/bin/ldap_filter ...` を使います
- Rust 実装は `tools/bench.yml` では `rust` として定義しています
- Rust 実装は `tools/bench.rb` で `cargo build --release --locked` を build として実行してから、`rust/target/release/ldf ...` を使います
- Go 実装は `tools/bench.yml` では `go` として定義しています
- Go 実装は `tools/bench.rb` で `env GOCACHE=/tmp/ldf-gocache go build -o bin/ldap_filter .` を build として実行してから、`go/bin/ldap_filter ...` を使います
- Go の比較版は `tools/bench.yml` では `go-switch` として定義しています
- Go の比較版は `tools/bench.rb` で `env GOCACHE=/tmp/ldf-gocache go build -o bin/ldap_filter .` を build として実行してから、`go-switch/bin/ldap_filter ...` を使います

TypeScript 実装を手動で使う場合は、`typescript/` ディレクトリで `tsc -p tsconfig.json` を実行してから、`node dist/index.js ...` または `bun dist/index.js ...` を使ってください。

TypeScript 実装のテストは `typescript/` ディレクトリで `npm test` を実行します。build も含めて確認します。

Python 実装のテストは `cd python && python3 -m unittest discover -s test -p 'test_*.py'` で実行します。

`csharp/` の unit test は `cd csharp && env DOTNET_CLI_HOME=/tmp/ldf-dotnet DOTNET_SKIP_FIRST_TIME_EXPERIENCE=1 DOTNET_NOLOGO=1 dotnet run --project tests/LdapFilter.Tests.csproj -c Release` で実行します。

`csharp-aot/` の smoke test は `cd csharp-aot && env DOTNET_CLI_HOME=/tmp/ldf-dotnet DOTNET_SKIP_FIRST_TIME_EXPERIENCE=1 DOTNET_NOLOGO=1 dotnet publish LdapFilter.Aot.csproj -c Release -r linux-x64 -p:PublishAot=true -p:SelfContained=true` の後に、生成された NativeAOT バイナリを 1 回実行して確認します。
スモーク用の実行内容は [csharp-aot/test-smoke.sh](csharp-aot/test-smoke.sh) に置いてあります。

`zig/` の unit test は `cd zig && zig build test` で実行します。

`rust/` の unit test は `cd rust && cargo test` で実行します。

`go/` の unit test は `cd go && env GOCACHE=/tmp/ldf-gocache go test ./...` で実行します。

`go-switch/` の unit test は `cd go-switch && env GOCACHE=/tmp/ldf-gocache go test ./...` で実行します。

`tools/bench.rb` のテストは `ruby tools/test/bench_test.rb` で実行します。

まとめて実行する場合は `just test` を使います。

例:

```bash
cd ruby
bundle exec ruby ./ldap_filter.rb --jit --format ltsv '(host=*)' ../data/kentei-access.log.xz
```

例:

```bash
ruby tools/bench.rb --filter '(uid=foo)' --input data/kentei-access.log.xz
```

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
