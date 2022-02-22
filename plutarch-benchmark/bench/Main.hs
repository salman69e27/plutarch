{-# LANGUAGE QualifiedDo #-}

module Main (main) where

import Control.Monad.Trans.Cont (cont, runCont)
import Data.ByteString (ByteString)
import Plutarch (ClosedTerm)
import Plutarch.Api.V1
import Plutarch.Benchmark (NamedBenchmark, bench, bench', benchGroup, benchMain)
import Plutarch.Bool
import Plutarch.Builtin
import qualified Plutarch.List as List
import qualified Plutarch.Monadic as P
import Plutarch.Prelude
import Plutus.V1.Ledger.Address (Address (Address))
import Plutus.V1.Ledger.Api (DCert (DCertGenesis), toData)
import Plutus.V1.Ledger.Contexts (ScriptPurpose (Certifying, Minting, Rewarding, Spending), TxOutRef (TxOutRef))
import Plutus.V1.Ledger.Credential (
  Credential (PubKeyCredential, ScriptCredential),
  StakingCredential (StakingPtr),
 )

main :: IO ()
main = do
  benchMain benchmarks

benchmarks :: [NamedBenchmark]
benchmarks =
  benchGroup
    "types"
    [ benchGroup "builtin:intlist" intListBench
    , benchGroup "data" dataBench
    , benchGroup "syn" syntaxBench
    ]

intListBench :: [[NamedBenchmark]]
intListBench =
  let numList = pconstant @(PBuiltinList PInteger) [1 .. 5]
   in [ benchGroup
          "primitives"
          [ bench' $ plam $ \_ -> pconstant True
          , bench' $ plam $ \_ -> (0 :: Term _ PInteger)
          , bench' $ plam $ \_ -> (1 :: Term _ PInteger)
          , bench' $ plam $ \_ -> (512 :: Term _ PInteger)
          , bench' $ plam $ \_ -> (1048576 :: Term _ PInteger)
          , bench' $ plam $ \_ -> pconstant ("1" :: ByteString)
          , bench' $ plam $ \_ -> pconstant ("1111111" :: ByteString)
          , bench' $ plam $ \_ -> pconstant ([()] :: [()])
          , bench' $ plam $ \_ -> pconstant ()
          , bench' $ pconstant ()
          , bench' $ plam $ \x -> x
          , bench' $ plam $ \_ -> (plam (+) :: Term _ (PInteger :--> PInteger :--> PInteger))
          , bench' $ (plam (+) :: Term _ (PInteger :--> PInteger :--> PInteger))
          ]
      ]

dataBench :: [[NamedBenchmark]]
dataBench =
  [ benchGroup "deconstruction" deconstrBench
  , benchGroup
      "pmatch-pfield"
      -- These two should ideally have the exact same efficiency.
      [ benchGroup
          "pmatch"
          [ bench "newtype" $ P.do
              let addr = pconstant $ Address (PubKeyCredential "ab") Nothing
              PAddress addrFields <- pmatch addr
              y <- pletFields @'["credential", "stakingCredential"] addrFields
              ppairDataBuiltin # hrecField @"credential" y # hrecField @"stakingCredential" y
          ]
      , benchGroup
          "pfield"
          [ bench "newtype" $ P.do
              let addr = pconstant $ Address (PubKeyCredential "ab") Nothing
              y <- pletFields @'["credential", "stakingCredential"] addr
              ppairDataBuiltin # hrecField @"credential" y # hrecField @"stakingCredential" y
          ]
      ]
  , benchGroup
      "pfield-pletFields"
      -- These two should ideally have the exact same efficiency.
      [ benchGroup
          "pfield"
          [ bench "single" $ P.do
              let addr = pconstant $ Address (PubKeyCredential "ab") Nothing
              pfromData $ pfield @"credential" # addr
          ]
      , benchGroup
          "pletFields"
          [ bench "single" $ P.do
              let addr = pconstant $ Address (PubKeyCredential "ab") Nothing
              y <- pletFields @'["credential"] addr
              pfromData $ hrecField @"credential" y
          ]
      ]
  ]

{- | For comparing typed and untyped data deconstruction approaches.

We ideally want the typed and raw versions to have as little deviation as possible.
-}
deconstrBench :: [[NamedBenchmark]]
deconstrBench =
  [ benchGroup
      "matching"
      $ [ benchGroup
            "typed"
            [ bench "newtype" $
                plam
                  ( \x -> P.do
                      PAddress addrFields <- pmatch x
                      addrFields
                  )
                  # pconstant addrPC
            , bench "sumtype(ignore-fields)" $
                plam
                  ( \x -> P.do
                      PMinting _ <- pmatch x
                      pconstant ()
                  )
                  # pconstant minting
            , bench "sumtype(partial-match)" $
                plam
                  ( \x -> P.do
                      PMinting hs <- pmatch x
                      hs
                  )
                  # pconstant minting
            , benchGroup "sumtype(exhaustive)" $
                benchPurpose $
                  plam
                    ( \x -> P.do
                        purp <- pmatch x
                        case purp of
                          PMinting f -> plet f $ const $ phexByteStr "01"
                          PSpending f -> plet f $ const $ phexByteStr "02"
                          PRewarding f -> plet f $ const $ phexByteStr "03"
                          PCertifying f -> plet f $ const $ phexByteStr "04"
                    )
            , benchGroup "sumtype(exhaustive)(ignore-fields)" $
                benchPurpose $
                  plam
                    ( \x -> P.do
                        purp <- pmatch x
                        case purp of
                          PMinting _ -> phexByteStr "01"
                          PSpending _ -> phexByteStr "02"
                          PRewarding _ -> phexByteStr "03"
                          PCertifying _ -> phexByteStr "04"
                    )
            ]
        , benchGroup
            "raw"
            [ bench "newtype" $
                plam
                  ( \x ->
                      psndBuiltin #$ pasConstr # x
                  )
                  #$ pconstant
                  $ toData addrPC
            , bench "sumtype(ignore-fields)" $
                plam
                  ( \x ->
                      pif
                        ((pfstBuiltin #$ pasConstr # x) #== 0)
                        (pconstant ())
                        perror
                  )
                  #$ pconstant
                  $ toData minting
            , bench "sumtype(partial-match)" $
                plam
                  ( \x ->
                      plet (pasConstr # x) $ \d ->
                        pif
                          (pfstBuiltin # d #== 0)
                          (psndBuiltin # d)
                          perror
                  )
                  #$ pconstant
                  $ toData minting
            , benchGroup "sumtype(exhaustive)" $
                benchPurpose' $
                  plam
                    ( \x -> P.do
                        d <- plet $ pasConstr # x
                        constr <- plet $ pfstBuiltin # d
                        _ <- plet $ psndBuiltin # d
                        pif
                          (constr #== 1)
                          (phexByteStr "02")
                          $ pif
                            (constr #== 2)
                            (phexByteStr "03")
                            $ pif
                              (constr #== 3)
                              (phexByteStr "04")
                              $ phexByteStr "01"
                    )
            , benchGroup "sumtype(exhaustive)(ignore-fields)" $
                benchPurpose' $
                  plam
                    ( \x -> P.do
                        constr <- plet $ pfstBuiltin #$ pasConstr # x
                        pif
                          (constr #== 1)
                          (phexByteStr "02")
                          $ pif
                            (constr #== 2)
                            (phexByteStr "03")
                            $ pif
                              (constr #== 3)
                              (phexByteStr "04")
                              $ phexByteStr "01"
                    )
            ]
        ]
  , benchGroup
      "fields"
      $ [ benchGroup
            "typed"
            [ bench "extract-single" $
                plam
                  ( \x ->
                      pfield @"credential" # x
                  )
                  # pconstant addrSC
            ]
        , benchGroup
            "raw"
            [ bench "extract-single" $
                plam
                  ( \x ->
                      phead #$ psndBuiltin #$ pasConstr # x
                  )
                  #$ pconstant
                  $ toData addrSC
            ]
        ]
  , benchGroup
      "combined"
      [ benchGroup
          "typed"
          [ bench "toValidatorHash" $
              plam
                ( \x -> P.do
                    cred <- pmatch . pfromData $ pfield @"credential" # x
                    case cred of
                      PPubKeyCredential _ -> pcon PNothing
                      PScriptCredential credFields -> pcon . PJust $ pto $ pfromData $ pfield @"_0" # credFields
                )
                # pconstant addrSC
          ]
      , benchGroup
          "raw"
          [ bench "toValidatorHash" $
              plam
                ( \x ->
                    P.do
                      let cred = phead #$ psndBuiltin #$ pasConstr # x
                      deconstrCred <- plet $ pasConstr # cred
                      pif
                        (pfstBuiltin # deconstrCred #== 0)
                        (pcon PNothing)
                        $ pcon . PJust $ pasByteStr #$ phead #$ psndBuiltin # deconstrCred
                )
                #$ pconstant
                $ toData addrSC
          ]
      ]
  ]
  where
    addrSC = Address (ScriptCredential "ab") Nothing
    addrPC = Address (PubKeyCredential "ab") Nothing
    minting = Minting ""
    spending = Spending (TxOutRef "ab" 0)
    rewarding = Rewarding (StakingPtr 42 0 7)
    certifying = Certifying DCertGenesis
    -- Bench given function feeding in all 4 types of script purpose (typed).
    benchPurpose :: ClosedTerm (PScriptPurpose :--> PByteString) -> [[NamedBenchmark]]
    benchPurpose f =
      [ bench "minting" $ f # pconstant minting
      , bench "spending" $ f # pconstant spending
      , bench "rewarding" $ f # pconstant rewarding
      , bench "certifying" $ f # pconstant certifying
      ]

    -- Bench given function feeding in all 4 types of script purpose (untyped).
    benchPurpose' :: ClosedTerm (PData :--> PByteString) -> [[NamedBenchmark]]
    benchPurpose' f =
      [ bench "minting" $ f #$ pconstant $ toData minting
      , bench "spending" $ f #$ pconstant $ toData spending
      , bench "rewarding" $ f #$ pconstant $ toData rewarding
      , bench "certifying" $ f #$ pconstant $ toData certifying
      ]

-- | Nested lambda, vs do-syntax vs cont monad.
syntaxBench :: [[NamedBenchmark]]
syntaxBench =
  let integerList :: [Integer] -> Term s (PList PInteger)
      integerList xs = List.pconvertLists #$ pconstant @(PBuiltinList PInteger) xs
      xs = integerList [1 .. 10]
   in [ benchGroup
          "ttail-pmatch"
          [ -- We expect all these benchmarks to produce equivalent numbers
            bench "nested" $ do
              pmatch xs $ \case
                PSCons _x xs' -> do
                  pmatch xs' $ \case
                    PSCons _ xs'' ->
                      xs''
                    PSNil -> perror
                PSNil -> perror
          , bench "do" $
              P.do
                PSCons _ xs' <- pmatch xs
                PSCons _ xs'' <- pmatch xs'
                xs''
          , bench "cont" $
              flip runCont id $ do
                ls <- cont $ pmatch xs
                case ls of
                  PSCons _ xs' -> do
                    ls' <- cont $ pmatch xs'
                    case ls' of
                      PSCons _ xs'' -> pure xs''
                      PSNil -> pure perror
                  PSNil -> pure perror
          , bench "termcont" $
              unTermCont $ do
                PSCons _ xs' <- TermCont $ pmatch xs
                PSCons _ xs'' <- TermCont $ pmatch xs'
                pure xs''
          ]
      ]
