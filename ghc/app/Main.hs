module Main where

import Control.Exception (try, displayException, SomeException)
import GHC.Clock         (getMonotonicTimeNSec)
import System.Environment (getArgs)
import System.Exit        (exitWith, ExitCode(..))
import System.IO          (hPutStrLn, stderr)

import LdapFilter (run)

main :: IO ()
main = do
  t0   <- getMonotonicTimeNSec
  args <- getArgs
  result <- try (run t0 args) :: IO (Either SomeException ())
  case result of
    Right () -> return ()
    Left e   -> do
      hPutStrLn stderr (displayException e)
      exitWith (ExitFailure 1)
