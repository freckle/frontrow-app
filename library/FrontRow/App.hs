-- | Micro-framework for building a non-web application
--
-- This is a version of the /ReaderT Design Pattern/.
--
-- <https://www.fpcomplete.com/blog/2017/06/readert-design-pattern>
--
-- == Basic Usage
--
-- Start by defining a type to hold your global application state:
--
-- > data App = App
-- >   { appDryRun :: Bool
-- >   , appLogLevel :: LogLevel
-- >   }
--
-- This type can be as complex or simple as you want. It might hold a separate
-- @Config@ attribute or may keep everything as one level of properties. It
-- could even hold an @'IORef'@ if you need mutable application state.
--
-- The only requirements are some notion of a @'LogLevel'@:
--
-- > instance HasLogging App where
-- >   getLogLevel = appLogLevel
-- >   getLogFormat _ = FormatTerminal
-- >   getLogLocation _ = LogStdout
--
-- and a way to build a value:
--
-- > loadApp :: IO App
--
-- It's likely you'll want to use @"FrontRow.App.Env"@ to load your @App@:
--
-- > import qualified FrontRow.App.Env as Env
-- >
-- > loadApp = Env.parse $ App
-- >   <$> Env.switch "DRY_RUN" mempty
-- >   <*> Env.flag LevelInfo LevelDebug "DEBUG" mempty
--
-- Though not required, a type synonym can make things throughout your
-- application a bit more readable:
--
-- > type AppM = ReaderT App (LoggingT IO)
--
-- Now you have application-specific actions that can do IO, log, and access
-- your state:
--
-- > myAppAction :: AppM ()
-- > myAppAction = do
-- >   isDryRun <- asks appDryRun
-- >
-- >   if isDryRun
-- >     then $logWarn "Skipping due to dry-run"
-- >     else liftIO $ fireTheMissles
--
-- These actions can be (composed of course, or) invoked by a @main@ that
-- handles the reader context and evaluating the logging action.
--
-- > main :: IO ()
-- > main = do
-- >   app <- loadApp
-- >   runApp app $ do
-- >     myAppAction
-- >     myOtherAppAction
--
-- == Database
--
-- Adding Database access requires an instance of @'HasSqlPool'@ on your @App@
-- type. Most often, this will be easiest if you indeed separate a @Config@
-- attribute:
--
-- > data Config = Config
-- >   { configDbPoolSize :: Int
-- >   , configLogLevel :: LogLevel
-- >   }
--
-- So you can isolate Env-related concerns
--
-- > loadConfig :: IO Config
-- > loadConfig = Env.parse $ Config
-- >   <$> Env.var Env.auto "PGPOOLSIZE" (Env.def 1)
-- >   <*> Env.flag LevelInfo LevelDebug "DEBUG" mempty
--
-- from the runtime application state:
--
-- > data App = App
-- >   { appConfig :: Config
-- >   , appSqlPool :: SqlPool
-- >   }
-- >
-- > instance HasLogging App where
-- >   getLogLevel = configLogLevel . appConfig
-- >   getLogFormat _ = FormatTerminal
-- >   getLogLocation _ = LogStdout
--
-- The @"FrontRow.App.Database"@ module provides @'makePostgresPool'@ for
-- building a Pool given this (limited) config data:
--
-- > loadApp :: IO App
-- > loadApp = do
-- >   appConfig{..} <- loadConfig
-- >   appSqlPool <- makePostgresPool configDbPoolSize
-- >   pure App{..}
-- >
-- > instance HasSqlPool App where
-- >   getSqlPool = appSqlPool
--
-- /Note/: the actual database connection parameters (host, user, etc) are
-- (currently) parsed from conventional environment variables by the underlying
-- driver directly. Our application configuration is only involved in declaring
-- the pool size.
--
-- This unlocks @'runDB'@ for your application:
--
-- > myAppAction :: AppM [Entity Something]
-- > myAppAction = runDB $ selectList [] []
--
-- == Testing
--
-- @"FrontRow.App.Test"@ exposes an @'AppExample'@ type for examples in a
-- @'SpecWith' App@ spec. The can be run by giving your @loadApp@ function to
-- Hspec's @'before'@.
--
-- Our @Test@ module also exposes @'runAppTest'@ for running @AppM@ actions and
-- lifted expectations for use within such an example.
--
-- > spec :: Spec
-- > spec = before loadApp $ do
-- >   describe "myAppAction" $ do
-- >     it "works" $ do
-- >       result <- runAppTest myAppAction
-- >       result `shouldBe` "as expected"
--
-- If your application makes use of the database, a few things will have to be
-- different:
--
-- First, we want to have a specialized @'runDB'@ in tests to avoid excessive
-- annotations because of the generalized type of @'runDB'@ itself:
--
-- > import Database.Persist.Sql
-- > import qualified FrontRow.App.Database as DB
-- >
-- > runDB :: SqlPersistM IO a -> AppExample App a
-- > runDB = DB.runDB
--
-- Second, we'll probably want a conventional @withApp@ function so that we can
-- truncate tables as part of spec setup:
--
-- > import FrontRow.App (runApp)
-- > import FrontRow.App.Test hiding (withApp)
-- > import Test.Hspec
-- >
-- > withApp :: SpecWith App -> Spec
-- > withApp = before $ do
-- >   app <- loadApp
-- >   runSqlPool truncateTables $ appSqlPool app
-- >   pure app
--
-- And now you can write specs that also use the database:
--
-- > spec :: Spec
-- > spec = withApp $ do
-- >   describe "myAppAction" $ do
-- >     it "works" . withGraph runDB do
-- >       nodeWith -- ...
-- >       nodeWith -- ...
-- >       nodeWith -- ...
-- >
-- >       result <- lift $ runAppTest myAppAction
-- >       result `shouldBe` "as expected"
--
module FrontRow.App
  ( runApp
  , module X
  )
where

import Prelude

import Control.Monad.Logger as X
import Control.Monad.Reader as X
import FrontRow.App.Database as X
import FrontRow.App.Logging as X
import System.IO (BufferMode(..), hSetBuffering, stderr, stdout)

runApp :: HasLogging app => app -> ReaderT app (LoggingT IO) a -> IO a
runApp app action = do
  -- Ensure output is streamed if in a Docker container
  hSetBuffering stdout LineBuffering
  hSetBuffering stderr LineBuffering
  runAppLoggerT app $ runReaderT action app
