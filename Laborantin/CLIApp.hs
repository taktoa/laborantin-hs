{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE FlexibleInstances, MultiParamTypeClasses #-}

module Laborantin.CLIApp (defaultMain) where

import Control.Exception (finally)
import Options.Applicative
import Data.Time (UTCTime(..), getCurrentTime)
import System.Locale (defaultTimeLocale)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as T
import qualified Data.Map as M
import Data.Either (rights)
import Data.Maybe (catMaybes)
import Control.Concurrent (readChan, writeChan, Chan (..), newChan)
import Control.Concurrent.Async (async)
import Control.Monad (replicateM_, forM_, void)
import Data.Monoid
import Data.Aeson (encode)

import Data.List (intercalate)
import qualified Data.ByteString.Lazy.Char8 as C

import Laborantin.Types (UExpr (..), TExpr (..), ScenarioDescription (..), Execution (..), ParameterDescription (..), expandValue, paramSets)
import Laborantin.Implementation (EnvIO, runEnvIO, defaultBackend)
import Laborantin (load, remove, runAnalyze, prepare)
import Laborantin.Query.Interpret (toTExpr)
import Laborantin.Query.Parse (parseUExpr, ParsePrefs (..))
import Laborantin.Query (simplifyOneBoolLevel)

data Run = Run
  { runScenarios    :: [String]
  , runParams       :: [String]
  , runMatchers     :: [String]
  , runConcurrency  :: Int
  } deriving (Show)

data Continue = Continue
  { continueScenarios   :: [String]
  , continueParams      :: [String]
  , continueMatchers    :: [String]
  , continueSuccessful  :: Bool
  , continueTodayOnly   :: Bool
  , continueConcurrency :: Int
  } deriving (Show)

data Describe = Describe
  { describeScenarios :: [String]
  } deriving (Show)

data Find = Find
  { findScenarios   :: [String]
  , findParams      :: [String]
  , findMatchers    :: [String]
  , findSuccessful  :: Bool
  , findTodayOnly   :: Bool
  } deriving (Show)

data Analyze = Analyze
  { analyzeScenarios    :: [String]
  , analyzeParams       :: [String]
  , analyzeMatchers     :: [String]
  , analyzeSuccessful   :: Bool
  , analyzeTodayOnly    :: Bool
  , analyzeConcurrency  :: Int
  } deriving (Show)

data Rm = Rm
  { rmScenarios   :: [String]
  , rmParams      :: [String]
  , rmMatchers    :: [String]
  , rmSuccessful  :: Bool
  , rmTodayOnly   :: Bool
  } deriving (Show)

data Params = Params
  { paramsScenarios   :: [String]
  , paramsParams      :: [String]
  , paramsMatchers    :: [String]
  } deriving (Show)

data Query = Query
  { queryScenarios   :: [String]
  , queryParams      :: [String]
  , queryMatchers    :: [String]
  , querySuccessful  :: Bool
  , queryTodayOnly   :: Bool
  } deriving (Show)

data Command = RunCommand Run
  | ContinueCommand Continue
  | DescribeCommand Describe
  | AnalyzeCommand Analyze
  | FindCommand Find
  | RmCommand Rm
  | ParamsCommand Params
  | QueryCommand Query
  deriving (Show)

scenariosOpt = many $ strOption (
     long "scenario"
  <> short 's'
  <> metavar "SCENARIOS"
  <> help "Names of the scenarios to run.")

paramsOpt = many $ strOption (
     long "param"
  <> short 'p'
  <> metavar "PARAMS"
  <> help "name:type:value tuple for parameter.")

matchersOpt = many $ strOption (
     long "matcher"
  <> short 'm'
  <> metavar "MATCHERS"
  <> help "Matcher queries to specify the parameter space.")

concurrencyLeveLOpt = option (
     long "concurrency"
  <> short 'C'
  <> value 1
  <> help "Max concurrent runs.")

successfulFlag = switch (
     long "successful"
  <> help "Only account for successful runs.")

todayFlag = switch (
     long "today"
  <> help "Only account for today's runs.")

run :: Parser Run
run = Run <$> scenariosOpt <*> paramsOpt <*> matchersOpt <*> concurrencyLeveLOpt

continue :: Parser Continue
continue = Continue <$> scenariosOpt <*> paramsOpt <*> matchersOpt <*> successfulFlag <*> todayFlag <*> concurrencyLeveLOpt

describe :: Parser Describe
describe = Describe <$> scenariosOpt

find :: Parser Find
find = Find <$> scenariosOpt <*> paramsOpt <*> matchersOpt <*> successfulFlag <*> todayFlag

analyze :: Parser Analyze
analyze = Analyze <$> scenariosOpt <*> paramsOpt <*> matchersOpt <*> successfulFlag <*> todayFlag <*> concurrencyLeveLOpt

rm :: Parser Rm
rm = Rm <$> scenariosOpt <*> paramsOpt <*> matchersOpt <*> successfulFlag <*> todayFlag

query :: Parser Query
query = Query <$> scenariosOpt <*> paramsOpt <*> matchersOpt <*> successfulFlag <*> todayFlag

params :: Parser Params
params = Params <$> scenariosOpt <*> paramsOpt <*> matchersOpt

runOpts :: ParserInfo Run
runOpts = info (helper <*> run)
          ( fullDesc
         <> progDesc "Executes experiment scenarios."
         <> header "runs a scenario")

continueOpts :: ParserInfo Continue
continueOpts = info (helper <*> continue)
          ( fullDesc
         <> progDesc "Executes missing scenarios."
         <> header "continues scenarios")

describeOpts :: ParserInfo Describe
describeOpts = info (helper <*> describe)
          ( fullDesc
         <> progDesc "Describe scenarios in this project."
         <> header "describes scenarios")

findOpts :: ParserInfo Find
findOpts = info (helper <*> find)
          ( fullDesc
         <> progDesc "Find scenarios executions."
         <> header "finds scenarios")

analyzeOpts :: ParserInfo Analyze
analyzeOpts = info (helper <*> analyze)
          ( fullDesc
         <> progDesc "Analyze scenarios runs by replaying the 'analyze' hook."
         <> header "analyzes scenarios")

rmOpts :: ParserInfo Rm
rmOpts = info (helper <*> rm)
          ( fullDesc
         <> progDesc "Deletes scenario runs, use carefully."
         <> header "removes scenarios")

queryOpts :: ParserInfo Query
queryOpts = info (helper <*> query)
          ( fullDesc
         <> progDesc "Prints the query (for find-like commands) given other program args."
         <> header "removes scenarios")

paramsOpts :: ParserInfo Params
paramsOpts = info (helper <*> params)
          ( fullDesc
         <> progDesc "Prints the params expansion (for run-like commands) given other program args."
         <> header "removes scenarios")

cmd :: Parser Command
cmd = subparser ( command "run" (RunCommand <$> runOpts)
               <> command "continue" (ContinueCommand <$> continueOpts)
               <> command "describe" (DescribeCommand <$> describeOpts)
               <> command "find" (FindCommand <$> findOpts)
               <> command "analyze" (AnalyzeCommand <$> analyzeOpts)
               <> command "rm" (RmCommand <$> rmOpts)
               <> command "params" (ParamsCommand <$> paramsOpts)
               <> command "query" (QueryCommand <$> queryOpts))

mainCmd :: ParserInfo Command
mainCmd = info (helper <*> cmd)
          ( fullDesc
         <> progDesc "Use subcommands to work with your Laborantin experiments."
         <> header "default Laborantin main script")

defaultMain :: [ScenarioDescription EnvIO] -> IO ()
defaultMain xs = do
   command <- execParser mainCmd
   case command of
    RunCommand y      -> runMain xs y
    ContinueCommand y -> continueMain xs y
    DescribeCommand y -> describeMain xs y
    FindCommand y     -> findMain xs y
    AnalyzeCommand y  -> analyzeMain xs y
    RmCommand y       -> rmMain xs y
    ParamsCommand y   -> paramsMain xs y
    QueryCommand y    -> queryMain xs y

-- double-plus non-good helper, should use a "saferead" version instead
unsafeReadText :: (Read a) => Text -> a 
unsafeReadText = read . T.unpack

-- concurrency helper
concurrentmapM_ :: Int -> (a -> IO b) -> [a] -> IO ()
concurrentmapM_ n f xs = do
    goChan <- newChan :: IO (Chan ())
    joinChan <- newChan :: IO (Chan ())
    let f' a = readChan goChan >> f a `finally` (writeChan goChan () >> writeChan joinChan ())
    mapM_ (async . f') xs
    replicateM_ n (writeChan goChan ()) 
    mapM_ (\_ -> readChan joinChan) xs

-- handy types to match Laborantin Scenario executions
newtype Conjunction a = Conjunction {unConjunction ::  a}
newtype Disjunction a = Disjunction {unDisjunction ::  a}

type QueryExpr = TExpr Bool

instance Monoid (Conjunction QueryExpr) where
  mempty                                  = Conjunction (B True)
  mappend (Conjunction x) (Conjunction y) = Conjunction (And x y)

instance Monoid (Disjunction QueryExpr) where
  mempty                                  = Disjunction (B False)
  mappend (Disjunction x) (Disjunction y) = Disjunction (Or x y)

allQueries :: [QueryExpr] -> QueryExpr
allQueries = unConjunction . mconcat . map Conjunction

anyQuery :: [QueryExpr] -> QueryExpr
anyQuery = unDisjunction . mconcat . map Disjunction

-- class and types to turn CLI parameters into Laborantin queries
class ToQueryExpr a where
  toQuery :: ParsePrefs -> a -> QueryExpr

instance ToQueryExpr QueryExpr where
  toQuery _ = id

newtype Params'     = Params' {unParams :: [String]}
newtype Scenarios'  = Scenarios' {unScenarios :: [String]}
newtype Matchers'   = Matchers' {unMatchers :: [String]}
newtype Successful' = Successful' {unSuccessful :: Bool}
newtype TodayOnly'  = TodayOnly' {unTodayOnly :: (Bool, UTCTime)}

instance ToQueryExpr Params' where
  toQuery _ = paramsToTExpr . unParams
          where paramsToTExpr :: [String] -> QueryExpr
                paramsToTExpr xs =
                  let atoms = catMaybes (map (parseParamTExpr . T.pack) xs)
                  in allQueries atoms

                parseParamTExpr :: Text -> Maybe QueryExpr
                parseParamTExpr str =
                  let vals = T.splitOn ":" str in
                  case vals of
                    [k,"str",v]      -> Just (Eq (SCoerce (ScParam k))
                                                 (S v))
                    [k,"int",v]      -> Just (Eq (NCoerce (ScParam k))
                                                 (N . toRational $ unsafeReadText v))
                    [k,"ratio",v]    -> Just (Eq (NCoerce (ScParam k))
                                                 (N $ unsafeReadText v))
                    [k,"float",v]    -> Just (Eq (NCoerce (ScParam k))
                                                 (N $ toRational
                                                      (unsafeReadText v :: Float)))
                    _                -> Nothing


instance ToQueryExpr Scenarios' where
  toQuery _ = scenarsToTExpr . unScenarios
          where scenarsToTExpr :: [String] -> QueryExpr
                scenarsToTExpr [] = B True
                scenarsToTExpr scii =
                  let atoms = map (\name -> (Eq ScName (S $ T.pack name))) scii
                  in anyQuery atoms


instance ToQueryExpr Matchers' where
  toQuery prefs = allQueries
                . map (toTExpr (B True))
                . rights
                . map (parseUExpr prefs)
                . unMatchers

instance ToQueryExpr Successful' where
  toQuery _ = statusToTExpr . unSuccessful
    where statusToTExpr :: Bool -> TExpr Bool
          statusToTExpr True  =     (Eq ScStatus (S "success"))
          statusToTExpr False = Not (Eq ScStatus (S "success"))

instance ToQueryExpr TodayOnly' where
  toQuery _ = uncurry todayToTExpr . unTodayOnly
    where todayToTExpr :: Bool -> UTCTime -> TExpr Bool
          todayToTExpr True today  = (Or (Eq ScTimestamp (T today))
                                         (Gt ScTimestamp (T today)))
          todayToTExpr False _     = B True

instance (ToQueryExpr a) => ToQueryExpr (Conjunction a) where
  toQuery prefs (Conjunction x) = toQuery prefs x

instance (ToQueryExpr a) => ToQueryExpr (Disjunction a) where
  toQuery prefs (Disjunction x) = toQuery prefs x

instance ToQueryExpr Run where
  toQuery prefs args = let
    wrap :: ToQueryExpr a => a -> Conjunction QueryExpr
    wrap a = Conjunction $ toQuery prefs $ a
    params'       = wrap $ Params'   $ runParams args
    scenarios'    = wrap $ Scenarios'$ runScenarios args
    matchers'     = wrap $ Matchers' $ runMatchers args
    in toQuery prefs (params' <> scenarios' <> matchers')

instance ToQueryExpr (Continue, UTCTime) where
  toQuery prefs (args, tst) = let
    wrap :: ToQueryExpr a => a -> Conjunction QueryExpr
    wrap a = Conjunction $ toQuery prefs $ a
    params'       = wrap $ Params'     $ continueParams args
    scenarios'    = wrap $ Scenarios'  $ continueScenarios args
    matchers'     = wrap $ Matchers'   $ continueMatchers args
    status'       = wrap $ Successful' $ continueSuccessful args
    date'         = wrap $ TodayOnly'  $ (continueTodayOnly args, tst)
    in toQuery prefs (params' <> scenarios' <> matchers' <> status' <> date')

instance ToQueryExpr (Find, UTCTime) where
  toQuery prefs (args, tst) = let
    wrap :: ToQueryExpr a => a -> Conjunction QueryExpr
    wrap a = Conjunction $ toQuery prefs $ a
    params'       = wrap $ Params'     $ findParams args
    scenarios'    = wrap $ Scenarios'  $ findScenarios args
    matchers'     = wrap $ Matchers'   $ findMatchers args
    status'       = wrap $ Successful' $ findSuccessful args
    date'         = wrap $ TodayOnly'  $ (findTodayOnly args, tst)
    in toQuery prefs (params' <> scenarios' <> matchers' <> status' <> date')

instance ToQueryExpr (Analyze, UTCTime) where
  toQuery prefs (args, tst) = let
    wrap :: ToQueryExpr a => a -> Conjunction QueryExpr
    wrap a = Conjunction $ toQuery prefs $ a
    params'       = wrap $ Params'     $ analyzeParams args
    scenarios'    = wrap $ Scenarios'  $ analyzeScenarios args
    matchers'     = wrap $ Matchers'   $ analyzeMatchers args
    status'       = wrap $ Successful' $ analyzeSuccessful args
    date'         = wrap $ TodayOnly'  $ (analyzeTodayOnly args, tst)
    in toQuery prefs (params' <> scenarios' <> matchers' <> status' <> date')

instance ToQueryExpr (Rm, UTCTime) where
  toQuery prefs (args, tst) = let
    wrap :: ToQueryExpr a => a -> Conjunction QueryExpr
    wrap a = Conjunction $ toQuery prefs $ a
    params'       = wrap $ Params'     $ rmParams args
    scenarios'    = wrap $ Scenarios'  $ rmScenarios args
    matchers'     = wrap $ Matchers'   $ rmMatchers args
    status'       = wrap $ Successful' $ rmSuccessful args
    date'         = wrap $ TodayOnly'  $ (rmTodayOnly args, tst)
    in toQuery prefs (params' <> scenarios' <> matchers' <> status' <> date')

instance ToQueryExpr Params  where
  toQuery prefs args = let
    wrap :: ToQueryExpr a => a -> Conjunction QueryExpr
    wrap a = Conjunction $ toQuery prefs $ a
    params'       = wrap $ Params'     $ paramsParams args
    scenarios'    = wrap $ Scenarios'  $ paramsScenarios args
    matchers'     = wrap $ Matchers'   $ paramsMatchers args
    in toQuery prefs (params' <> scenarios' <> matchers')

instance ToQueryExpr (Query, UTCTime) where
  toQuery prefs (args, tst) = let
    wrap :: ToQueryExpr a => a -> Conjunction QueryExpr
    wrap a = Conjunction $ toQuery prefs $ a
    params'       = wrap $ Params'     $ queryParams args
    scenarios'    = wrap $ Scenarios'  $ queryScenarios args
    matchers'     = wrap $ Matchers'   $ queryMatchers args
    status'       = wrap $ Successful' $ querySuccessful args
    date'         = wrap $ TodayOnly'  $ (queryTodayOnly args, tst)
    in toQuery prefs (params' <> scenarios' <> matchers' <> status' <> date')


-- Extra helpers

cliScenarios :: [String] -> [ScenarioDescription m] -> [ScenarioDescription m]
cliScenarios names scii = [sc | sc <- scii, sName sc `elem` map T.pack names]

-- | Main program for the 'run' command.
runMain :: [ScenarioDescription EnvIO] -> Run -> IO ()
runMain scii args = do
  let scenarios = cliScenarios (runScenarios args) scii
      query     = toQuery (ParsePrefs defaultTimeLocale) args
      execs     = concatMap (prepare defaultBackend query []) scenarios
  concurrentmapM_ (runConcurrency args) runEnvIO execs

-- | Main program for the 'continue' command.
continueMain :: [ScenarioDescription EnvIO] -> Continue -> IO ()
continueMain scii args = do
  now <- getCurrentTime
  let scenarios = cliScenarios (continueScenarios args) scii
      query = toQuery (ParsePrefs defaultTimeLocale) (args, now)
      loadMatching  = load defaultBackend scenarios query
  matching <- runEnvIO loadMatching
  let execs     = concatMap (prepare defaultBackend query matching) scenarios
  concurrentmapM_ (continueConcurrency args) runEnvIO execs

-- | Main program for the 'describe' command.
-- TODO: use the query information to expand parameter values
describeMain :: [ScenarioDescription EnvIO] -> Describe -> IO ()
describeMain scii args = do
  let scenarios = cliScenarios (describeScenarios args) scii
  forM_ scenarios (T.putStrLn . describeScenario)

  where describeScenario :: ScenarioDescription m -> Text
        describeScenario sc = T.unlines [
            T.append "# Scenario: " (sName sc)
          , T.append "    " (sDesc sc)
          , T.concat ["    ", (T.pack . show . length . paramSets $ sParams sc), " parameter combinations by default"]
          , "## Parameters:"
          , unlines' $ map (uncurry paramLine) $ M.toList $ sParams sc
          ]

        unlines' :: [Text] -> Text
        unlines' = T.intercalate "\n"

        paramLine n p = unlines' [
                          T.append "### " n
                        , describeParameter p
                        ]

        describeParameter :: ParameterDescription -> Text
        describeParameter p = unlines' [
            T.concat ["(", pName p , ")"]
          , T.concat ["    ", pDesc p]
          , T.concat ["    ", (T.pack . show . length $ concatMap expandValue $ pValues p), " values:"]
          , T.pack $ unlines $ map (("    - " ++) . show) (pValues p)
          ]

-- | Main program for the 'find' command.
findMain :: [ScenarioDescription EnvIO] -> Find -> IO ()
findMain scii args = do
  now <- getCurrentTime
  let scenarios = cliScenarios (findScenarios args) scii
      query = toQuery (ParsePrefs defaultTimeLocale) (args, now)
      loadMatching  = load defaultBackend scenarios query
  matching <- runEnvIO loadMatching
  forM_ matching (T.putStrLn . describeExecution)
  where describeExecution :: Execution m -> Text
        describeExecution e = T.pack $ intercalate " " [ ePath e
                                      , T.unpack $ sName (eScenario e)
                                      , "(" ++ show (eStatus e) ++ ")"
                                      , C.unpack $ encode (eParamSet e)
                                      ]

-- | Main program for the 'analyze' command.
analyzeMain :: [ScenarioDescription EnvIO] -> Analyze -> IO ()
analyzeMain scii args = do
  now <- getCurrentTime
  let scenarios = cliScenarios (analyzeScenarios args) scii
      query = toQuery (ParsePrefs defaultTimeLocale) (args, now)
      loadMatching  = load defaultBackend scenarios query
  matching <- runEnvIO loadMatching
  let analyses = map (runAnalyze defaultBackend) matching
  concurrentmapM_ (analyzeConcurrency args) runEnvIO analyses

-- | Main program for the 'rm' command.
rmMain :: [ScenarioDescription EnvIO] -> Rm -> IO ()
rmMain scii args = do
  now <- getCurrentTime
  let scenarios = cliScenarios (rmScenarios args) scii
      query = toQuery (ParsePrefs defaultTimeLocale) (args, now)
      loadMatching  = load defaultBackend scenarios query
  matching <- runEnvIO loadMatching
  let deletions = map (remove defaultBackend) matching
  forM_ deletions runEnvIO

-- | Main program for the 'params' command.
paramsMain :: [ScenarioDescription EnvIO] -> Params -> IO ()
paramsMain scii args = do
  let query = toQuery (ParsePrefs defaultTimeLocale) args
  print $ simplifyOneBoolLevel $ query

-- | Main program for the 'query' command.
queryMain :: [ScenarioDescription EnvIO] -> Query -> IO ()
queryMain scii args = do
  now <- getCurrentTime
  let query = toQuery (ParsePrefs defaultTimeLocale) (args, now)
  print $ simplifyOneBoolLevel $ query
