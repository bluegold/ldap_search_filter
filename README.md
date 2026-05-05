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
- `csharp/` - C# / .NET 10 実装
- `data/` - ベンチマーク用データ置き場

## `data/` について

`data/` 配下にはベンチマーク用の大きなデータを置く想定です。
サイズが大きいため、原則として git には含めません。

必要なデータは各自の作業環境に配置してください。

## 動作確認とベンチマーク

- `tools/bench.rb` で各実装を同じフィルタ・同じ入力で実行できます
- 入力が `.xz` の場合は、ツール側で一時展開します
- 実装一覧と build 手順は `tools/bench.yml` に書きます
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
- C# 実装は .NET 10 で動きます
- `tools/bench.yml` では C# 実装を `csharp` として定義しています
- C# 実装は `tools/bench.rb` で `dotnet build -c Release` を build として実行してから、`dotnet csharp/bin/Release/net10.0/LdapFilter.dll ...` を使います

TypeScript 実装を手動で使う場合は、`typescript/` ディレクトリで `tsc -p tsconfig.json` を実行してから、`node dist/index.js ...` または `bun dist/index.js ...` を使ってください。

TypeScript 実装のテストは `typescript/` ディレクトリで `npm test` を実行します。build も含めて確認します。

`csharp/` の unit test は `cd csharp && env DOTNET_CLI_HOME=/tmp/ldf-dotnet DOTNET_SKIP_FIRST_TIME_EXPERIENCE=1 DOTNET_NOLOGO=1 dotnet run --project tests/LdapFilter.Tests.csproj -c Release` で実行します。

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
