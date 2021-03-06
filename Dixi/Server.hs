{-# LANGUAGE DataKinds         #-}
{-# LANGUAGE PolyKinds         #-}
{-# LANGUAGE TypeFamilies      #-}
{-# LANGUAGE TypeOperators     #-}
{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE CPP               #-}
{-# LANGUAGE ViewPatterns      #-}
{-# LANGUAGE ConstraintKinds   #-}

module Dixi.Server where

import Control.Monad.IO.Class
import Control.Monad.Trans.Except
import Data.Acid
import Data.Default
import Data.Time
import Data.Text (Text)
import Data.Traversable
import Servant
import Text.Pandoc
#ifdef OLDBASE
import Control.Applicative
#endif

import qualified Data.Text         as T

import Dixi.API
import Dixi.Common
import Dixi.Config
import Dixi.Database
import Dixi.Forms  () -- imported for orphans
import Dixi.Markup (writePandocError, dixiError)
import Dixi.Page

spacesToUScores :: T.Text -> T.Text
spacesToUScores = T.pack . map (\x -> if x == ' ' then '_' else x) . T.unpack

page :: AcidState Database -> Renders -> Key -> Server PageAPI
page db renders (spacesToUScores -> key)
  =  latest
  |: history
  where
    latest  =  latestQ pp |: latestQ rp

    diffPages (Just v1) (Just v2) = liftIO (query db (GetDiff key (v1, v2)))
                                       >>= \case Left  e -> handle e
                                                 Right x -> return $ DP renders key v1 v2 x
    diffPages _ _ = throwE err400

    history =  liftIO (H renders key <$> query db (GetHistory key))
            |: version
            |: diffPages
            |: reversion

    reversion (DR v1 v2 com) = do
      _ <- liftIO (getCurrentTime >>= update db . Revert key (v1, v2) com)
      latestQ pp
    version v =  (versionQ pp v |: versionQ rp v)
              |: updateVersion v
    updateVersion v (NB t c) = do _ <- liftIO (getCurrentTime >>= update db . Amend key v t c)
                                  latestQ pp

    latestQ :: (Key -> Version -> Page Text -> IO a) -> ExceptT ServantErr IO a
    latestQ p = liftIO (uncurry (p key) =<< query db (GetLatest key))

    versionQ :: (Key -> Version -> Page Text -> IO a) -> Version -> ExceptT ServantErr IO a
    versionQ p v = liftIO (query db (GetVersion key v))
                      >>= \case Left  e -> handle e
                                Right x -> liftIO (p key v x)


    pp :: Key -> Version -> Page Text -> IO PrettyPage
    pp k v p = fmap (PP renders k v) $ for p $ \b ->
                 case pandocReader renders def (filter (/= '\r') . T.unpack $ b) of
                   Left err -> return $ writePandocError err
                   Right pd -> writeHtml (pandocWriterOptions renders) <$> runEndoIO (pandocProcessors renders) pd

    rp k v p = return (RP renders k v p)

    handle :: DixiError -> ExceptT ServantErr IO a
    handle e = throwE err404 { errBody = dixiError (headerBlock renders) e }


server :: AcidState Database -> Renders -> Server Dixi
server db cfg =  page db cfg
              |: page db cfg "Main_Page"

