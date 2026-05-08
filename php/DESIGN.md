# PHP 実装 設計メモ

## 全体の流れ

```
$argv
  └─ main($argv)
       ├─ parseArgs              # オプション解析（boot の前）
       ├─ phaseLine("boot")
       ├─ detectFormat           # フォーマット判定（拡張子 + スニッフィング）
       ├─ FilterParser::parse    # フィルタ文字列 → FilterExpr (AST)
       ├─ phaseLine("ready")
       └─ withInputHandle(inputPath, ...)
            ├─ fgetcsv / parseLtsvLine → OrderedAttrs
            ├─ $filter->evaluate($attrs) → bool
            └─ true のとき echo inspectAttrs($attrs) . "\n"
       └─ phaseLine("done")
```

## ファイル構成

```
ldap_filter.php          # 全実装（1 ファイル）
test/
  test_ldap_filter.php   # 独自テスト
```

単一ファイルで完結している。`declare(strict_types=1)` をファイル冒頭に記述し、厳格な型チェックを有効にする。
`main()` の呼び出しはエントリポイントのガードで保護し、`require` からも読み込める構造にする。

## レイヤー構造

### 1. タイミング（ベンチ用）

`hrtime(true)` は PHP 7.3+ で利用可能な単調増加クロック。ナノ秒整数を直接返す。

```php
function monotonicNs(): int {
    return hrtime(true);
}
```

| フェーズ | 区間 |
|:---|:---|
| `boot`  | 引数解析完了〜フォーマット判定・フィルタコンパイル開始前 |
| `ready` | フィルタコンパイル完了（入力処理の開始点） |
| `done`  | 入力の読み取りと出力の完了 |

引数解析が `boot` の前に行われる（Ruby と同じ順序）。

### 2. AST（abstract クラス階層）

```php
abstract class FilterExpr {
    abstract public function evaluate(OrderedAttrs $attrs): bool;
}
final class FilterAnd  extends FilterExpr { ... }
final class FilterOr   extends FilterExpr { ... }
final class FilterNot  extends FilterExpr { ... }
final class FilterItem extends FilterExpr { ... }
```

各クラスが `evaluate` を実装することでポリモーフィズムを実現する。

`FilterAnd` は `array_all` 相当のロジックで短絡評価、`FilterOr` は `array_any` 相当のロジックで短絡評価する。

### 3. 順序付き属性（`OrderedAttrs`）

```php
final class OrderedAttrs {
    /** @var array<int, array{0: string, 1: ?string}> */
    private array $items = [];
}
```

`[key, value]` のペア配列（タプルの配列）で挿入順を保持する。
`?string` で `null`（LTSV の空値）と空文字を区別する。Go / C++ と同じ設計。

### 4. パーサ（`FilterParser` クラス）

位置カーソル `$pos` を持つクラスで再帰下降。`peek()` / `expect()` で現在位置の文字を操作する。C++ と同じアプローチ（Ruby / TypeScript / C# / Go の括弧カウント方式とは異なる）。

```
FilterParser::parse(expr)
  └─ parseFilter()
       ├─ '&' → parseSubfilters → FilterAnd（各子を再帰）
       ├─ '|' → parseSubfilters → FilterOr（各子を再帰）
       ├─ '!' → parseSubfilters → FilterNot（子は 1 つのみ）
       └─ それ以外 → parseItem → FilterItem
```

`parseItem()` は `)` が来るまで文字を読み進め、集めた文字列を `preg_match` で分解する：

```php
if (!preg_match('/\A([^~=><]+)(~=|>=|<=|=)(.+)\z/s', $item, $matches)) {
    throw $this->error('error in item syntax', $start);
}
```

値のデコードとワイルドカード解析は `parseItemValue()` トップレベル関数に委譲する。

### 5. ワイルドカードマッチング

`ItemMatcher` クラスで `kind`（`'presence'` / `'exact'` / `'wildcard'`）とセグメント情報を保持する：

```php
final class ItemMatcher {
    public function __construct(
        public string $kind,
        public array  $parts        = [],
        public bool   $leadingStar  = false,
        public bool   $trailingStar = false,
    ) {}
}
```

`wildcardMatches()` トップレベル関数がセグメントを左から消費し、位置 `$offset` を追跡する：

| 条件 | 処理 |
|:---|:---|
| 先頭セグメント かつ `leadingStar=false` | `str_starts_with($actual, $first)` で先頭 anchor |
| 末尾セグメント かつ `trailingStar=false` | `strrpos($actual, $last)` で末尾 anchor |
| それ以外 | `strpos($actual, $part, $offset)` で左から検索 |

### 6. 近似一致（`~=`）

PHP 組み込みの `levenshtein()` 関数を使用。閾値は `<= 2`：

```php
return levenshtein($actual, $this->value) <= 2;
```

他の実装が自前で Levenshtein を実装しているのに対し、PHP は標準関数があるため外部依存なしで利用できる。

### 7. LTSV のアンエスケープ

`str_replace()` の配列形式で一括変換する：

```php
return str_replace(['\\\\', '\t', '\n', '\r'], ['\\', "\t", "\n", "\r"], $text);
```

PHP 文字列の `'\\\\'` は実際の `\\` 2 文字に対応することに注意。

### 8. 入力ソース

`.xz` なら `proc_open()` でサブプロセスを起動し、`$pipes[1]`（stdout）を通常のファイルハンドルとして使う：

```php
$process = proc_open($cmd, $descriptors, $pipes);
fclose($pipes[0]); // stdin を閉じる
// ...yield $pipes[1] as handle
$exitCode = proc_close($process);
if ($exitCode !== 0) { throw new RuntimeException("xz failed: exit $exitCode"); }
```

コマンドは `escapeshellarg()` で安全にエスケープする。通常ファイルは `fopen` で開く。

### 9. フォーマット自動検出

拡張子で判定し、不明な場合はコンテンツスニッフィング（先頭行のタブ有無）を行う（Ruby と同じアプローチ）：

1. `.csv` / `.csv.xz` → CSV
2. `.ltsv` / `.ltsv.xz` → LTSV
3. それ以外 → 先頭行にタブが含まれれば LTSV、含まれなければ CSV

```php
$firstLine = withInputHandle($inputPath, fn($h) => fgets($h));
if ($firstLine !== null && str_contains($firstLine, "\t")) { return 'ltsv'; }
return 'csv';
```

### 10. CSV パーサ

PHP 組み込みの `fgetcsv()` を使用（外部ライブラリ不要）。BOM 除去は最初の行に対して `preg_replace('/^\xEF\xBB\xBF/', '', ...)` で行う。
空行が `[null]` として返ることがあるため、`$row === [null]` で除外する。

### 11. 引数パーサ

`--filter=value` インライン形式と `--filter value` スペース区切り形式の両方を受け付ける：

```php
if (str_starts_with($arg, '--filter=')) {
    $options['filter'] = substr($arg, 9);
}
```

### 12. エントリポイントのガード

テストから `require` で読み込めるよう、`main()` の呼び出しをガードする：

```php
if (PHP_SAPI === 'cli' && realpath($argv[0] ?? '') === __FILE__) {
    exit(main($argv));
}
```

## PHP 固有の注意点

| 事項 | 対応 |
|:---|:---|
| `levenshtein()` の引数順 | `levenshtein($actual, $this->value)`（第 1 引数が実際の値） |
| `fgetcsv()` が返す `[null]` | 空行が `[null]` になるため `$row === [null]` で除外 |
| `str_replace` の配列変換 | `'\\\\'`（PHP 文字列）は `\\` 2 文字に対応することに注意 |
| `proc_close` の戻り値 | 非ゼロなら xz 失敗としてエラーを投げる |
| `declare(strict_types=1)` | ファイル冒頭に必須。ないと型強制（型ジャグリング）が起きる |

## テスト

```bash
# テスト
php test/test_ldap_filter.php

# 実行
php ldap_filter.php FILTER INPUT
```
