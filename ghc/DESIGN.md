# GHC 実装 設計メモ

## 全体の流れ

```
argv
  └─ parseArgv
       ├─ parseFilter → Filter (ADT)
       └─ openInput → InputSource (plain file / xz pipe)
                          └─ processLtsv / processCsv
                               ├─ parseLtsvLine / parseCsvLine → Attrs (alist)
                               ├─ filterMatch (ADT を再帰走査)
                               └─ formatAttrs → stdout
```

## レイヤー構造

### 1. タイミング（ベンチ用）

`main` 冒頭で `getMonotonicTimeNSec :: IO Word64` を呼び、`t0` として `run` に渡す。  
`emitPhase t0 phase` が現在時刻との差分をナノ秒で `stderr` に出力する。

```haskell
emitPhase :: Word64 -> String -> IO ()
emitPhase t0 phase = do
  t1 <- getMonotonicTimeNSec
  let ns = t1 - t0
  hPutStrLn stderr $ "phase=" ++ phase ++ " t=" ++ show ns ++ " elapsed_ns=" ++ show ns
```

`GHC.Clock.getMonotonicTimeNSec` は `base >= 4.11` (GHC 8.2+) の標準モジュール。  
単調増加クロックのため、ベンチマーク計測に適している。

### 2. AST 型（代数的データ型）

```haskell
data Filter
  = FAnd [Filter]
  | FOr  [Filter]
  | FNot Filter
  | FItem FilterItem

data FilterItem = FilterItem
  { fiAttr     :: String
  , fiOp       :: String        -- "=" | ">=" | "<=" | "~="
  , fiValue    :: String
  , fiWildcard :: Maybe WildcardPattern
  }

data WildcardPattern = WildcardPattern
  { wpParts    :: [String]  -- * で分割したセグメント列
  , wpLeading  :: Bool      -- パターンが * で始まる
  , wpTrailing :: Bool      -- パターンが * で終わる
  }

type AttrValue = Maybe String   -- Nothing = nil (LTSV の空値など)
type Attrs     = [(String, AttrValue)]
```

Haskell の ADT は型タグ付きで、パターンマッチで網羅チェックが入る。  
SBCL の `defstruct` + `etypecase` に相当するが、コンパイラが網羅性を検査してくれる。

### 3. パーサー（手書き再帰下降）

```
parseFilter
  └─ parseFilterAt        (pos 指定で "(...)" を1個切り出す)
       └─ parseFilterContent (先頭文字で & | ! item に振り分け)
            ├─ parseFilterList (& | の子ノードリストを収集)
            └─ parseItem       (attr op value を抽出)
                 └─ parseItemValue (値を decode + WildcardPattern を構築)
```

- **`findClose`**：カッコ深さを数えて対応する `)` の位置を返す。O(n)。
- **`parseItemValue`**：文字列を逆順で `dec`（decoded）と `curSeg`（現セグメント）に積む。  
  `*` を見つけたら `curSeg` を `segs` に `push` してリセット。最後に `map reverse` で正順に戻す。

```haskell
-- 末尾再帰スタイルで acc を逆順に積む
go [] dec curSeg segs sawStar
  | not sawStar = Right (reverse dec, Nothing)
  | otherwise   =
      let allSegs = map reverse (reverse (curSeg : segs))
      in Right (reverse dec, Just (WildcardPattern allSegs leading trailing))
go ('*':rest) dec curSeg segs _ =
  go rest ('*':dec) [] (curSeg:segs) True   -- curSeg を確定してリセット
```

**注意点**：`segs` に積まれた各セグメントは逆順のまま。最後に `map reverse` を忘れると  
ワイルドカードが正しくマッチしない（実装中に発生したバグ）。

### 4. 評価器

```haskell
filterMatch :: Filter -> Attrs -> Bool
filterMatch (FAnd nodes) attrs = all (`filterMatch` attrs) nodes
filterMatch (FOr  nodes) attrs = any (`filterMatch` attrs) nodes
filterMatch (FNot node)  attrs = not (filterMatch node attrs)
filterMatch (FItem item) attrs = itemMatch item attrs
```

- `all` / `any` は Haskell の遅延評価で自動的に短絡評価される。
- `FAnd` の最初の `False`、`FOr` の最初の `True` で残りは評価されない。

`itemMatch` では `lookup attr attrs :: Maybe AttrValue` を使い、`Nothing`（キー不在）と  
`Just Nothing`（キーあり・nil 値）を区別して判定する。

### 5. ワイルドカードマッチング

セグメント列を左から消費し、位置 `pos` を追跡する：

| 条件 | 処理 |
|:---|:---|
| `i == 0 && not leading` | 先頭 anchor：`take pl (drop pos actual) == p` |
| `i == lastIdx && not trailing` | 末尾 anchor：`drop (al - pl) actual == p` |
| それ以外 | `findFrom`：`pos` 以降で最初に一致する位置を `tails` で探索 |

```haskell
-- 指定位置以降でサブ文字列を検索
findFrom :: String -> Int -> Maybe Int
findFrom needle start =
  listToMaybe [ start + j
              | (j, t) <- zip [0..] (tails (drop start actual))
              , needle `isPrefixOf` t ]
```

### 6. Levenshtein 距離（近似一致 `~=`）

ローリング配列相当を Haskell の `foldl'` + `scanl` で表現：

```haskell
-- prev[j] = distance(a[0..i-1], b[0..j-1])
-- curr[j] = distance(a[0..i],   b[0..j-1])
nextRow :: [Int] -> (Int, Char) -> [Int]
nextRow prev (i, ac) =
  let triples = zip3 prev (tail prev) b
      step cur (pj1, pj, bc) =
        minimum [pj + 1, cur + 1, pj1 + (if ac == bc then 0 else 1)]
  in scanl step i triples
```

`scanl step i triples` で `curr[0] = i`、左から右に計算した行を生成。  
閾値 `maxDist = 2`（Ruby 実装準拠）。長さ差が `maxDist` を超えれば早期返却。

### 7. 出力フォーマット

Ruby の `inspect` 相当を再現：

| キーの形式 | 出力例 |
|:---|:---|
| `[A-Za-z_][A-Za-z0-9_]*`（Ruby シンボル相当） | `host: "example.com"` |
| それ以外 | `"key-with-dash" => "val"` |
| `AttrValue = Nothing` | `nil` |

```haskell
formatAttrs :: Attrs -> String
formatAttrs attrs = "{" ++ intercalate ", " (map fmt attrs) ++ "}\n"
  where fmt (k, v) = formatKey k ++ formatValue v
```

### 8. LTSV / CSV パーサー

**LTSV**：タブで分割 → `key:value` をコロンで分割 → 値を `unescapeLtsv` でデコード。  
空値 (`""`) は `unescapeLtsv` が `Nothing` を返す。

**CSV**：RFC 4180 準拠の手書き状態機械。`"` で始まればクォートフィールド、  
`""` は `"` にデコード、`"` の次に `,` でフィールド終端。

### 9. 入力ソース

`.xz` 拡張子なら `System.Process.createProcess` で `xz -dc` をサブプロセス起動し、  
stdout を文字ストリームとして遅延読み取り：

```haskell
(_, Just hout, _, ph) <- createProcess (proc "xz" ["-dc", path])
  { std_out = CreatePipe, std_err = Inherit }
hSetEncoding hout utf8
```

`hGetContents h` の遅延 IO により、行ごとに `parseLtsv` / `parseCsv` を適用しつつ  
ストリーミング処理できる。

### 10. 引数パーサー

```
--format fmt  --filter expr  --input path
または
positional[0]=filter  positional[1]=path
```

`--jit` / `--no-jit` / `--yjit` / `--no-yjit` などは `"--"` で始まるフラグとして  
まとめて無視する。

## モジュール構成

```
ghc/
  src/LdapFilter.hs   ライブラリ（全ロジック）
  app/Main.hs         実行バイナリのエントリポイント（約 20 行）
  test/Spec.hs        ユニットテスト（52 件、独自フレームワーク）
  test-unit.sh        ユニットテスト実行スクリプト
  test-smoke.sh       バイナリスモークテスト（6 件）
  build.sh            ビルドスクリプト
  ldap-filter.cabal   プロジェクト定義
  bin/                gitignore 対象（ビルド成果物）
```

`library` + `executable` + `test-suite` の 3 stanza 構成。  
ロジックを `LdapFilter` ライブラリに集約することで、テストから直接インポートできる。

## ビルド

```bash
bash build.sh
# → bin/ldap_filter に実行バイナリを生成
```

内部では `ghc -O2 -isrc -outputdir /tmp/ghc-ldf-build -o bin/ldap_filter app/Main.hs`。  
cabal はバージョン不一致（mise GHC 8.10.7 vs system ghc-pkg 9.4.7）のため直接使用しない。  
mise GHC にバンドルされた `x86_64-conda-linux-gnu-gcc` を `PATH` に追加してビルドする。

## テスト

```bash
# ユニットテスト（52 件）
bash test-unit.sh

# スモークテスト（バイナリ必須）
bash test-smoke.sh
```

## SBCL 実装との対比

| 観点 | SBCL | GHC |
|:---|:---|:---|
| AST 表現 | `defstruct` + `etypecase` | ADT + パターンマッチ |
| 評価器 | 再帰関数 | 再帰関数（`all`/`any` で短絡） |
| 文字列型 | 可変長文字列 (adjustable array) | `String` (= `[Char]`、不変リスト) |
| 副作用 | 全体が命令型 | IO モナドで明示的に管理 |
| 前方宣言 | `declaim ftype` が必要 | 相互再帰は同一モジュール内で解決 |
| グローバル時刻 | `*start-time*` IORef (unsafePerformIO) | `t0` を引数として渡す（純粋） |
| パッケージ管理 | 単一ファイル、依存なし | cabal (library stanza) |
