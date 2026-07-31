# ldap_filter

RFC 4515 の LDAP Search Filter を解析し、属性ハッシュを評価する Ruby gem です。

## ライブラリとして使う

```ruby
require "ldap_filter"

filter = LdapFilter.parse("(&(host=www.*)(status>=200))")

LdapFilter.evaluate(filter, {
  "host" => "www.example.com",
  "status" => "200"
})
# => true
```

フィルタ文字列を直接評価することもできます。

```ruby
LdapFilter.evaluate("(host=example.com)", "host" => "example.com")
# => true
```

属性キーを Symbol として扱う場合は `keytype: :symbol` を指定します。

```ruby
LdapFilter.evaluate(
  "(host=example.com)",
  { host: "example.com" },
  keytype: :symbol
)
```

## サンプルアプリ

`ldap_filter.rb` は CSV / LTSV のログを読み込み、一致した行を表示する CLI サンプルです。

```bash
bundle exec ruby ruby/ldap_filter.rb \\
  --format ltsv \\
  '(host=www.*)' \\
  data/access.log.ltsv
```

gem の executable として使う場合は、次のようにビルドして実行できます。

```bash
cd ruby
gem build ldap_filter.gemspec
gem install ./ldap_filter-0.1.0.gem
ldap_filter '(host=www.*)' data/access.log.ltsv
```

CLI はライブラリの利用例として配置しており、入力処理・出力形式・ベンチマーク用のフェーズ計測を確認できます。

## 開発

```bash
cd ruby
bundle install
bundle exec ruby -Itest test/test_ldap_filter.rb
gem build ldap_filter.gemspec
```
