{-# LANGUAGE ScopedTypeVariables, TupleSections #-}
module LdapFilter
  ( Filter(..)
  , FilterItem(..)
  , WildcardPattern(..)
  , Attrs
  , AttrValue
  , Format(..)
  , InputSource
  , parseFilter
  , filterMatch
  , wildcardMatches
  , levenshteinLte
  , parseLtsvLine
  , parseCsvLine
  , stripBom
  , rowToAttrs
  , formatAttrs
  , detectFormat
  , openInput
  , closeInput
  , parseArgv
  , processLtsv
  , processCsv
  , emitPhase
  , run
  ) where

import Control.Applicative ((<|>))
import Control.Exception   (try, displayException, SomeException)
import Control.Monad       (when, unless, forM_)
import Data.Char           (isAlpha, isAlphaNum, toLower)
import Data.List           (intercalate, isPrefixOf, isSuffixOf, tails, foldl')
import Data.Maybe          (isJust, listToMaybe)
import Data.Word           (Word64)
import GHC.Clock           (getMonotonicTimeNSec)
import System.IO
import System.Process      ( createProcess, proc, StdStream(..)
                           , CreateProcess(..), waitForProcess, ProcessHandle )

-- ---- Types -------------------------------------------------------------------

type AttrValue = Maybe String
type Attrs     = [(String, AttrValue)]

data WildcardPattern = WildcardPattern
  { wpParts    :: [String]
  , wpLeading  :: Bool
  , wpTrailing :: Bool
  } deriving (Show, Eq)

data FilterItem = FilterItem
  { fiAttr     :: String
  , fiOp       :: String
  , fiValue    :: String
  , fiWildcard :: Maybe WildcardPattern
  } deriving (Show)

data Filter
  = FAnd [Filter]
  | FOr  [Filter]
  | FNot Filter
  | FItem FilterItem
  deriving (Show)

data Format = FormatLtsv | FormatCsv deriving (Show, Eq)

data InputSource = InputSource Handle (Maybe ProcessHandle)

-- ---- Timing ------------------------------------------------------------------

emitPhase :: Word64 -> String -> IO ()
emitPhase t0 phase = do
  t1 <- getMonotonicTimeNSec
  let ns = t1 - t0
  hPutStrLn stderr $ "phase=" ++ phase ++ " t=" ++ show ns ++ " elapsed_ns=" ++ show ns
  hFlush stderr

-- ---- Hex decode --------------------------------------------------------------

hexVal :: Char -> Maybe Int
hexVal c
  | '0' <= c && c <= '9' = Just (fromEnum c - fromEnum '0')
  | 'a' <= c && c <= 'f' = Just (10 + fromEnum c - fromEnum 'a')
  | 'A' <= c && c <= 'F' = Just (10 + fromEnum c - fromEnum 'A')
  | otherwise             = Nothing

decodeHexChar :: Char -> Char -> Maybe Char
decodeHexChar h l = do
  hi <- hexVal h
  lo <- hexVal l
  return (toEnum (hi * 16 + lo))

-- ---- Value parsing -----------------------------------------------------------

-- Returns (decoded-string, Maybe WildcardPattern)
parseItemValue :: String -> Either String (String, Maybe WildcardPattern)
parseItemValue "*" = Right ("*", Nothing)
parseItemValue raw = go raw [] [] [] False
  where
    -- Accumulate decoded (reversed) and current segment (reversed) + prior segments
    go [] dec curSeg segs sawStar
      | not sawStar = Right (reverse dec, Nothing)
      | otherwise   =
          let allSegs  = map reverse (reverse (curSeg : segs))
              leading  = head raw == '*'
              trailing = last raw == '*'
          in Right (reverse dec, Just (WildcardPattern allSegs leading trailing))
    go ('\\':h:l:rest) dec curSeg segs sawStar =
      case decodeHexChar h l of
        Nothing -> Left "invalid escape sequence"
        Just c  -> go rest (c:dec) (c:curSeg) segs sawStar
    go ['\\'] _ _ _ _ = Left "incomplete escape sequence"
    go ('*':rest) dec curSeg segs _ =
      go rest ('*':dec) [] (curSeg:segs) True
    go (c:rest) dec curSeg segs sawStar =
      go rest (c:dec) (c:curSeg) segs sawStar

-- ---- Filter parsing ----------------------------------------------------------

parseFilter :: String -> Either String Filter
parseFilter expr = do
  (node, next) <- parseFilterAt expr 0
  if next /= length expr
    then Left "unexpected trailing input"
    else Right node

parseFilterAt :: String -> Int -> Either String (Filter, Int)
parseFilterAt expr pos
  | pos >= length expr || expr !! pos /= '(' = Left "expected '('"
  | otherwise =
      case findClose expr pos of
        Nothing -> Left "parenthesis mismatch"
        Just e  -> do
          node <- parseFilterContent (substring expr (pos + 1) e)
          Right (node, e + 1)

findClose :: String -> Int -> Maybe Int
findClose s start = go (start + 1) 1
  where
    n = length s
    go i _     | i >= n    = Nothing
    go i depth
      | s !! i == '(' = go (i + 1) (depth + 1)
      | s !! i == ')' = if depth == 1 then Just i else go (i + 1) (depth - 1)
      | otherwise     = go (i + 1) depth

parseFilterList :: String -> Int -> Either String ([Filter], Int)
parseFilterList expr pos = go pos []
  where
    n = length expr
    go p acc
      | p < n && expr !! p == '(' = do
          (node, next) <- parseFilterAt expr p
          go next (node : acc)
      | otherwise = Right (reverse acc, p)

parseFilterContent :: String -> Either String Filter
parseFilterContent "" = Left "empty filter"
parseFilterContent content = case head content of
  '&' -> do
    (nodes, _) <- parseFilterList content 1
    if null nodes then Left "expected at least one nested filter" else Right (FAnd nodes)
  '|' -> do
    (nodes, _) <- parseFilterList content 1
    if null nodes then Left "expected at least one nested filter" else Right (FOr nodes)
  '!' -> do
    (node, next) <- parseFilterAt content 1
    if next < length content then Left "not operator has more than one filter"
    else Right (FNot node)
  _   -> FItem <$> parseItem content

parseItem :: String -> Either String FilterItem
parseItem content =
  case findOp content of
    Nothing        -> Left "error in item syntax"
    Just (pos, op) ->
      let attr = take pos content
      in if null attr
         then Left "error in item syntax"
         else do
           let rawValue = drop (pos + length op) content
           (value, wc) <- parseItemValue rawValue
           Right (FilterItem attr op value wc)

findOp :: String -> Maybe (Int, String)
findOp = go 0
  where
    go _ []     = Nothing
    go i (c:cs)
      | c == '='            = Just (i, "=")
      | c `elem` ("~><" :: String) = case cs of
          ('=':_) -> Just (i, [c, '='])
          _       -> Nothing
      | otherwise           = go (i + 1) cs

substring :: String -> Int -> Int -> String
substring s start end = take (end - start) (drop start s)

-- ---- Wildcard matching -------------------------------------------------------

wildcardMatches :: WildcardPattern -> String -> Bool
wildcardMatches wp actual
  | null nonEmpty = True
  | otherwise     = go nonEmpty 0 (length nonEmpty - 1) 0
  where
    nonEmpty = filter (not . null) (wpParts wp)
    leading  = wpLeading wp
    trailing = wpTrailing wp
    al       = length actual

    go :: [String] -> Int -> Int -> Int -> Bool
    go [] _ _ _         = True
    go (p:ps) i li pos
      | i == 0 && not leading =
          let pl = length p
          in if pos + pl <= al && take pl (drop pos actual) == p
             then go ps (i + 1) li (pos + pl)
             else False
      | i == li && not trailing =
          let pl = length p
          in al >= pl && drop (al - pl) actual == p
      | otherwise =
          let pl = length p
          in case findFrom p pos of
               Nothing    -> False
               Just found -> go ps (i + 1) li (found + pl)

    findFrom :: String -> Int -> Maybe Int
    findFrom needle start =
      listToMaybe [ start + j
                  | (j, t) <- zip [0..] (tails (drop start actual))
                  , needle `isPrefixOf` t ]

-- ---- Levenshtein -------------------------------------------------------------

levenshteinLte :: String -> String -> Int -> Bool
levenshteinLte a b maxDist
  | abs (la - lb) > maxDist    = False
  | last finalRow <= maxDist   = True
  | otherwise                  = False
  where
    la       = length a
    lb       = length b
    initRow  = [0..lb]
    finalRow = foldl' nextRow initRow (zip [1 :: Int ..] a)

    nextRow :: [Int] -> (Int, Char) -> [Int]
    nextRow prev (i, ac) =
      let triples = zip3 prev (tail prev) b
          step cur (pj1, pj, bc) =
            let cost = if ac == bc then 0 else 1
            in minimum [pj + 1, cur + 1, pj1 + cost]
      in scanl step i triples

-- ---- Filter evaluation -------------------------------------------------------

filterMatch :: Filter -> Attrs -> Bool
filterMatch (FAnd nodes) attrs = all (`filterMatch` attrs) nodes
filterMatch (FOr  nodes) attrs = any (`filterMatch` attrs) nodes
filterMatch (FNot node)  attrs = not (filterMatch node attrs)
filterMatch (FItem item) attrs = itemMatch item attrs

itemMatch :: FilterItem -> Attrs -> Bool
itemMatch item attrs =
  let op   = fiOp item
      attr = fiAttr item
      val  = fiValue item
      wc   = fiWildcard item
  in case op of
       "=" | val == "*" -> isJust (lookup attr attrs)
           | otherwise  ->
               case lookup attr attrs of
                 Nothing         -> False
                 Just Nothing    -> False
                 Just (Just av)  -> case wc of
                   Just wp -> wildcardMatches wp av
                   Nothing -> av == val
       _ ->
         case lookup attr attrs of
           Nothing         -> False
           Just Nothing    -> False
           Just (Just av)  -> case op of
             ">=" -> av >= val
             "<=" -> av <= val
             "~=" -> levenshteinLte val av 2
             _    -> False

-- ---- Output formatting -------------------------------------------------------

isRubySymbol :: String -> Bool
isRubySymbol []     = False
isRubySymbol (c:cs) =
  (isAlpha c || c == '_') &&
  all (\x -> isAlphaNum x || x == '_') cs

escapeForRuby :: String -> String
escapeForRuby = concatMap escape
  where
    escape '"'  = "\\\""
    escape '\\' = "\\\\"
    escape '\n' = "\\n"
    escape '\r' = "\\r"
    escape '\t' = "\\t"
    escape x    = [x]

formatKey :: String -> String
formatKey k
  | isRubySymbol k = k ++ ": "
  | otherwise      = "\"" ++ escapeForRuby k ++ "\" => "

formatValue :: AttrValue -> String
formatValue Nothing  = "nil"
formatValue (Just v) = "\"" ++ escapeForRuby v ++ "\""

formatAttrs :: Attrs -> String
formatAttrs attrs =
  "{" ++ intercalate ", " (map fmt attrs) ++ "}\n"
  where fmt (k, v) = formatKey k ++ formatValue v

-- ---- LTSV parsing ------------------------------------------------------------

splitOnChar :: Char -> String -> [String]
splitOnChar sep s = go s []
  where
    go [] cur          = [reverse cur]
    go (c:cs) cur
      | c == sep  = reverse cur : go cs []
      | otherwise = go cs (c:cur)

unescapeLtsv :: String -> AttrValue
unescapeLtsv "" = Nothing
unescapeLtsv s  =
  let result = go s []
  in if null result then Nothing else Just (reverse result)
  where
    go []              acc = acc
    go ('\\':'r':rest) acc = go rest ('\r':acc)
    go ('\\':'n':rest) acc = go rest ('\n':acc)
    go ('\\':'t':rest) acc = go rest ('\t':acc)
    go ('\\':'\\':rest) acc = go rest ('\\':acc)
    go ('\\':c:rest)   acc = go rest (c:'\\':acc)
    go ['\\']          acc = '\\':acc
    go (c:rest)        acc = go rest (c:acc)

parseLtsvLine :: String -> Attrs
parseLtsvLine line =
  [ (key, unescapeLtsv val)
  | entry <- splitOnChar '\t' line
  , let (key, rest) = break (== ':') entry
  , not (null rest)
  , let val = drop 1 rest
  ]

-- ---- CSV parsing -------------------------------------------------------------

stripBom :: String -> String
stripBom ('\xFEFF':rest) = rest
stripBom s               = s

parseCsvLine :: String -> [String]
parseCsvLine s = reverse (go s [] [])
  where
    go []        cur fields = reverse cur : fields
    go (',':rest) cur fields = go rest [] (reverse cur : fields)
    go ('"':rest) cur fields = quoted rest cur fields
    go (c:rest)   cur fields = go rest (c:cur) fields

    quoted []              cur fields = reverse cur : fields
    quoted ('"':'"':rest)  cur fields = quoted rest ('"':cur) fields
    quoted ('"':rest)      cur fields = go rest cur fields
    quoted (c:rest)        cur fields = quoted rest (c:cur) fields

rowToAttrs :: [String] -> [String] -> Attrs
rowToAttrs headers row =
  [ (key, Just (if i < length row then row !! i else ""))
  | (key, i) <- zip headers [0..] ]

-- ---- Format detection --------------------------------------------------------

endsWithCI :: String -> String -> Bool
endsWithCI s suffix = map toLower suffix `isSuffixOf` map toLower s

detectFormat :: FilePath -> Format
detectFormat path
  | endsWithCI path ".csv"    = FormatCsv
  | endsWithCI path ".csv.xz" = FormatCsv
  | otherwise                  = FormatLtsv

-- ---- Input source ------------------------------------------------------------

openInput :: FilePath -> IO InputSource
openInput path
  | endsWithCI path ".xz" = do
      (_, Just hout, _, ph) <- createProcess (proc "xz" ["-dc", path])
        { std_out = CreatePipe, std_err = Inherit }
      hSetEncoding hout utf8
      return (InputSource hout (Just ph))
  | otherwise = do
      h <- openFile path ReadMode
      hSetEncoding h utf8
      return (InputSource h Nothing)

closeInput :: InputSource -> IO ()
closeInput (InputSource h Nothing)   = hClose h
closeInput (InputSource h (Just ph)) = hClose h >> waitForProcess ph >> return ()

-- ---- Argument parsing --------------------------------------------------------

parseArgv :: [String] -> Maybe (String, FilePath, String)
parseArgv argv =
  let (mf, mi, fmt, pos) = go argv Nothing Nothing "auto" []
      mf' = mf <|> listToMaybe pos
      mi' = mi <|> listToMaybe (drop 1 pos)
  in (,, fmt) <$> mf' <*> mi'
  where
    go []                  f i fmt pos = (f, i, fmt, reverse pos)
    go ("--format":v:rest) f i _   pos = go rest f i v pos
    go ("--filter":v:rest) _ i fmt pos = go rest (Just v) i fmt pos
    go ("--input":v:rest)  f _ fmt pos = go rest f (Just v) fmt pos
    go (v:rest)            f i fmt pos
      | "--" `isPrefixOf` v = go rest f i fmt pos  -- ignore --jit etc.
      | otherwise            = go rest f i fmt (v:pos)

-- ---- Line processing ---------------------------------------------------------

stripCR :: String -> String
stripCR s = if not (null s) && last s == '\r' then init s else s

processLtsv :: Handle -> Filter -> IO ()
processLtsv h filt = do
  contents <- hGetContents h
  forM_ (lines contents) $ \line -> do
    let s = stripCR line
    unless (null s) $ do
      let attrs = parseLtsvLine s
      when (filterMatch filt attrs) $ putStr (formatAttrs attrs)

processCsv :: Handle -> Filter -> IO ()
processCsv h filt = do
  contents <- hGetContents h
  case lines contents of
    [] -> return ()
    (headerLine:rest) -> do
      let headers = parseCsvLine (stripBom (stripCR headerLine))
      forM_ rest $ \line -> do
        let s = stripCR line
        unless (null s) $ do
          let attrs = rowToAttrs headers (parseCsvLine s)
          when (filterMatch filt attrs) $ putStr (formatAttrs attrs)

-- ---- Main entry point --------------------------------------------------------

run :: Word64 -> [String] -> IO ()
run t0 argv =
  case parseArgv argv of
    Nothing ->
      ioError (userError "filter and input path are required")
    Just (filterStr, inputPath, fmtStr) -> do
      emitPhase t0 "boot"
      case parseFilter filterStr of
        Left e     -> ioError (userError e)
        Right filt -> do
          src <- openInput inputPath
          let fmt = case fmtStr of
                      "csv"  -> FormatCsv
                      "ltsv" -> FormatLtsv
                      _      -> detectFormat inputPath
          emitPhase t0 "ready"
          hSetBuffering stdout (BlockBuffering (Just (64 * 1024)))
          let InputSource h _ = src
          case fmt of
            FormatCsv  -> processCsv  h filt
            FormatLtsv -> processLtsv h filt
          hFlush stdout
          closeInput src
          emitPhase t0 "done"
