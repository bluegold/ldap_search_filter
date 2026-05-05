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
- `data/` - ベンチマーク用データ置き場

## `data/` について

`data/` 配下にはベンチマーク用の大きなデータを置く想定です。
サイズが大きいため、原則として git には含めません。

必要なデータは各自の作業環境に配置してください。

## 動作確認とベンチマーク

- `tools/bench.rb` で各実装を同じフィルタ・同じ入力で実行できます
- 入力が `.xz` の場合は、ツール側で一時展開します
- 実装一覧は `tools/bench.yml` に書きます
- `--jit` / `--no-jit` で JIT の有無を指定できます
- ドライバが入力ファイル名から `csv` / `ltsv` を決めて、実装に `--format` を渡します
- 既定では Ruby 実装を基準に stdout を比較し、あわせて実行時間も表示します
- `--verbose` を付けると、各実装の stdout / stderr をそのまま表示します
- Ruby 実装は `--format auto|csv|ltsv` を受け付けます
- Ruby 実装は `stderr` に `phase=boot` / `phase=ready` / `phase=done` を出します
- Ruby 実装は起動前フラグとして `--jit` / `--no-jit` / `--yjit` / `--no-yjit` / `--yjit-stats` を受け付けます

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
