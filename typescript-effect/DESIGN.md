# TypeScript + Effect 実装設計

LDAP Search Filter（RFC 4515）の解析と、CSV / LTSV ログのフィルタリングを行う CLI です。失敗する処理、非同期処理、リソース解放、副作用を Effect の型で表現します。

## 処理の流れ

```text
argv
  └─ program(): Effect<number, ArgumentError | FilterError | InputError | OutputError, CliConsole>
       ├─ parseArgs
       ├─ detectFormat
       ├─ parseFilter(): Effect<FilterNode, FilterError>
       └─ processInput
            ├─ forEachInputRecord(): Effect<void, InputError>
            ├─ parseCsvLine / parseLtsvLine
            ├─ evaluateFilter(): boolean
            ├─ inspectAttrs(): string
            └─ CliConsole.stdout
```

`index.ts` は `CliConsole` の実装を Layer で提供し、`Effect.runPromise` でプログラムを起動します。アプリケーションの処理は `program` に集約され、終了コードまたは分類された失敗として完了します。

## Effect の型と責務

### フィルタ解析

`parseFilter` は `Effect<FilterNode, FilterError>` を返します。再帰下降パーサの例外は `Effect.try` で `FilterError` に変換されます。

AST は次の判別共用体で表現します。

```typescript
type FilterNode =
  | { kind: "item"; attr: string; op: "=" | "~=" | ">=" | "<="; value: string; presence: boolean; regex?: RegExp }
  | { kind: "and"; nodes: FilterNode[] }
  | { kind: "or"; nodes: FilterNode[] }
  | { kind: "not"; node: FilterNode }
```

### フィルタ評価

`evaluateFilter` は純粋な `boolean` を返します。`and` と `or` は通常の短絡評価を使い、AST と属性が正しければ評価中に失敗しません。

`inspectAttrs` も純粋な `string` を返します。Effect の実行コストをレコードごとの計算へ持ち込まず、出力書き込みだけを `CliConsole` の Effect として扱います。

比較演算子の評価は次の通りです。

- `=`: 完全一致または `*` によるワイルドカード一致
- `=*`: 属性の存在確認
- `~=`: Levenshtein 距離が 3 未満
- `>=` / `<=`: 文字列の辞書順比較

### 入力処理

`forEachInputRecord` は `Effect<void, InputError>` を返します。通常ファイルは Node.js の読み取りストリーム、`.xz` ファイルは `xz -dc` の標準出力を入力に使用します。LTSV は物理行、CSV は引用符の状態を追跡した論理レコード単位で処理します。

入力ストリーム、readline、`xz` 子プロセスのエラーを `InputError` へ変換し、`AbortSignal` と scoped release によりキャンセル時にはすべてのリソースを解放します。`Stream.runForEach` により、レコード処理 Effect の完了に合わせて入力を逐次消費します。CSV の構文エラーなど、入力に関する失敗も `InputError` として扱います。

### 標準入出力

標準出力と標準エラーは `CliConsole` サービスとして定義します。

```typescript
interface CliConsole {
  readonly stdout: (text: string) => Effect.Effect<void, OutputError>
  readonly stderr: (text: string) => Effect.Effect<void, OutputError>
}
```

実行時は Node.js の標準ストリームを使い、テスト時は `Layer.succeed` でメモリ上の実装に差し替えます。これにより CLI のロジックがグローバルな標準出力へ直接依存しません。

書き込み callback で chunk の処理結果を確認します。戻り値が `false` の場合は callback に加えて `drain` イベントも待ち、出力側の backpressure を維持します。書き込み中のエラーは `OutputError` に変換されます。

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
  errors.ts  # ArgumentError、FilterError、InputError、OutputError
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

CLI の失敗は `ArgumentError`、`FilterError`、`InputError`、`OutputError` の union で表現します。

```bash
npm install
npm test
```
