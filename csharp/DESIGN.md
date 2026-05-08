# C# 実装 設計メモ

## 全体の流れ

```
args
  └─ Run(args, stdout, stderr)
       ├─ ParseArgs              # オプション解析
       ├─ phaseLine("boot")
       ├─ detectFormat           # フォーマット判定（拡張子）
       ├─ phaseLine("ready")     # ← フィルタコンパイルの前
       ├─ Parser.ParseFilter     # フィルタ文字列 → FilterNode (AST)
       └─ await foreach ReadRowsAsync
            ├─ OrderedAttrs へ変換
            ├─ Evaluator.Evaluate(node, attrs) → bool
            └─ true のとき stdout.WriteLine(InspectAttrs(attrs))
       └─ phaseLine("done")
```

## ファイル構成

```
Program.cs               # 全実装（1 ファイル）
LdapFilter.csproj        # プロジェクト定義
tests/
  Program.cs             # TAP 形式の独自テスト
  LdapFilter.Tests.csproj
```

単一ファイルで完結している。テストプロジェクトは `[assembly: InternalsVisibleTo("LdapFilter.Tests")]` を通じて内部クラスにアクセスする。

## レイヤー構造

### 1. タイミング（ベンチ用）

`Stopwatch.GetTimestamp()` と `Stopwatch.Frequency` を組み合わせてナノ秒に変換する。

```csharp
var delta = Stopwatch.GetTimestamp() - startTimestamp;
return (long)(delta * 1_000_000_000.0 / Stopwatch.Frequency);
```

| フェーズ | 区間 |
|:---|:---|
| `boot`  | プロセス起動〜オプション解析・フォーマット判定完了 |
| `ready` | フォーマット判定完了（フィルタコンパイルの前） |
| `done`  | 入力の読み取りと出力の完了 |

`ready` の後にフィルタコンパイルが行われる点が Ruby と異なる。

### 2. AST（sealed record）

```csharp
abstract record FilterNode;
sealed record ItemNode(string Attr, string Op, string Value, Regex? Regex) : FilterNode;
sealed record AndNode(IReadOnlyList<FilterNode> Nodes) : FilterNode;
sealed record OrNode(IReadOnlyList<FilterNode> Nodes) : FilterNode;
sealed record NotNode(FilterNode Node) : FilterNode;
```

C# の `sealed record` を使うことで構造的等値が自動実装され、テストで役立つ。
パターンマッチは `switch` 式で行い、`_` アームが `ArgumentOutOfRangeException` を投げる（網羅性は実行時チェック）。

### 3. 順序付き属性（`OrderedAttrs`）

`Dictionary<string, string?>` で実装する。.NET の `Dictionary` の列挙順は挿入順という実装上の特性があるが、仕様では保証されていない。
`string?` により `null`（LTSV の空値）と空文字を区別する。

### 4. パーサ（`Parser.ParseFilter`）

再帰下降の手書きパーサ。ネスト構造の解析は `SplitTopLevel` が括弧の深さをカウントして行う。

```
ParseFilter(expr)
  └─ ParseNode(str)
       ├─ "&" → SplitTopLevel → AndNode（各子を再帰）
       ├─ "|" → SplitTopLevel → OrNode（各子を再帰）
       ├─ "!" → SplitTopLevel → NotNode（子は 1 つのみ）
       └─ それ以外 → ParseItem → ItemNode
```

`SplitTopLevel` は `(` で `depth` をインクリメント、`)` でデクリメントし、`depth` がゼロになるたびに 1 ノード分の部分文字列を収集して返す。Ruby の `subfilters`・TypeScript の `splitTopLevel` と同じアプローチ。

`UnescapeHex` は `Regex.Replace` でまとめて `\xx`（16 進 2 桁）エスケープを展開する。

ワイルドカードを含む値は `Regex` オブジェクトに変換して `ItemNode.Regex` に保持する：

```csharp
var pattern = Regex.Escape(value).Replace(@"\*", ".*");
return new Regex("^" + pattern + "$", RegexOptions.CultureInvariant);
```

### 5. 評価器（`Evaluator.Evaluate`）

```csharp
return node switch {
    AndNode and  => and.Nodes.All(child => Evaluate(child, attrs)),
    OrNode or    => or.Nodes.Any(child => Evaluate(child, attrs)),
    NotNode not  => !Evaluate(not.Node, attrs),
    ItemNode item => EvaluateItem(item, attrs),
    _ => throw new ArgumentOutOfRangeException(nameof(node))
};
```

`All` / `Any` は LINQ の短絡評価により、最初の `false` / `true` が出た時点で打ち切られる。

`>=` / `<=` は `string.CompareOrdinal` でカルチャ非依存の辞書順比較を行う。
`~=` は自前の Levenshtein（ローリング配列、`char` 単位、早期終了なし）で閾値 `< 3`。

### 6. 非同期ストリーミング

行の読み取りに `IAsyncEnumerable<OrderedAttrs>` を使い、`await foreach` で消費する：

```csharp
private static async IAsyncEnumerable<OrderedAttrs> ReadRowsAsync(string inputPath, FormatKind format)
{
    await using var input = InputHelper.Open(inputPath);
    // ...
    while ((line = await input.Reader.ReadLineAsync()) is not null) { yield return ...; }
}
```

`InputHandle : IAsyncDisposable` が `DisposeAsync` で xz プロセスの終了待ちと stderr 確認を行う。

### 7. 入力ソース

`.xz` なら `Process` を `StartInfo.ArgumentList` で起動する。`ArgumentList` を使うことでシェルエスケープが不要になる：

```csharp
process.StartInfo.FileName = "xz";
process.StartInfo.ArgumentList.Add("-dc");
process.StartInfo.ArgumentList.Add(inputPath);
```

通常ファイルは `StreamReader` で読み込む。

### 8. CSV パーサ

手書き RFC 4180 状態機械。標準ライブラリに適切な CSV パーサがないため自前実装。
BOM は `line.StartsWith('\uFEFF')` で検出し除去する。

### 9. フォーマット自動検出

拡張子で判定する。

1. `.csv` / `.csv.xz` → CSV
2. `.ltsv` / `.ltsv.xz` → LTSV
3. それ以外 → LTSV にフォールバック

## C# 固有の注意点

| 事項 | 対応 |
|:---|:---|
| `record` の等値比較 | `sealed record` は構造的等値が自動実装されるためテストで直接比較できる |
| `InternalsVisibleTo` | テストプロジェクトから `Parser`・`Evaluator`・`OrderedAttrs` にアクセスするため必須 |
| `Levenshtein` の `char` 単位 | サロゲートペアの扱いは未考慮 |
| `ready` の後にコンパイル | フォーマット検出完了後・フィルタコンパイル前が `ready`（Ruby とは異なる） |
| `RegexOptions.CultureInvariant` | ワイルドカード変換時に指定し、カルチャ依存の挙動を避ける |

## ビルドとテスト

```bash
# ビルド（self-contained single file）
dotnet publish -c Release -r linux-x64 --self-contained true -p:PublishSingleFile=true

# テスト
dotnet run --project tests/

# 実行
./ldap_filter FILTER INPUT
```
