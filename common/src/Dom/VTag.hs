module Dom.VTag (module Dom.VTag) where

import Data.TH
import Language.Haskell.TH
import Language.Haskell.TH.Syntax

import Basis hiding (Type)


--------------------------------------------------------------------------------
-- * VTag
--
data family VTag' a b

type VTag a = VTag' () a

class ReifyVTag (a :: *) where
  reifyVTag :: Proxy a -> VTag a

--------------------------------------------------------------------------------
-- * Das Ground Table Gen
--
-- | Given a GADT 'data Xxx ix' declaration, define:
--
--   - the 'data family Ty ix' instances for the tag GADT
--   - instances for the 'Xxx ix':
--     - Eq
--     - GEq, GCompare
--     - Show
--     - Serialise
--   - groundTable :: TyDicts Ground
--
--   This operates in two phases:
--
--   1. Parse the GADT decl into a list of 'TagDecl',
--   2. Emit all those definitions, proportional to that list.
--
data TagDecl
  = TagDecl
    { tdStem   :: String
    , tdTy     :: Maybe Type
    , tdGround :: Bool
    }
  deriving Show

defineGroundTypes :: Q [Dec] -> Q [Dec]
defineGroundTypes qDec = qDec >>= emit
 where
   [a, b, c, f, r, x] = mkName <$> ["a", "b", "c", "f", "r", "x"]
   refl            = mkName "Refl"
   just            = mkName "Just"
   nothing         = mkName "Nothing"
   tag             = mkName "tag"
   vtag            = mkName "VTag"
   vtag'           = mkName "VTag'"
   pair            = mkName "(,)"
   unit            = mkName "()"
   dot             = mkName "."
   typeable        = mkName "Typeable"
   reifyvtag       = mkName "ReifyVTag"
   eRror           = mkName "error"
   groundTable     = mkName "groundTable"
   serialiseN      = mkName "Serialise"
   capNs           = OccName <$> ["T", "TS", "TSG"]

   qualRef :: String -> String -> Name
   qualRef qual name = Name (OccName name) (NameQ $ ModName qual)

   tyUncons :: Type -> (OccName -> Bool) -> (Type, Maybe Name)
   tyUncons t@(AppT (thAppHead -> PromotedT n@(Name occ _)) _xs) f' =
     (\xx -> trace ("tyUncons " <> show t <> " -> " <> show (snd xx)) xx) $
     if f' occ
     then (thAppTailIf (const True) t, Just n)
     else (t, Nothing)
   tyUncons t _f =
     (\xx -> trace ("tyUncons " <> show t <> " -> " <> show (snd xx)) xx) $
     (t, Nothing)

   splitTyDecl :: Type -> (Type, Bool)
   splitTyDecl t = case tyUncons t (flip elem capNs) of
                     (xs, Just (Name (OccName "TSG") _)) -> (xs, True)
                     (xs, Just{})  -> (xs, False)
                     (xs, Nothing) -> (xs, False)

   tableEntry :: Type -> String -> Exp
   tableEntry ty name =
     AppE (AppE (VarE (qualRef "TyDict" "insert"))
                (LitE (StringL name)))
          (AppTypeE (ConE $ mkName "Proxy")
                    ty)
   tableStep :: TagDecl -> Exp -> Exp
   tableStep TagDecl{tdTy = Just ty, ..} acc =
     if tdGround
     then AppE (tableEntry ty tdStem) acc
     else trace ("Ground table:  skipping " <> show ty) acc
   tableStep _ acc = acc -- skip the catch-all: no ground dict entry made

   emit :: [Dec] -> Q [Dec]
   emit [DataD [] dataNameRaw [PlainTV tyIxName] Nothing cons derivs] = do
     (!decls) :: [TagDecl] <- mapM conDecl cons
       -- TagDecl "Top" Nothing -- the catch-all for non-Ground types.
       -- : -- we interpret the retTy of 'a' as a catch-all.

     let declsNoTop = filter (isJust . tdTy) decls
         declsGround = filter tdGround decls

     pure $
       [ DataInstD [] {- no context -}
                 Nothing {- no tyvar binds -}
                 (AppT (AppT (ConT dataName) (ConT unit)) (VarT tyIxName))
                 Nothing    -- no kind spec
         (decls <&>
          \TagDecl{..} ->
             let conTname = 'V':tdStem in
             GadtC [Name (OccName conTname) NameS] []
                   (ForallT
                      []
                      (let cty = maybe (VarT tyIxName)
                                       id
                                       tdTy
                       in [ AppT (ConT typeable)  cty
                          , AppT (ConT reifyvtag) cty
                          ]) $
                     (AppT (AppT (ConT dataName) (ConT unit)) $
                       -- Here again, 'Nothing' for the type means catchall.
                           fromMaybe (VarT tyIxName) tdTy)))
         derivs     -- no derive clauses
       -- instance Eq (VTag' () a) where
       --   a == b = case (,) a b of
       --              (,) VXxx VXxx -> True
       --              _ -> False
       , SigD groundTable
                (AppT (ConT $ mkName "TyDicts") (ConT $ mkName "Ground"))
       , ValD (VarP groundTable)
              (NormalB $ foldr tableStep (VarE (qualRef "TyDict" "empty"))
                               declsGround)
              []
       , InstanceD Nothing []
           (AppT (ConT $ mkName "Eq") (AppT (AppT (ConT vtag') (ConT unit))
                                            (VarT a)))
           [ FunD (mkName "==")
               [ Clause [VarP a, VarP b]
                   (NormalB $
                      CaseE (AppE (AppE (ConE pair) (VarE a)) (VarE b))
                            ((decls <&>
                             \TagDecl{..} ->
                               let tag' = mkName $ "V" <> tdStem
                               in Match (ConP pair [ConP tag' [], ConP tag' []])
                                        (NormalB . ConE $ mkName "True") [])
                             <>
                             [Match WildP
                                    (NormalB . ConE $ mkName "False") []])) []
               ]]
       -- instance GEq (VTag' ()) where
       --   geq a b = case (a,b) of
       --     (,) VXxx VXxx -> Just Refl ...
       --     _ -> Nothing
       , InstanceD Nothing []
           (AppT (ConT $ mkName "GEq") (AppT (ConT vtag') (ConT unit)))
           [ FunD (mkName "geq")
               [ Clause [VarP a, VarP b]
                   (NormalB $
                      CaseE (AppE (AppE (ConE pair) (VarE a)) (VarE b))
                            ((declsNoTop <&>
                             \TagDecl{..} ->
                               let tag' = mkName $ "V" <> tdStem
                               in Match (ConP pair [ConP tag' [], ConP tag' []])
                                        (NormalB $
                                           AppE (ConE just) (ConE refl)) [])
                             <>
                             [Match WildP
                                    (NormalB $ ConE nothing) []])) []
               ]]
       -- instance GCompare CTag where
       --   gcompare a b = case geq a b of
       --     Just Refl -> GEQ
       --     Nothing -> case orderCTag a `compare` orderCTag b of
       --       LT -> GLT
       --       GT -> GGT
       --    where
       --      orderCTag :: forall a. CTag a -> Int
       --      orderCTag = \case
       --        CPoint -> 0 ...
       , let geq = mkName "GEQ"
             glt = mkName "GLT"
             ggt = mkName "GGT"
             compar = mkName "compare"
             orderVTag = mkName "orderVTag" in
         InstanceD Nothing []
           (AppT (ConT $ mkName "GCompare") (AppT (ConT vtag') (ConT unit)))
           [ FunD (mkName "gcompare")
               [ Clause [VarP a, VarP b]
                   (NormalB $
                      CaseE (AppE (AppE (VarE $ mkName "geq") (VarE a)) (VarE b))
                            [ Match (ConP just [ConP refl []])
                                    (NormalB $ ConE geq)
                                    []
                            , Match (ConP nothing [])
                                    (NormalB $
                                     CaseE (AppE (AppE (VarE compar)
                                                    (AppE (VarE orderVTag) (VarE a)))
                                                 (AppE (VarE orderVTag) (VarE b)))
                                           [ Match (ConP (mkName "LT") [])
                                                   (NormalB $ ConE glt) []
                                           , Match (ConP (mkName "GT") [])
                                                   (NormalB $ ConE ggt) []
                                           -- XXX: this is dangerous.
                                           , Match (ConP (mkName "EQ") [])
                                                   (NormalB $ ConE ggt) []
                                           ]) []
                            ])
                 [ SigD orderVTag $
                   ForallT [PlainTV a] [] $
                     funT [ AppT (ConT vtag) (VarT a)
                          , ConT $ mkName "Int"]
                 , FunD orderVTag
                     [ Clause
                         []
                         (NormalB . LamCaseE $
                            zip decls [0..] <&>
                            \(TagDecl{..}, n) ->
                                Match (ConP (mkName $ "V" <> tdStem) [])
                                      (NormalB . LitE $ IntegerL n) []) [] ]]]]
       , InstanceD Nothing []
           (AppT (ConT $ mkName "Show")
                 (AppT (AppT (ConT vtag') (ConT unit)) (VarT a)))
           [ FunD (mkName "show")
               [ Clause []
                   (NormalB . LamCaseE $
                      decls <&>
                      \TagDecl{..} ->
                        let tag' = "V" <> tdStem
                        in Match (ConP (mkName tag') [])
                                 (NormalB . LitE $ StringL tag') []) []
               ]]
       -- instance Serialise SomeCTag where
       --   encode = \(SomeCTag tag) -> case tag of
       --     CPoint -> CBOR.encodeWord 1 ...
       , InstanceD Nothing []
           (AppT (ConT $ mkName "Serialise") (ConT $ mkName "SomeVTag"))
           [ FunD (mkName "encode")
               [ Clause []
                 (NormalB
                   (LamE [ConP (mkName "SomeVTag")
                          [SigP (VarP tag)
                                (AppT (ConT vtag) (VarT c))]] $
                      CaseE (VarE tag) $
                        zip decls [256..] <&>
                          \(TagDecl{..}, n) ->
                              Match (ConP (mkName $ "V" <> tdStem) [])
                                (NormalB $
                                  let tagE = AppE (VarE $ mkName "encodeWord")
                                                  (LitE $ IntegerL n)
                                      prependTopRep x' =
                                        InfixE (Just x')
                                               (VarE $ mkName "<>")
                                               (Just $ AppE
                                                         (VarE $ mkName "encode")
                                                         (AppTypeE
                                                           (VarE $ mkName "typeRep")
                                                           (VarT c)))
                                  in if isJust tdTy
                                     then tagE
                                     else prependTopRep tagE)
                              []
                         )) []
               ]
       -- instance Serialise SomeCTag where
       --   decode = do
       --     tag <- CBOR.decodeWord
       --     case tag of
       --       1 -> pure $ SomeCTag CPoint ...
       --       _ -> fail $ "invalid SomeCTag encoding: tag="<>show tag
           , FunD
               (mkName "decode")
               [ Clause
                 []
                 (NormalB $ DoE
                   [ BindS (VarP tag)
                           (VarE $ mkName "decodeWord")
                   , NoBindS $
                       CaseE (VarE tag) $
                         (zip decls [256..] <&>
                           \(TagDecl{..}, n) ->
                              Match (LitP $ IntegerL n)
                              (NormalB $
                                 if isJust tdTy
                                 then AppE (VarE $ mkName "pure") $
                                           AppE (ConE $ mkName "SomeVTag")
                                                (ConE $ mkName $ "V" <> tdStem)
                                 else VarE (mkName "decodeVTop")) [])
                         <>
                         [Match (VarP a)
                           (NormalB
                             (AppE (VarE eRror)
                               (InfixE
                                 (Just . LitE $ StringL "decode @VTag: ")
                                 (VarE $ mkName "<>")
                                 (Just $ AppE (VarE (mkName "show")) (VarE a))))) []]
                   ]) []
               ]
           ]

       -- withVTag :: VTag a -> ((Typeable a, ReifyVTag a) => r) -> r
       -- withVTag x f = case x of
       --   VTop -> f
       , SigD (mkName "withVTag") $
           funT [ AppT (ConT vtag) (VarT a)
                , ForallT []
                    [ AppT (ConT typeable)  (VarT a)
                    , AppT (ConT reifyvtag) (VarT a)] $
                    VarT r
                , VarT r ]
       , FunD (mkName "withVTag") . (:[]) $
           Clause
             [VarP x, VarP f]
             (NormalB $
               CaseE (VarE x) $
                 decls <&>
                  \TagDecl{..} ->
                     Match (ConP (mkName $ 'V':tdStem) [])
                      (NormalB $ VarE f) []) []
       -- mkSomeValue ::
       --   (Typeable c, ReifyCTag c)
       --   => CTag c -> VTag v -> Repr c v -> SomeValue
       -- , SigD (mkName "mkSomeValue") $
       --     ForallT [PlainTV c, PlainTV v]
       --             [ AppT (ConT typeable) (VarT c)
       --             , AppT (ConT reifyctag) (VarT c)] $
       --       funT [ AppT (ConT ctag) (VarT c)
       --            , AppT (ConT vtag) (VarT v)
       --            , AppT (AppT (ConT repr) (VarT c)) (VarT v)
       --            , ConT somevalue ]
       -- , FunD (mkName "mkSomeValue") $
       --     decls <&>
       --       \TagDecl{..} ->
       --          Clause
       --            [VarP c, AsP v (RecP (mkName $ 'V':tdStem) [])]
       --            (NormalB $
       --               if isJust tdTy
       --               then composeList [ AppE (ConE somevalue) (VarE c)
       --                                , AppE (ConE somevaluekinded) (VarE v)
       --                                , AppE (AppE (VarE mkvalue) (VarE v)) (VarE c)
       --                                ]
       --               else
       --                 AppE (VarE eRror)
       --                      (LitE (StringL "Cannot create SomeKindedValue from a VTop."))) []
       ] ++
       (decls <&>
         \TagDecl{..} ->
           InstanceD
           (maybe (Just Overlappable)
                   -- overlap for the catchall (supposed to be VTop)
                  (const $ Just Incoherent)
                  tdTy)
           (maybe [AppT (ConT typeable) (VarT a)] -- Top requires Typeable.
                  (const []) tdTy)
           (AppT (ConT reifyvtag)
                 (fromMaybe (VarT a) tdTy))
           -- reifyVTag = const VSomething
           [ FunD (mkName $ "reifyVTag")
                  [ Clause
                    []
                    (NormalB $
                     AppE (VarE $ mkName "const")
                     (ConE . mkName $ 'V':tdStem)) []]]
       ) ++ []
       -- (decls <&>
       --   \TagDecl{..} ->
       --     InstanceD
       --     (maybe (Just Overlappable)
     --             -- overlap for the catchall (supposed to be VTop)
     --            (const $ Just Incoherent)
     --            tdTy)
     --     [] -- no context
     --     (AppT (ConT $ mkName "Enum")
     --           (fromMaybe (VarT a) tdTy))
     --     -- reifyVTag = const VSomething
     --     [ FunD (mkName "toEnum")
     --            [ Clause
     --              []
     --              (NormalB $
     --               ConE . mkName $ 'V':tdStem) []]
     --     -- , FunD (mkName "fromEnum")
     --     --        [ Clause
     --     --          []
     --     --          (NormalB $
     --     --           ConE . mkName $ 'V':tdStem) []]
     --     ]
     -- )
    where
      funT :: [Type] -> Type
      funT (fromMaybe (error "Empty list passed to funT -- no fun.")
            . unsnoc -> (xs, x')) =
        foldr (AppT . AppT ArrowT) x' xs

      _composeList :: [Exp] -> Exp
      _composeList (fromMaybe (error "Empty list passed to dot -- no fun.")
           . unsnoc -> (xs, x')) =
        foldr (flip UInfixE (VarE dot)) x' xs

      dataName = nameToDyn dataNameRaw

      nameToDyn :: Name -> Name
      nameToDyn (Name (OccName n) _) = Name (OccName n) NameS

      conDecl :: Con -> Q TagDecl
      conDecl con =
        case con of
          GadtC _ns [] retTy ->
            case nameOf con of
              ('V':tdStem, _name) ->
                case retTy of
                  VarT _ -> pure $ TagDecl tdStem Nothing False
                  ty -> do
                    (,) tdTy tdGround <-
                      case splitTyDecl ty of
                        ret@(_, True) -> pure ret
                        (ty', False) ->
                          (ty',) <$> thNameIsInstanceSpine serialiseN ty'
                    pure $ TagDecl{tdTy = Just tdTy, ..}
              (other, _) -> error $
                "Ground tag constructor name doesn't start with V: " <> other
          GadtC{} -> error $
            "Ground tag specifier allows no arguments: " <> fst (nameOf con)
          _ -> error $
            "Ground tag specifier must be a GADT constructor: " <> show con

      nameOf :: Con -> (String, Name)
      nameOf = \case
        GadtC [] _ _      -> error "Broken GADT variant:  no name"
        GadtC (_:_:_) _ _ -> error "Broken GADT variant:  multiple names"
        GadtC [name@(Name (OccName str) _)] _ _ -> (str, name)
        _                 -> error "Non-GADT constructor"

   emit (x':xs) = (x' :) <$> emit xs
   emit []      = pure []

-- http://hackage.haskell.org/package/template-haskell/docs/Language-Haskell-TH-Lib.html
-- https://ghc.gitlab.haskell.org/ghc/doc/libraries/template-haskell-2.17.0.0/Language-Haskell-TH-Syntax.html
--
-- mkName :: String -> Name
-- type BangType = (Bang, Type)
-- type VarBangType = (Name, Bang, Type)
-- type Cxt = [Pred]	                -- (Eq a, Ord b)
-- TyVarBndr
-- data Type
--   AppT Type Type                     -- T a b
--   VarT Name                          -- a
--   ConT Name	                        -- T
--   ParensT Type
--   ArrowT
--   ForallT [TyVarBndr Specificity] Cxt Type -- forall <vars>. <ctxt> => <type>
-- data Bang
--   Bang SourceUnpackedness SourceStrictness -- C { {-# UNPACK #-} !}a
-- data Body
--   NormalB Exp                        -- f p { = e } where ds
-- data Dec
--   ValD Pat Body [Dec]
--   DataD Cxt Name [TyVarBndr ()] (Maybe Kind) [Con] [DerivClause]
--   FunD Name [Clause]                 -- { f p1 p2 = b where decs }
-- data DerivClause
--   DerivClause (Maybe DerivStrategy) Cxt -- { deriving stock (Eq, Ord) }
-- data Clause
--   Clause [Pat] Body [Dec]            -- f { p1 p2 = body where decs }
-- data Pat
--   VarP Name
--   ConP Name [Pat]                    -- {C1 p1 p1} = e
--   InfixP Pat Name Pat                -- foo ({x :+ y}) = e
--   ParensP Pat
--   RecP Name [FieldPat]               -- f (Pt { pointx = x }) = g x
--   ListP [Pat]
--   SigP Pat Type
--   AsP Name Pat                       -- { x @ p }
-- data Con
--   NormalC Name [BangType]            -- C Int a
--   RecC Name [VarBangType]            -- C { v :: Int, w :: a }
--   GadtC [Name] [BangType] Type       -- C :: a -> b -> T b Int
--   RecGadtC [Name] [VarBangType] Type -- C :: { v :: Int } -> T b Int
-- data Exp
--   VarE Name                          -- { x }
--   ConE Name                          -- data T1 = C1 t1 t2; p = {C1} e1 e2
--   LitE Lit                           --  { 5 or 'c'}
--   AppE Exp Exp                       --  { f x }
--   CaseE Exp [Match]                  -- { case e of m1; m2 }
--   LamE [Pat] Exp                     -- { \ p1 p2 -> e }
--   DoE (Maybe ModName) [Stmt]
-- data Stmt
--   BindS Pat Exp                      -- p <- e
--   LetS [Dec]                         -- { let { x=e1; y=e2 } }
--   NoBindS Exp                        -- e
-- data Match
--   Match Pat Body [Dec]               -- case e of { pat -> body where decs }
-- data TyVarBndr flag
--   PlainTV Name flag                  -- a
--   KindedTV Name flag Kind            -- (a :: k)
-- data Specificity
--   SpecifiedSpec                      -- a
--   InferredSpec                       -- {a}

-- * data Type Source #
--
-- Constructors
--
--  ForallT [TyVarBndr] Cxt Type  forall <vars>. <ctxt> => <type>
--  ForallVisT [TyVarBndr] Type  forall <vars> -> <type>
--  AppT Type Type  T a b
--  AppKindT Type Kind  T @k t
--  SigT Type Kind  t :: k
--  VarT Name  a
--  ConT Name  T
--  PromotedT Name  'T
--  InfixT Type Name Type  T + T
--  UInfixT Type Name Type  T + T
--  ParensT Type  (T)
--  TupleT Int  (,), (,,), etc.
--  UnboxedTupleT Int  (#,#), (#,,#), etc.
--  UnboxedSumT SumArity  (#|#), (#||#), etc.
--  ArrowT  ->
--  EqualityT  ~
--  ListT  []
--  PromotedTupleT Int  '(), '(,), '(,,), etc.
--  PromotedNilT  '[]
--  PromotedConsT  (':)
--  StarT  *
--  ConstraintT  Constraint
--  LitT TyLit  0,1,2, etc.
--  WildCardT  _
--  ImplicitParamT String Type  ?x :: t
