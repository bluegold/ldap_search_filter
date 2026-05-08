module Main where

import Data.IORef  (IORef, newIORef, readIORef, modifyIORef')
import System.Exit (exitFailure, exitSuccess)
import System.IO   (hPutStrLn, stderr)

import LdapFilter

-- ---- Minimal test framework --------------------------------------------------

data TestState = TestState { tsPassed :: !Int, tsFailed :: !Int }
type TestRef   = IORef TestState

newTestRef :: IO TestRef
newTestRef = newIORef (TestState 0 0)

check :: (Show a, Eq a) => TestRef -> String -> a -> a -> IO ()
check ref name expected actual
  | expected == actual = modifyIORef' ref (\s -> s { tsPassed = tsPassed s + 1 })
  | otherwise = do
      hPutStrLn stderr $ "FAIL: " ++ name
      hPutStrLn stderr $ "  expected: " ++ show expected
      hPutStrLn stderr $ "  actual:   " ++ show actual
      modifyIORef' ref (\s -> s { tsFailed = tsFailed s + 1 })

checkTrue, checkFalse :: TestRef -> String -> Bool -> IO ()
checkTrue  ref name v = check ref name True  v
checkFalse ref name v = check ref name False v

checkRight :: Show a => TestRef -> String -> Either a b -> IO (Maybe b)
checkRight ref name (Right v) = do
  modifyIORef' ref (\s -> s { tsPassed = tsPassed s + 1 })
  return (Just v)
checkRight ref name (Left e) = do
  hPutStrLn stderr $ "FAIL (unexpected Left): " ++ name ++ ": " ++ show e
  modifyIORef' ref (\s -> s { tsFailed = tsFailed s + 1 })
  return Nothing

isRight :: Either a b -> Bool
isRight (Right _) = True
isRight _         = False

-- ---- Tests -------------------------------------------------------------------

main :: IO ()
main = do
  ref <- newTestRef

  -- ---- Parser ----------------------------------------------------------------
  checkTrue  ref "parse simple"     (isRight (parseFilter "(uid=foo)"))
  checkFalse ref "parse no parens"  (isRight (parseFilter "uid=foo"))
  checkTrue  ref "parse AND"        (isRight (parseFilter "(&(a=1)(b=2))"))
  checkTrue  ref "parse OR"         (isRight (parseFilter "(|(a=1)(b=2))"))
  checkTrue  ref "parse NOT"        (isRight (parseFilter "(!(a=1))"))
  checkTrue  ref "parse presence"   (isRight (parseFilter "(uid=*)"))
  checkTrue  ref "parse wildcard"   (isRight (parseFilter "(uid=foo*)"))
  checkTrue  ref "parse GE"         (isRight (parseFilter "(age>=18)"))
  checkTrue  ref "parse LE"         (isRight (parseFilter "(age<=65)"))
  checkTrue  ref "parse approx"     (isRight (parseFilter "(name~=john)"))
  checkFalse ref "parse empty"      (isRight (parseFilter ""))
  checkFalse ref "parse trailing"   (isRight (parseFilter "(a=b)x"))

  -- ---- Filter evaluation -----------------------------------------------------
  let attrs = [("host", Just "www.example.com"), ("status", Just "200")]

  checkTrue  ref "match eq"         (filterMatch f1 attrs)
  checkFalse ref "match eq fail"    (filterMatch f1 [("host", Just "other.com")])
  checkTrue  ref "match AND"        (filterMatch f2 attrs)
  checkFalse ref "match AND fail"   (filterMatch f2 [("host", Just "www.example.com"), ("status", Just "500")])
  checkTrue  ref "match OR"         (filterMatch f3 [("host", Just "other"), ("status", Just "200")])
  checkTrue  ref "match NOT"        (filterMatch f4 [("status", Just "500")])
  checkFalse ref "match NOT fail"   (filterMatch f4 [("status", Just "200")])
  checkTrue  ref "match presence"   (filterMatch f5 attrs)
  checkFalse ref "match presence absent" (filterMatch f5 [("status", Just "200")])
  checkTrue  ref "match nil value present" (filterMatch f5 [("host", Nothing)])

  -- ---- Wildcard matching via filter ------------------------------------------
  let wf s = case parseFilter s of { Right f -> f; Left _ -> error "parse failed" }

  checkTrue  ref "wc trailing match"    (filterMatch (wf "(host=www.*)") attrs)
  checkFalse ref "wc trailing no match" (filterMatch (wf "(host=www.*)") [("host", Just "other.com")])
  checkTrue  ref "wc leading match"     (filterMatch (wf "(host=*.com)") attrs)
  checkFalse ref "wc leading no match"  (filterMatch (wf "(host=*.com)") [("host", Just "www.org")])
  checkTrue  ref "wc both match"        (filterMatch (wf "(host=*example*)") attrs)
  checkFalse ref "wc both no match"     (filterMatch (wf "(host=*xyz*)") attrs)
  checkTrue  ref "wc star alone"        (filterMatch (wf "(host=*)") attrs)

  -- wildcard-matches-p direct tests
  let wp parts l t = WildcardPattern parts l t
  checkTrue  ref "wc trailing direct"   (wildcardMatches (wp ["abc", ""] False True) "abcXYZ")
  checkFalse ref "wc trailing fail"     (wildcardMatches (wp ["abc", ""] False True) "XYZabc")
  checkTrue  ref "wc leading direct"    (wildcardMatches (wp ["", "abc"] True False) "XYZabc")
  checkFalse ref "wc leading fail"      (wildcardMatches (wp ["", "abc"] True False) "abcXYZ")
  checkTrue  ref "wc foo* foobar"       (wildcardMatches (wp ["foo", ""] False True) "foobar")
  checkFalse ref "wc foo* barfoo"       (wildcardMatches (wp ["foo", ""] False True) "barfoo")
  checkTrue  ref "wc *bar foobar"       (wildcardMatches (wp ["", "bar"] True False) "foobar")
  checkFalse ref "wc *bar barfoo"       (wildcardMatches (wp ["", "bar"] True False) "barfoo")
  checkFalse ref "wc *oo* bar"          (wildcardMatches (wp ["", "oo", ""] True True) "bar")
  checkTrue  ref "wc *oo* foobar"       (wildcardMatches (wp ["", "oo", ""] True True) "foobar")

  -- ---- Approx match ----------------------------------------------------------
  let f6 = case parseFilter "(name~=john)" of Right f -> f; _ -> error "parse"
  checkTrue  ref "approx match"     (filterMatch f6 [("name", Just "jonn")])
  checkFalse ref "approx no match"  (filterMatch f6 [("name", Just "smith")])

  -- ---- LTSV ------------------------------------------------------------------
  let ltsvLine = "host:example.com\tstatus:200"
  let ltsvAttrs = parseLtsvLine ltsvLine
  check ref "ltsv host"   (Just (Just "example.com")) (lookup "host"   ltsvAttrs)
  check ref "ltsv status" (Just (Just "200"))         (lookup "status" ltsvAttrs)

  let ltsvEsc = "key:val\\nue"
  let ltsvEscAttrs = parseLtsvLine ltsvEsc
  check ref "ltsv newline escape"
        (Just (Just "val\nue"))
        (lookup "key" ltsvEscAttrs)

  let ltsvEmpty = "empty:"
  check ref "ltsv empty value" (Just Nothing) (lookup "empty" (parseLtsvLine ltsvEmpty))

  -- ---- CSV -------------------------------------------------------------------
  check ref "csv simple"      ["a", "b", "c"]   (parseCsvLine "a,b,c")
  check ref "csv quoted"      ["a,b", "c"]       (parseCsvLine "\"a,b\",c")
  check ref "csv dquote"      ["a\"b", "c"]      (parseCsvLine "\"a\"\"b\",c")
  check ref "csv empty field" ["a", "", "c"]     (parseCsvLine "a,,c")

  -- ---- Output formatting -----------------------------------------------------
  let symAttrs = [("host", Just "example.com"), ("status", Just "200")]
  check ref "inspect symbol keys"
        "{host: \"example.com\", status: \"200\"}\n"
        (formatAttrs symAttrs)

  let nonSymAttrs = [("key-with-dash", Just "val")]
  check ref "inspect non-symbol key"
        "{\"key-with-dash\" => \"val\"}\n"
        (formatAttrs nonSymAttrs)

  check ref "format nil value"
        "{key: nil}\n"
        (formatAttrs [("key", Nothing)])

  -- ---- Summary ---------------------------------------------------------------
  TestState p f <- readIORef ref
  putStrLn $ show p ++ " passed, " ++ show f ++ " failed"
  if f > 0 then exitFailure else exitSuccess

  where
    f1 = case parseFilter "(host=www.example.com)" of Right f -> f; _ -> error "f1"
    f2 = case parseFilter "(&(host=www.example.com)(status=200))" of Right f -> f; _ -> error "f2"
    f3 = case parseFilter "(|(host=www.example.com)(status=200))" of Right f -> f; _ -> error "f3"
    f4 = case parseFilter "(!(status=200))" of Right f -> f; _ -> error "f4"
    f5 = case parseFilter "(host=*)" of Right f -> f; _ -> error "f5"
