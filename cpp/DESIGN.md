# C++ 実装 設計メモ

## 全体の流れ

```
main(argc, argv)
  └─ ldf::runCli(args)
       ├─ parseArgs              # オプション解析
       ├─ detectFormat           # フォーマット判定（拡張子）
       ├─ Parser::parse(expr)    # フィルタ文字列 → FilterExpr (AST)
       ├─ phaseLine("ready")     # ← フィルタコンパイル完了後
       └─ withInputLines(inputPath, ...)
            ├─ parseLTSVLine / parseCSVLine → OrderedAttrs
            ├─ filterExpr.evaluate(attrs) → bool
            └─ true のとき stdout << inspectAttrs(attrs) << "\n"
       └─ phaseLine("done")
```

## ファイル構成

```
main.cpp             # エントリポイント（9 行、ldf::runCli を呼ぶだけ）
ldap_filter.hpp      # 全ロジック（単一ヘッダ）
tests/
  test_ldap_filter.cpp
```

全ロジックが `ldap_filter.hpp` に収まる単一ヘッダ構成。`main.cpp` は最小限のエントリポイントのみ。

## レイヤー構造

### 1. タイミング（ベンチ用）

`std::chrono::steady_clock` は単調増加クロック。ナノ秒へは `duration_cast` で変換する。

```cpp
int64_t monotonicNs() {
    using namespace std::chrono;
    return duration_cast<nanoseconds>(steady_clock::now().time_since_epoch()).count();
}
```

| フェーズ | 区間 |
|:---|:---|
| `boot`  | プロセス起動〜フォーマット判定・フィルタコンパイル完了 |
| `ready` | フィルタコンパイル完了（入力処理の開始点） |
| `done`  | 入力の読み取りと出力の完了 |

フィルタコンパイルが `ready` の前に完了する（Ruby と同じ順序）。

### 2. AST（`std::variant` による tagged union）

```cpp
struct FilterExpr {
    using Node = std::variant<FilterAnd, FilterOr, FilterNot, FilterItem>;
    Node node;
    bool evaluate(const OrderedAttrs &attrs) const {
        return std::visit([&](const auto &value) { return value.evaluate(attrs); }, node);
    }
};
```

子ノードは `std::unique_ptr<FilterExpr>` で所有権を管理する。`FilterExpr` はコピーコンストラクタを `= delete` にした move-only 型。
演算子は `FilterItem::Op` として `enum class {Eq, Approx, Ge, Le}` で表現する。

### 3. 順序付き属性（`OrderedAttrs`）

```cpp
struct OrderedAttrs {
    std::vector<std::pair<std::string, std::optional<std::string>>> items;
};
```

`std::optional<std::string>` で `nullopt`（LTSV の空値）と空文字を区別する。
Go / PHP と同じ設計。

### 4. パーサ（`Parser` クラス）

位置カーソル `pos_` を持つクラスで再帰下降。`peek()` / `expect()` で現在位置の文字を操作する。PHP も同じアプローチを採る（Ruby / TypeScript / C# / Go の括弧カウント方式とは異なる）。

```
Parser::parse(expr)
  └─ parseFilter()
       ├─ '&' → parseSubfilters → FilterAnd（各子を再帰）
       ├─ '|' → parseSubfilters → FilterOr（各子を再帰）
       ├─ '!' → parseSubfilters → FilterNot（子は 1 つのみ）
       └─ それ以外 → parseItem → FilterItem
```

演算子の検出には `item.find_first_of("~=><")` を使う。
エラーメッセージには `position` を含め、デバッグを容易にする。

### 5. ワイルドカードマッチング

`ItemMatcher` 構造体でセグメントリストと先頭・末尾スター有無を管理する：

```cpp
struct ItemMatcher {
    enum class Kind { Exact, Presence, Wildcard };
    Kind kind;
    std::vector<std::string> parts;
    bool leading_star, trailing_star;
};
```

`wildcardMatches` 関数がセグメントを左から消費し、位置 `pos` を追跡する：

| 条件 | 処理 |
|:---|:---|
| 先頭セグメント かつ `leading_star=false` | `actual.starts_with(parts[0])` で先頭 anchor |
| 末尾セグメント かつ `trailing_star=false` | `actual.ends_with(parts[end])` で末尾 anchor |
| それ以外 | `actual.find(part, offset)` で最初の出現位置を探索 |

### 6. 近似一致（`~=`）

ローリング配列 + バンド最適化による Levenshtein 距離。`limit` の幅の外は計算をスキップし、行の最小値が `limit` を超えたら早期終了する：

```cpp
const int from = std::max(1, i - limit);
const int to   = std::min(right_len, i + limit);
// ...
prev.swap(curr);  // バッファをスワップ
```

閾値は `<= 2`。

### 7. 入力ソース

`.xz` なら `popen("xz -dc " + shellQuote(inputPath), "r")` でパイプを開く。`shellQuote` は `'...'` 形式でシェルエスケープを行い、`'` を `'"'"'` に置換する。`pclose` の戻り値でエラーを検出する。

通常ファイルは `std::ifstream` + `std::getline` で読み込む。

`withInputLines` テンプレート関数がコールバックを受け取り、各行を `std::string` として渡す：

```cpp
template<typename F>
void withInputLines(const std::string &inputPath, F callback);
```

### 8. フォーマット自動検出

`std::filesystem::path(inputPath).filename().string()` でベース名を取得して拡張子を判定する。

1. `.csv` / `.csv.xz` → CSV
2. `.ltsv` / `.ltsv.xz` → LTSV
3. それ以外 → CSV にフォールバック

### 9. 出力フォーマット（`inspectAttrs`）

`escapeRubyString` で Ruby の `inspect` 形式を再現する。`\\` `\"` `\n` `\r` `\t` を処理する。

CSV の BOM 除去はバイト列 `0xEF 0xBB 0xBF` を直接確認する（`std::string` は UTF-8 バイト列として扱う）：

```cpp
if (line.size() >= 3 &&
    (unsigned char)line[0] == 0xEF &&
    (unsigned char)line[1] == 0xBB &&
    (unsigned char)line[2] == 0xBF) { line = line.substr(3); }
```

## C++ 固有の注意点

| 事項 | 対応 |
|:---|:---|
| `std::variant` のコピー禁止 | `FilterExpr` は move-only（コピーコンストラクタ `= delete`） |
| `popen` の shell injection | `shellQuote` で `'` をエスケープして安全なコマンドを生成 |
| BOM 検出 | バイト列 `0xEF 0xBB 0xBF` を `unsigned char` キャストで確認 |
| `std::isalpha` の符号問題 | `static_cast<unsigned char>` でキャストしてから渡す |
| C++23 必須 | `std::string::starts_with` / `ends_with`、構造化束縛 `auto [value, matcher]` |

## ビルドとテスト

```bash
# ビルド
g++ -std=c++23 -O2 -o ldap_filter main.cpp

# テスト
cd tests && g++ -std=c++23 -O2 -o test_ldap_filter test_ldap_filter.cpp && ./test_ldap_filter

# 実行
./ldap_filter FILTER INPUT
```
