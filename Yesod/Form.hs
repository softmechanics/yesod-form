{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE PackageImports #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE CPP #-}
-- | Parse forms (and query strings).
module Yesod.Form
    ( -- * Data types
      GForm
    , FormResult (..)
    , Enctype (..)
    , FormFieldSettings (..)
    , Textarea (..)
    , FieldInfo (..)
      -- ** Utilities
    , formFailures
      -- * Type synonyms
    , Form
    , Formlet
    , FormField
    , FormletField
    , FormInput
      -- * Unwrapping functions
    , generateForm
    , runFormGet
    , runFormMonadGet
    , runFormPost
    , runFormPostNoNonce
    , runFormMonadPost
    , runFormGet'
    , runFormPost'
      -- ** High-level form post unwrappers
    , runFormTable
    , runFormDivs
      -- * Field/form helpers
    , fieldsToTable
    , fieldsToDivs
    , fieldsToPlain
    , checkForm
      -- * Type classes
    , module Yesod.Form.Class
      -- * Template Haskell
    , mkToForm
    , module Yesod.Form.Fields
    ) where

import Yesod.Form.Core
import Yesod.Form.Fields
import Yesod.Form.Class
import Yesod.Form.Profiles (Textarea (..))
import Yesod.Widget (GWidget)

import Text.Hamlet
import Yesod.Request
import Yesod.Handler
import Control.Applicative hiding (optional)
import Data.Maybe (fromMaybe, mapMaybe)
import "transformers" Control.Monad.IO.Class
import Control.Monad ((<=<))
import Language.Haskell.TH.Syntax
import Database.Persist.Base (EntityDef (..), PersistEntity (entityDef))
import Data.Char (toUpper, isUpper)
import Control.Arrow ((&&&))
import Data.List (group, sort)

-- | Display only the actual input widget code, without any decoration.
fieldsToPlain :: FormField sub y a -> Form sub y a
fieldsToPlain = mapFormXml $ mapM_ fiInput

-- | Display the label, tooltip, input code and errors in a single row of a
-- table.
fieldsToTable :: FormField sub y a -> Form sub y a
fieldsToTable = mapFormXml $ mapM_ go
  where
    go fi =
#if __GLASGOW_HASKELL__ >= 700
                [hamlet|
#else
                [$hamlet|
#endif
%tr.$clazz.fi$
    %td
        %label!for=$fiIdent.fi$ $fiLabel.fi$
        .tooltip $fiTooltip.fi$
    %td
        ^fiInput.fi^
    $maybe fiErrors.fi err
        %td.errors $err$
|]
    clazz fi = if fiRequired fi then "required" else "optional"

-- | Display the label, tooltip, input code and errors in a single div.
fieldsToDivs :: FormField sub y a -> Form sub y a
fieldsToDivs = mapFormXml $ mapM_ go
  where
    go fi =
#if __GLASGOW_HASKELL__ >= 700
                [hamlet|
#else
                [$hamlet|
#endif
.$clazz.fi$
    %label!for=$fiIdent.fi$ $fiLabel.fi$
        .tooltip $fiTooltip.fi$
    ^fiInput.fi^
    $maybe fiErrors.fi err
        %div.errors $err$
|]
    clazz fi = if fiRequired fi then "required" else "optional"

-- | Run a form against POST parameters, without CSRF protection.
runFormPostNoNonce :: GForm s m xml a -> GHandler s m (FormResult a, xml, Enctype)
runFormPostNoNonce f = do
    rr <- getRequest
    (pp, files) <- liftIO $ reqRequestBody rr
    runFormGeneric pp files f

-- | Run a form against POST parameters.
--
-- This function includes CSRF protection by checking a nonce value. You must
-- therefore embed this nonce in the form as a hidden field; that is the
-- meaning of the fourth element in the tuple.
runFormPost :: GForm s m xml a -> GHandler s m (FormResult a, xml, Enctype, Html)
runFormPost f = do
    rr <- getRequest
    (pp, files) <- liftIO $ reqRequestBody rr
    nonce <- fmap reqNonce getRequest
    (res, xml, enctype) <- runFormGeneric pp files f
    let res' =
            case res of
                FormSuccess x ->
                    if lookup nonceName pp == Just nonce
                        then FormSuccess x
                        else FormFailure ["As a protection against cross-site request forgery attacks, please confirm your form submission."]
                _ -> res
    return (res', xml, enctype, hidden nonce)
  where
    hidden nonce =
#if __GLASGOW_HASKELL__ >= 700
                [hamlet|
#else
                [$hamlet|
#endif
    %input!type=hidden!name=$nonceName$!value=$nonce$
|]

nonceName :: String
nonceName = "_nonce"

-- | Run a form against POST parameters. Please note that this does not provide
-- CSRF protection.
runFormMonadPost :: GFormMonad s m a -> GHandler s m (a, Enctype)
runFormMonadPost f = do
    rr <- getRequest
    (pp, files) <- liftIO $ reqRequestBody rr
    runFormGeneric pp files f

-- | Run a form against POST parameters, disregarding the resulting HTML and
-- returning an error response on invalid input. Note: this does /not/ perform
-- CSRF protection.
runFormPost' :: GForm sub y xml a -> GHandler sub y a
runFormPost' f = do
    rr <- getRequest
    (pp, files) <- liftIO $ reqRequestBody rr
    x <- runFormGeneric pp files f
    helper x

-- | Create a table-styled form.
--
-- This function wraps around 'runFormPost' and 'fieldsToTable', taking care of
-- some of the boiler-plate in creating forms. In particular, is automatically
-- creates the form element, sets the method, action and enctype attributes,
-- adds the CSRF-protection nonce hidden field and inserts a submit button.
runFormTable :: Route m -> String -> FormField s m a
             -> GHandler s m (FormResult a, GWidget s m ())
runFormTable dest inputLabel form = do
    (res, widget, enctype, nonce) <- runFormPost $ fieldsToTable form
    let widget' =
#if __GLASGOW_HASKELL__ >= 700
                [hamlet|
#else
                [$hamlet|
#endif
%form!method=post!action=@dest@!enctype=$enctype$
    %table
        ^widget^
        %tr
            %td!colspan=2
                $nonce$
                %input!type=submit!value=$inputLabel$
|]
    return (res, widget')

-- | Same as 'runFormPostTable', but uses 'fieldsToDivs' for styling.
runFormDivs :: Route m -> String -> FormField s m a
            -> GHandler s m (FormResult a, GWidget s m ())
runFormDivs dest inputLabel form = do
    (res, widget, enctype, nonce) <- runFormPost $ fieldsToDivs form
    let widget' =
#if __GLASGOW_HASKELL__ >= 700
                [hamlet|
#else
                [$hamlet|
#endif
%form!method=post!action=@dest@!enctype=$enctype$
    ^widget^
    %div
        $nonce$
        %input!type=submit!value=$inputLabel$
|]
    return (res, widget')

-- | Run a form against GET parameters, disregarding the resulting HTML and
-- returning an error response on invalid input.
runFormGet' :: GForm sub y xml a -> GHandler sub y a
runFormGet' = helper <=< runFormGet

helper :: (FormResult a, b, c) -> GHandler sub y a
helper (FormSuccess a, _, _) = return a
helper (FormFailure e, _, _) = invalidArgs e
helper (FormMissing, _, _) = invalidArgs ["No input found"]

-- | Generate a form, feeding it no data. The third element in the result tuple
-- is a nonce hidden field.
generateForm :: GForm s m xml a -> GHandler s m (xml, Enctype, Html)
generateForm f = do
    (_, b, c) <- runFormGeneric [] [] f
    nonce <- fmap reqNonce getRequest
    return (b, c,
#if __GLASGOW_HASKELL__ >= 700
                [hamlet|
#else
                [$hamlet|
#endif
    %input!type=hidden!name=$nonceName$!value=$nonce$
|])

-- | Run a form against GET parameters.
runFormGet :: GForm s m xml a -> GHandler s m (FormResult a, xml, Enctype)
runFormGet f = do
    gs <- reqGetParams `fmap` getRequest
    runFormGeneric gs [] f

runFormMonadGet :: GFormMonad s m a -> GHandler s m (a, Enctype)
runFormMonadGet f = do
    gs <- reqGetParams `fmap` getRequest
    runFormGeneric gs [] f

-- | Create 'ToForm' instances for the given entity. In addition to regular 'EntityDef' attributes understood by persistent, it also understands label= and tooltip=.
mkToForm :: PersistEntity v => v -> Q [Dec]
mkToForm =
    fmap return . derive . entityDef
  where
    afterPeriod s =
        case dropWhile (/= '.') s of
            ('.':t) -> t
            _ -> s
    beforePeriod s =
        case break (== '.') s of
            (t, '.':_) -> Just t
            _ -> Nothing
    getSuperclass (_, _, z) = getTFF' z >>= beforePeriod
    getTFF (_, _, z) = maybe "toFormField" afterPeriod $ getTFF' z
    getTFF' [] = Nothing
    getTFF' (('t':'o':'F':'o':'r':'m':'F':'i':'e':'l':'d':'=':x):_) = Just x
    getTFF' (_:x) = getTFF' x
    getLabel (x, _, z) = fromMaybe (toLabel x) $ getLabel' z
    getLabel' [] = Nothing
    getLabel' (('l':'a':'b':'e':'l':'=':x):_) = Just x
    getLabel' (_:x) = getLabel' x
    getTooltip (_, _, z) = fromMaybe "" $ getTooltip' z
    getTooltip' (('t':'o':'o':'l':'t':'i':'p':'=':x):_) = Just x
    getTooltip' (_:x) = getTooltip' x
    getTooltip' [] = Nothing
    getId (_, _, z) = fromMaybe "" $ getId' z
    getId' (('i':'d':'=':x):_) = Just x
    getId' (_:x) = getId' x
    getId' [] = Nothing
    getName (_, _, z) = fromMaybe "" $ getName' z
    getName' (('n':'a':'m':'e':'=':x):_) = Just x
    getName' (_:x) = getName' x
    getName' [] = Nothing
    derive :: EntityDef -> Q Dec
    derive t = do
        let cols = map ((getId &&& getName) &&& ((getLabel &&& getTooltip) &&& getTFF)) $ entityColumns t
        ap <- [|(<*>)|]
        just <- [|pure|]
        nothing <- [|Nothing|]
        let just' = just `AppE` ConE (mkName $ entityName t)
        string' <- [|string|]
        ftt <- [|fieldsToTable|]
        ffs' <- [|FormFieldSettings|]
        let stm "" = nothing
            stm x = just `AppE` LitE (StringL x)
        let go_ = go ap just' ffs' stm string' ftt
        let c1 = Clause [ ConP (mkName "Nothing") []
                        ]
                        (NormalB $ go_ $ zip cols $ map (const nothing) cols)
                        []
        xs <- mapM (const $ newName "x") cols
        let xs' = map (AppE just . VarE) xs
        let c2 = Clause [ ConP (mkName "Just") [ConP (mkName $ entityName t)
                            $ map VarP xs]]
                        (NormalB $ go_ $ zip cols xs')
                        []
        let y = mkName "y"
        let ctx = map (\x -> ClassP (mkName x) [VarT y])
                $ map head $ group $ sort
                $ mapMaybe getSuperclass
                $ entityColumns t
        return $ InstanceD ctx ( ConT ''ToForm
                              `AppT` ConT (mkName $ entityName t)
                              `AppT` VarT y)
            [FunD (mkName "toForm") [c1, c2]]
    go ap just' ffs' stm string' ftt a =
        let x = foldl (ap' ap) just' $ map (go' ffs' stm string') a
         in ftt `AppE` x
    go' ffs' stm string' (((theId, name), ((label, tooltip), tff)), ex) =
        let label' = LitE $ StringL label
            tooltip' = string' `AppE` LitE (StringL tooltip)
            ffs = ffs' `AppE`
                  label' `AppE`
                  tooltip' `AppE`
                  (stm theId) `AppE`
                  (stm name)
         in VarE (mkName tff) `AppE` ffs `AppE` ex
    ap' ap x y = InfixE (Just x) ap (Just y)

toLabel :: String -> String
toLabel "" = ""
toLabel (x:rest) = toUpper x : go rest
  where
    go "" = ""
    go (c:cs)
        | isUpper c = ' ' : c : go cs
        | otherwise = c : go cs

formFailures :: FormResult a -> Maybe [String]
formFailures (FormFailure x) = Just x
formFailures _ = Nothing
