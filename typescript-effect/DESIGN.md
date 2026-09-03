# TypeScript + Effect 実装設計

LDAP Search Filter（RFC 4515）の解析と、CSV / LTSV ログのフィルタリングを行う CLI です。処理の成功値、失敗、非同期処理、リソース解放、副作用を Effect の型で構成します。

## 処理の流れ

```text
argv
  └─ program(): Effect<number, Error, CliConsole>
       ├─ parseArgs
       ├─ detectFormat
       ├─ parseFilter(): Effect<FilterNode, FilterError>
       └─ processInput
            ├─ forEachInputLine(): Effect<void, Error>
            ├─ parseCsvLine / parseLtsvLine
            ├─ evaluateFilter(): Effect<boolean, FilterError>
            ├─ inspectAttrs(): Effect<string, never>
            └─ CliConsole.stdout
```

`index.ts` は `CliConsole` の実装を Layer で提供し、`Effect.runPromise` でプログラムを起動します。アプリケーションの処理は `program` から外へ出ず、終了コードまたは失敗として完了します。

## Effect の型と責務

### フィルタ解析

`parseFilter` は `Effect<FilterNode, FilterError>` を返します。再帰下降パーサの例外は `Effect.try` で `FilterError` に変換されます。

AST は次の判別共用体で表現します。

```typescript
type FilterNode =
  | { kind: "item"; attr: string; op: "=" | "~=" | ">=" | "<="; value: string; regex?: RegExp }
  | { kind: "and"; nodes: FilterNode[] }
  | { kind: "or"; nodes: FilterNode[] }
  | { kind: "not"; node: FilterNode }
```

### フィルタ評価

`evaluateFilter` は `Effect<boolean, FilterError>` を返します。`and` と `or` の子ノードは `Effect.forEach` で評価し、いずれかの評価が失敗した場合は全体を失敗させます。

比較演算子の評価は次の通りです。

- `=`: 完全一致または `*` によるワイルドカード一致
- `=*`: 属性の存在確認
- `~=`: Levenshtein 距離が 3 未満
- `>=` / `<=`: 文字列の辞書順比較

### 入力処理

`forEachInputRecord` は `Effect<void, Error>` を返します。通常ファイルは Node.js の読み取りストリーム、`.xz` ファイルは `xz -dc` の標準出力を入力に使用します。LTSV は物理行、CSV は引用符の状態を追跡した論理レコード単位で処理します。

入力ストリーム、readline、`xz` 子プロセスのエラーを Effect の失敗へ変換し、キャンセル時にはすべてのリソースを解放します。Node.js の async iterator と逐次 `await` により、各レコードの処理完了まで次のレコードを読み込まない構成です。

### 標準入出力

標準出力と標準エラーは `CliConsole` サービスとして定義します。

```typescript
interface CliConsole {
  readonly stdout: (text: string) => Effect.Effect<void, Error>
  readonly stderr: (text: string) => Effect.Effect<void, Error>
}
```

実行時は Node.js の標準ストリームを使い、テスト時は `Layer.succeed` でメモリ上の実装に差し替えます。これにより CLI のロジックがグローバルな標準出力へ直接依存しません。

## フェーズ計測

単調増加するナノ秒時計で次のフェーズを標準エラーへ出力します。

```text
phase=boot t=123 elapsed_ns=123
phase=ready t=456 elapsed_ns=456
phase=done t=789 elapsed_ns=789
```

- `boot`: 引数解析と初期化
- `ready`: フィルタ解析と入力処理を開始できる状態
- `done`: 入力処理と出力が完了した状態

## ファイル構成

```text
src/
  filter.ts  # AST、パーサ、評価、属性の出力整形
  io.ts      # 入力ストリーム、CSV / LTSV パーサ
  cli.ts     # CLI プログラム、CliConsole サービス
  index.ts   # 実行時 Layer の提供と Effect の起動
test/
  filter.test.js  # 解析・評価・出力整形
  cli.test.js     # Layer を差し替えた CLI 実行
```

## 依存関係と確認方法

実行時依存は `effect`、開発時依存は `typescript` と `@types/node` です。

```bash
npm install
npm test
```
