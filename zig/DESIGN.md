# Zig 実装 設計メモ

## 全体の流れ

```
args (argv スライス)
  └─ run(allocator, args, stdout, stderr)
       ├─ parseArgs              # オプション解析
       ├─ monotonicNs() → boot
       ├─ detectFormat           # フォーマット判定
       ├─ monotonicNs() → ready  # フィルタコンパイルの前
       ├─ parseFilter(arena, filter)   # フィルタ文字列 → *FilterNode
       └─ processInput(allocator, ...)
            ├─ .xz → std.process.run（全出力をメモリに取得）
            ├─ plain → readFileAlloc（全データをメモリに読み込み）
            ├─ std.mem.splitScalar で行分割
            └─ 行ごとに attrs → evaluate → inspectAttrs → 出力
  └─ monotonicNs() → done
```

## ファイル構成

```
src/
  main.zig    # 全実装（1 ファイル）
build.zig     # Zig ビルドシステム定義
```

## レイヤー構造

### 1. タイミング（ベンチ用）

`std.os.linux.clock_gettime(.MONOTONIC, ...)` で単調増加クロックをナノ秒整数で取得する：

```zig
fn monotonicNs() u64 {
    var ts: std.os.linux.timespec = .{ .sec = 0, .nsec = 0 };
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}
```

| フェーズ | 区間 |
|:---|:---|
| `boot`  | プロセス起動〜オプション解析・フォーマット判定完了 |
| `ready` | フォーマット判定完了（フィルタコンパイルの**前**） |
| `done`  | 入力の処理と出力の完了 |

**注意**：`ready` はフィルタのコンパイル前に出力される。Ruby・Go・Rust と異なる。

### 2. AST 型（タグ付き共用体）

Zig の `union(enum)` でタグ付き共用体を表現する：

```zig
const FilterNode = union(enum) {
    item:     ItemNode,
    and_node: []*FilterNode,
    or_node:  []*FilterNode,
    not_node: *FilterNode,
};
```

`FilterNode` はポインタで管理される（`*FilterNode`）。
子ノードは `[]*FilterNode`（ポインタのスライス）で保持する。

`ItemNode` は `wildcard: ?[]const u8` を持つ。`null` なら完全一致、非 `null` なら `*` を含む値文字列をそのまま保持する（セグメント分割はしない）：

```zig
const ItemNode = struct {
    attr:     []const u8,
    op:       []const u8,
    value:    []const u8,
    wildcard: ?[]const u8,
};
```

### 3. メモリ管理（アリーナアロケータ）

フィルタ AST は `ArenaAllocator` で管理し、処理が終わったら `arena.deinit()` で一括解放する：

```zig
var arena = std.heap.ArenaAllocator.init(allocator);
defer arena.deinit();
const ast = try parseFilter(arena.allocator(), filter);
```

行ごとの `attrs` も `row_arena` で管理し、各行の処理後に解放する：

```zig
var row_arena = std.heap.ArenaAllocator.init(allocator);
defer row_arena.deinit();
var attrs = try parseLtsvLine(row_arena.allocator(), line);
```

### 4. パーサ（`parseFilter`）

括弧の剥がし方が他の実装と異なる。外側の `(` と `)` を確認してから内側を再帰する：

```zig
fn parseFilter(allocator: Allocator, expr: []const u8) !*FilterNode {
    if (expr[0] == '(') {
        if (expr[expr.len - 1] != ')') return error.ParenthesisMismatch;
        return parseFilter(allocator, expr[1 .. expr.len - 1]);
    }
    switch (expr[0]) {
        '&' => return parseNary(allocator, expr[1..], .and_node),
        '|' => return parseNary(allocator, expr[1..], .or_node),
        '!' => return parseNot(allocator, expr[1..]),
        else => return parseItem(allocator, expr),
    }
}
```

`parseNary` / `parseNot` は `splitTopLevel` で子ノードの文字列リストを取得してから
それぞれ `parseFilter` を再帰呼び出しする。

`splitTopLevel` は括弧の深さをカウントして内側文字列を切り出す（他言語の同名関数と同じ方式）。

### 5. ワイルドカードマッチング

セグメントリストは使わず、`*` を含む値文字列をそのままパターンとして `wildcardMatch` に渡す。
DP / バックトラック方式（`star` ポインタと `match_index` の組み合わせ）：

```zig
fn wildcardMatch(pattern: []const u8, text: []const u8) bool {
    var p: usize = 0; var t: usize = 0;
    var star: ?usize = null; var match_index: usize = 0;

    while (t < text.len) {
        if (p < pattern.len and pattern[p] == text[t])       { p += 1; t += 1; continue; }
        if (p < pattern.len and pattern[p] == '*')           { star = p; p += 1; match_index = t; continue; }
        if (star) |star_pos| { p = star_pos + 1; match_index += 1; t = match_index; continue; }
        return false;
    }
    while (p < pattern.len and pattern[p] == '*') p += 1;
    return p == pattern.len;
}
```

他言語（Go・PHP・Python・Rust など）のセグメントリスト方式とは異なり、パターン文字列を直接消費する。

### 6. 近似一致（`~=`）

ローリング配列による Levenshtein 距離。`std.heap.page_allocator` を直接使用する（アリーナではない）。
バイト単位の比較のため、マルチバイト文字は未対応。閾値は `< 3`（`<= 2` と等価）。

```zig
fn levenshtein(a: []const u8, b: []const u8) !usize {
    const prev = try std.heap.page_allocator.alloc(usize, b.len + 1);
    defer std.heap.page_allocator.free(prev);
    // ... ローリング配列で各行を計算
    std.mem.copyForwards(usize, prev, curr);
}
```

早期終了は実装していない。

### 7. 入力処理（非ストリーミング）

**最大の特徴**：全ファイルをメモリに読み込んでから処理する。

```zig
// .xz ファイル
const result = try std.process.run(allocator, io, .{ .argv = &.{ "xz", "-dc", input } });
defer allocator.free(result.stdout);
try processData(allocator, result.stdout, format, ast, stdout);

// 通常ファイル
const data = try std.Io.Dir.cwd().readFileAlloc(io, input, allocator, .unlimited);
defer allocator.free(data);
try processData(allocator, data, format, ast, stdout);
```

`std.mem.splitScalar(u8, data, '\n')` でバッファを行に分割し、
各行の部分スライス（コピーなし）を処理する。

### 8. CSV / LTSV パーサ

**CSV**（`parseCsvFields`）：手書き RFC 4180 状態機械。`Managed(u8)` のリストでフィールドを積む。
セルが空でない場合のみクォートを開始するため、先頭以外の `"` はリテラルとして扱う。
BOM は `stripBom` が先頭 3 バイト `\xEF\xBB\xBF` を確認して除去する。

**LTSV**（`parseLtsvLine`）：`std.mem.splitScalar(u8, line, '\t')` でタブ分割し、
`std.mem.indexOfScalar(u8, entry, ':')` でキーと値を分割する。
`allocator.dupe(u8, key)` でキーをコピーし、値は `unescapeLtsvValue` でアロケートして返す。

### 9. フォーマット自動検出

拡張子で判定。不明な場合は LTSV にフォールバック（Ruby は CSV）。

1. `.csv` / `.csv.xz` → CSV
2. `.ltsv` / `.ltsv.xz` → LTSV
3. それ以外 → LTSV

### 10. 出力フォーマット（`inspectAttrs`）

`appendRubySymbolKey` が `isRubySymbolKey` で判定してキー形式を切り替える。
`appendEscapedRubyString` は `\\` と `\"` のみエスケープする：

```zig
fn appendEscapedRubyString(out: *Managed(u8), text: []const u8) !void {
    for (text) |ch| {
        switch (ch) {
            '\\' => try out.appendSlice("\\\\"),
            '"'  => try out.appendSlice("\\\""),
            else => try out.append(ch),
        }
    }
}
```

### 11. I/O 抽象

`StdStream` 構造体が stdout / stderr をラップする。`print` は `std.fmt.allocPrint` で文字列を生成してから書き出す。

```zig
fn print(self: *StdStream, comptime fmt: []const u8, args: anytype) !void {
    const rendered = try std.fmt.allocPrint(self.allocator, fmt, args);
    defer self.allocator.free(rendered);
    try self.writeAll(rendered);
}
```

## Zig 固有の注意点

| 事項 | 対応 |
|:---|:---|
| 非ストリーミング | `readFileAlloc` / `std.process.run` でメモリに全読み込み |
| `ready` の位置 | フィルタコンパイル前（他の多くの実装と異なる） |
| ワイルドカード方式 | セグメントリストではなく DP/バックトラック |
| `levenshtein` のアロケータ | `page_allocator` を直接使用（アリーナ外） |
| バイト単位比較 | Levenshtein はバイト比較のためマルチバイト文字に未対応 |
| `errdefer` | アロケーション失敗時のリソース解放に `errdefer attrs.deinit()` を活用 |
| `OrderedAttrs.add` の重複処理 | 同キーがすでに存在する場合は値を上書きする（他の実装は上書きしない） |

## ビルドとテスト

```bash
# ビルド
zig build

# テスト
zig build test

# 実行
./zig-out/bin/ldap_filter FILTER INPUT
```
