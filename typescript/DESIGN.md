# TypeScript 実装 設計メモ

## 全体の流れ

```
argv
  └─ main(argv)                    # index.ts → cli.ts
       ├─ parseArgs                # オプション解析
       ├─ phaseLine("boot")
       ├─ detectFormat             # フォーマット判定
       ├─ phaseLine("ready")
       └─ processCsv / processLtsv
            ├─ parseFilter(expr)   # フィルタ文字列 → FilterNode (AST)
            └─ forEachInputLine    # 行ごとに読み取り
                 ├─ parseLtsvLine / parseCsvLine → AttrMap
                 ├─ evaluateFilter(ast, attrs) → boolean
                 └─ true のとき process.stdout.write(inspectAttrs(attrs))
```

## ファイル構成

```
src/
  index.ts      # エントリポイント（EPIPE ハンドリング、main 呼び出し）
  cli.ts        # main()、フェーズ計測、入力処理の振り分け
  filter.ts     # AST 型定義、parseFilter、evaluateFilter、inspectAttrs
  io.ts         # 入力ストリーム、LTSV / CSV パーサ、フォーマット検出
  globals.d.ts  # 型補完用
dist/           # tsc ビルド成果物（CommonJS）
test/
  filter.test.js
  io.test.js
  cli.test.js
```

## レイヤー構造

### 1. タイミング（ベンチ用）

`process.hrtime.bigint()` で単調増加クロックをナノ秒精度の `bigint` で取得する。

```typescript
function monotonicNs(): bigint {
  return process.hrtime.bigint();
}

function phaseLine(phase: string, start: bigint): string {
  const elapsed = monotonicNs() - start;
  return `phase=${phase} t=${elapsed} elapsed_ns=${elapsed}`;
}
```

| フェーズ | 区間 |
|:---|:---|
| `boot`  | プロセス起動〜オプション解析・フォーマット判定完了 |
| `ready` | 入力処理の開始点（フィルタのコンパイルは `ready` の**後**） |
| `done`  | 入力の読み取りと出力の完了 |

**注意**：フィルタのコンパイル（`parseFilter`）は `ready` の後、`processCsv` / `processLtsv`
の中で行われる。Ruby では `ready` の前にコンパイルするため、フェーズの区切りが異なる。

### 2. AST 型（判別共用体）

```typescript
export type FilterNode =
  | { kind: "item"; attr: string; op: string; value: string; regex?: RegExp }
  | { kind: "and"; nodes: FilterNode[] }
  | { kind: "or"; nodes: FilterNode[] }
  | { kind: "not"; node: FilterNode };
```

TypeScript の判別共用体（discriminated union）を使う。`kind` プロパティで分岐し、
`switch (node.kind)` が網羅性を型レベルで保証する。

### 3. パーサ（`parseFilter`）

再帰下降の手書きパーサ。括弧ネストの解析は `splitTopLevel` が担う。

```
parseFilter(expr)
  ├─ "("  → splitTopLevel → parseFilter（外側の括弧を剥がして再帰）
  ├─ "&"  → splitTopLevel(expr.slice(1)).map(parseFilter) → { kind: "and" }
  ├─ "|"  → splitTopLevel(expr.slice(1)).map(parseFilter) → { kind: "or" }
  ├─ "!"  → splitTopLevel → parseFilter → { kind: "not" }
  └─ else → parseItem → { kind: "item" }
```

`splitTopLevel` はカッコの深さをカウントし、深さゼロに戻るたびに内側の文字列を `parts` に積む。
括弧がなければ `[expr]` を返す（Ruby の `subfilters` に相当）。

`parseItem` は `ITEM_PARSER = /^([^~=><]+)(~=|>=|<=|=)(.+)$/` で分解し、
`unescapeHex` で `\xx` エスケープを展開する。

ワイルドカードを含む値は `*` で `split` した各部分を `escapeRegex` したうえで
`.*` で結合した正規表現を構築し、`node.regex` に持たせる：

```typescript
const regexText = value.split("*").map(escapeRegex).join(".*");
node.regex = new RegExp(regexText);
```

`escapeRegex` は `text.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")` で全特殊文字をエスケープする。

### 4. 評価器（`evaluateFilter`）

```typescript
export function evaluateFilter(node: FilterNode, attrs: AttrMap): boolean {
  switch (node.kind) {
    case "and": return node.nodes.every((child) => evaluateFilter(child, attrs));
    case "or":  return node.nodes.some((child) => evaluateFilter(child, attrs));
    case "not": return !evaluateFilter(node.node, attrs);
    case "item": ...
  }
}
```

`every` / `some` は JavaScript の短絡評価により、最初の `false` / `true` で打ち切られる。

presence filter（`value === "*"`）の判定は `Object.prototype.hasOwnProperty.call(attrs, attr)` を使う。
プロトタイプチェーン上のプロパティを誤って拾わないようにするため、直接 `attr in attrs` は使わない。

### 5. 近似一致（`~=`）

ローリング配列による標準的な Levenshtein 距離の自前実装。閾値は 3 未満。
早期終了は実装していない。

```typescript
function levenshtein(a: string, b: string): number {
  const prev = new Array(b.length + 1).fill(0).map((_, i) => i);
  const curr = new Array(b.length + 1).fill(0);
  for (let i = 1; i <= a.length; i += 1) {
    curr[0] = i;
    for (let j = 1; j <= b.length; j += 1) {
      const cost = a[i - 1] === b[j - 1] ? 0 : 1;
      curr[j] = Math.min(prev[j] + 1, curr[j - 1] + 1, prev[j - 1] + cost);
    }
    for (let j = 0; j <= b.length; j += 1) prev[j] = curr[j];
  }
  return prev[b.length];
}
```

### 6. 出力フォーマット（`inspectAttrs`）

`attrs` は `Record<string, AttrValue>` なので `Object.entries` で順序付き列挙できる
（モダン JS エンジンでは挿入順が保証される）。

```typescript
export function inspectAttrs(attrs: AttrMap): string {
  const parts = Object.entries(attrs).map(([k, v]) => `${formatKey(k)}${formatValue(v)}`);
  return `{${parts.join(", ")}}`;
}
```

`formatValue` は `JSON.stringify` の結果から前後の `"` を取り除いて Ruby 形式の文字列エスケープを再現する。
`null` / `undefined` は `"nil"` として出力する。

### 7. LTSV / CSV パーサ

**LTSV**（`parseLtsvLine`）：タブで分割 → `indexOf(":")` でキーと値を分割 → `unescapeLtsvValue` でデコード。
空値は `null` を返す。

**CSV**（`parseCsvLine`）：RFC 4180 準拠の手書き状態機械。`"` で始まればクォートフィールド、
`""` は `"` にデコード。stdlib がないため自前実装。BOM 除去は `parseCsvHeader` が担う。

### 8. 入力ソース（`forEachInputLine`）

Node.js の `readline.createInterface` を `for await...of` で消費する非同期ストリーミング。
`.xz` なら `child_process.spawn("xz", ["-dc", path])` でサブプロセスを起動し、
その stdout を `readline` に渡す。

```typescript
const rl = readline.createInterface({ input: stream, crlfDelay: Infinity });
for await (const line of rl) {
  await onLine(line);
}
```

`waitForClose` は xz プロセスの終了待ちに使うプロミス。xz の終了コードが非ゼロなら
stderr の内容とともにエラーを `reject` する。

### 9. フォーマット自動検出

拡張子で判定する。不明な場合は LTSV にフォールバック（Ruby は CSV にフォールバック）。

1. `.csv` / `.csv.xz` → CSV
2. `.ltsv` / `.ltsv.xz` → LTSV
3. それ以外 → LTSV

### 10. EPIPE ハンドリング

`index.ts` で `process.stdout` の `error` イベントを監視し、
`head` 等でパイプが切れた場合（`EPIPE`）は exit code 0 で正常終了する。

```typescript
process.stdout.on("error", (error: any) => {
  if (error?.code === "EPIPE") process.exit(0);
  throw error;
});
```

## TypeScript 固有の注意点

| 事項 | 対応 |
|:---|:---|
| `AttrValue` の型 | `string \| null \| undefined`。`null` は「値あり・空」、`undefined` はキー不在と区別できる |
| `hasOwnProperty` | `Object.prototype.hasOwnProperty.call` でプロトタイプ汚染を防ぐ |
| フィルタコンパイル位置 | `ready` の後（Ruby とフェーズの区切りが異なる） |
| フォールバックフォーマット | 不明な拡張子は LTSV（Ruby は CSV） |
| `bigint` の文字列化 | `elapsed.toString()` が必要（テンプレートリテラルは自動変換するが明示推奨） |

## ビルドとテスト

```bash
# ビルド（src/ → dist/）
npm run build

# テスト（ビルド + node --test）
npm test

# 実行
node dist/index.js FILTER INPUT
```

テストは Node.js 組み込みの `node:test` モジュールを使用（外部フレームワークなし）。
テストファイルはビルド済みの `dist/*.js` に対して実行される。
