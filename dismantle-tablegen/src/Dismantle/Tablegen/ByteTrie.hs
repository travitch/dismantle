{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MagicHash #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TypeFamilies #-}

module Dismantle.Tablegen.ByteTrie (
  ByteTrie(..),
  byteTrie,
  lookupByte,
  Bit(..),
  -- * Errors
  TrieError(..),
  -- * Unsafe
  unsafeFromAddr,
  unsafeByteTrieParseTableBytes,
  unsafeByteTriePayloads
  ) where
import           Debug.Trace

import qualified GHC.Prim as P
import qualified GHC.Ptr as Ptr
import qualified GHC.ForeignPtr as FP

import           Control.Applicative
import           Control.DeepSeq
import qualified Control.Monad.Except as E
import           Control.Monad.Fail
import qualified Control.Monad.State.Strict as St
import qualified Data.Binary.Put as P
import           Data.Bits ( Bits, (.&.), (.|.), popCount, bit )
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as LBS
import           Data.Coerce ( coerce )
import qualified Data.Foldable as F
import qualified Data.HashMap.Strict as HM
import qualified Data.Hashable as DH
import           Data.Int ( Int32 )
import qualified Data.List as L
import qualified Data.Map.Strict as M
import           Data.Maybe (catMaybes)
import qualified Data.Traversable as T
import qualified Data.Vector as V
import qualified Data.Vector.Generic as VG
import qualified Data.Vector.Generic.Mutable as VGM
import qualified Data.Vector.Storable as SV
import qualified Data.Vector.Unboxed as VU
import qualified Data.Vector.Unboxed.Mutable as VUM
import           Data.Word ( Word8 )
import qualified System.IO.Unsafe as IO

import           Prelude

-- | A data type mapping sequences of bytes to elements of type @a@
data ByteTrie a =
  ByteTrie { btPayloads :: V.Vector a
           -- ^ Payloads of the parser; looking up a byte sequence in the trie
           -- will yield an element in this vector.
           --
           -- Note that the element at index 0 is undefined and unused, as the
           -- indices into the payloads table from the parse tables start at 1
           -- (since those values are stored as negatives).  The item at index 1
           -- is the "default" element returned when nothing else matches.
           , btParseTables :: SV.Vector Int32
           -- ^ The parse tables are linearized into an array of Int32.  To look
           -- up a byte, add the byte to the 'btStartIndex' and use the result
           -- to index into 'btParseTables'.  If the result negative, it is a
           -- (negated) index into 'btPayloads'.  Otherwise, it is the next
           -- 'btStartIndex' to use.
           , btStartIndex :: {-# UNPACK #-} !Int
           -- ^ The table index to start traversing from.
           }

-- | A bit with either an expected value ('ExpectedBit') or an
-- unconstrained value ('Any')
data Bit = ExpectedBit !Bool
         | Any
         deriving (Eq, Ord, Show)

instance NFData Bit where
  rnf _ = ()

-- | A wrapper around a sequence of 'Bit's
data Pattern = Pattern { requiredMask :: BS.ByteString
                       -- ^ The mask of bits that must be set in order for the
                       -- pattern to match
                       , trueMask :: BS.ByteString
                       -- ^ The bits that must be set (or not) in the positions
                       -- selected by the 'requiredMask'
                       , negativePairs :: [(BS.ByteString, BS.ByteString)]
                       -- ^ a list of "negative" masks, where the lefthand side of
                       -- each pair is the mask of bits that must /not/ match for
                       -- this pattern to apply, and the righthand side is the bits
                       -- that must be set (or not) in the positions selected by the
                       -- lefthand side in order to reject the pattern
                       }
               deriving (Eq, Ord, Show)

instance DH.Hashable Pattern where
  hashWithSalt slt p = slt `DH.hashWithSalt` requiredMask p
                           `DH.hashWithSalt` trueMask p
                           `DH.hashWithSalt` negativePairs p

showPattern :: Pattern -> String
showPattern Pattern{..} =
  "Pattern { requiredMask = " ++ show (BS.unpack requiredMask) ++
  ", trueMask = " ++ show (BS.unpack trueMask) ++
  "}"

-- | Return the number of bytes occupied by a 'Pattern'
patternBytes :: Pattern -> Int
patternBytes = BS.length . requiredMask

-- | Look up a byte in the trie.
--
-- The result could either be a terminal element or another trie that
-- must be fed another byte to continue the lookup process.
--
-- There is no explicit return value for invalid encodings.  The trie
-- is constructed such that no invalid encodings are possible (i.e.,
-- the constructor is required to explicitly represent those cases
-- itself).
lookupByte :: ByteTrie a -> Word8 -> Either (ByteTrie a) a
lookupByte bt byte
  | tableVal < 0 = Right (btPayloads bt `V.unsafeIndex` fromIntegral (negate tableVal))
  | otherwise = Left $ bt { btStartIndex = fromIntegral tableVal }
  where
    tableVal = btParseTables bt `SV.unsafeIndex` (fromIntegral byte + btStartIndex bt)

data TrieError = OverlappingBitPattern [(Pattern, [String], Int)]
               | OverlappingBitPatternAt Int [Word8] [(Pattern, [String], Int)]
               -- ^ Byte index, byte, patterns
               | InvalidPatternLength Pattern
               | MonadFailErr String
  deriving (Eq)

instance Show TrieError where
  show err = case err of
    OverlappingBitPattern patList -> "OverlappingBitPattern " ++ showPatList patList
    OverlappingBitPatternAt ix bytes patList ->
      "OverlappingBitPatternAt index:" ++ show ix ++
      " bytesSoFar: " ++ show bytes ++
      " matching patterns: " ++ showPatList patList
    InvalidPatternLength p -> "InvalidPatternLength " ++ showPattern p
    MonadFailErr str -> "MonadFailErr " ++ show str
    where showPat (p, mnemonics, numBytes) = "(" ++ showPattern p ++ ", " ++ show mnemonics ++ ", " ++ show numBytes ++ ")"
          showPatList pats = "[" ++ L.intercalate "," (showPat <$> pats) ++ "]"

newtype PatternSet = PatternSet { patternSetBits :: Integer }
  deriving (Eq, Ord, Show, DH.Hashable, Bits)

-- | The state of the 'TrieM' monad
data TrieState e = TrieState { tsPatterns :: !(M.Map Pattern (LinkedTableIndex, e))
                             -- ^ The 'Int' is the index of the element into the
                             -- 'btPayloads' vector; these are allocated
                             -- up-front so that we don't need to maintain a
                             -- backwards mapping from e -> Int (which would put
                             -- an unfortunate 'Ord' constraint on e).
                             , tsPatternMnemonics :: !(M.Map Pattern String)
                             -- ^ A mapping of patterns to their menmonics
                             , tsPatternSets :: !(HM.HashMap Pattern PatternSet)
                             -- ^ Record the singleton 'PatternSet' for each
                             -- pattern; when constructing the key for
                             -- 'tsCache', all of these will be looked up and
                             -- ORed together to construct the actual set.
                             , tsCache :: !(HM.HashMap (Int, PatternSet) LinkedTableIndex)
                             -- ^ A map of trie levels to tries to allow for
                             -- sharing of common sub-trees.  The 'Int' is an
                             -- index into 'tsTables'
                             , tsTables :: !(M.Map LinkedTableIndex (VU.Vector LinkedTableIndex))
                             -- ^ The actual tables, which point to either other
                             -- tables or terminal elements in the 'tsPatterns'
                             -- table.
                             , tsEltIdSrc :: LinkedTableIndex
                             -- ^ The next element ID to use
                             , tsTblIdSrc :: LinkedTableIndex
                             -- ^ The next table ID to use
                             }

newtype TrieM e a = TrieM { unM :: St.StateT (TrieState e) (E.Except TrieError) a }
  deriving (Functor,
            Applicative,
            Monad,
            E.MonadError TrieError,
            St.MonadState (TrieState e))

instance MonadFail (TrieM e) where
    fail msg = E.throwError $ MonadFailErr msg


-- | Construct a 'ByteTrie' from a list of mappings and a default element
byteTrie :: e -> [(String, BS.ByteString, BS.ByteString, [(BS.ByteString, BS.ByteString)], e)] -> Either TrieError (ByteTrie e)
byteTrie defElt mappings = mkTrie defElt (mapM_ (\(n, r, t, nps, e) -> assertMapping n r t nps e) mappings)
  where _showMapping (s, bs0, bs1, bs2, bs3, _) = show (s, BS.unpack bs0, BS.unpack bs1, BS.unpack bs2, BS.unpack bs3)

-- | Construct a 'ByteTrie' through a monadic assertion-oriented interface.
--
-- Any bit pattern not covered by an explicit assertion will default
-- to the undefined parse value.
mkTrie :: e
       -- ^ The value of an undefined parse
       -> TrieM e ()
       -- ^ The assertions composing the trie
       -> Either TrieError (ByteTrie e)
mkTrie defElt act =
  E.runExcept (St.evalStateT (unM (act >> trieFromState defElt)) s0)
  where
    s0 = TrieState { tsPatterns = M.empty
                   , tsCache = HM.empty
                   , tsPatternMnemonics = M.empty
                   , tsPatternSets = HM.empty
                   , tsTables = M.empty
                   , tsEltIdSrc = firstElementIndex
                   , tsTblIdSrc = firstTableIndex
                   }

trieFromState :: e -> TrieM e (ByteTrie e)
trieFromState defElt = do
  pats <- St.gets tsPatterns
  t0 <- buildTableLevel pats 0 BS.empty
  st <- St.get
  return (flattenTables t0 defElt st)

-- | Flatten the maps of parse tables that reference each other into a single
-- large array with indices into itself (positive indices) and the payloads
-- table (negative indices).
--
-- The 'LinkedTableIndex' parameter is the index of the table to start from.
-- Note that it almost certainly *won't* be zero, as table IDs are allocated
-- depth-first.
flattenTables :: LinkedTableIndex -> e -> TrieState e -> ByteTrie e
flattenTables t0 defElt st =
  ByteTrie { btStartIndex = ix0
           , btPayloads = V.fromList (undefined : defElt : sortedElts)
           , btParseTables = SV.fromList parseTables
           }
  where
    ix0 = fromIntegral (unFTI (linkedToFlatIndex t0))
    -- We have to reverse the elements because their IDs are negated
    sortedElts = [ e | (_ix, e) <- reverse (L.sortOn fst (M.elems (tsPatterns st))) ]
    -- The table index doesn't really matter - it is just important to keep the
    -- tables in relative order
    parseTables = [ unFTI (linkedToFlatIndex e)
                  | (_tblIx, tbl) <- L.sortOn fst (M.toList (tsTables st))
                  , e <- VU.toList tbl
                  ]

-- | Builds a table for a given byte in the sequence (or looks up a matching
-- table in the 'tsCache')
buildTableLevel :: M.Map Pattern (LinkedTableIndex, e)
                -- ^ Remaining valid patterns
                -> Int
                -- ^ Byte index we are computing
                -> BS.ByteString
                -- ^ string of bytes we have followed thus far
                -> TrieM e LinkedTableIndex
buildTableLevel patterns byteIndex bytesSoFar = do
  cache <- St.gets tsCache
  psets <- St.gets tsPatternSets
  let addPatternToSet ps p =
        case HM.lookup p psets of
          Nothing -> error ("Missing pattern set for pattern: " ++ show p)
          Just s -> s .|. ps
  let pset = F.foldl' addPatternToSet (PatternSet 0) (M.keys patterns)
  let key = (byteIndex, pset)
  case HM.lookup key cache of
    Just tix -> return tix
    Nothing -> do
      payloads <- T.traverse (makePayload patterns byteIndex bytesSoFar) byteValues
      tix <- newTable payloads
      St.modify' $ \s -> s { tsCache = HM.insert key tix (tsCache s) }
      return tix
  where
    maxWord :: Word8
    maxWord = maxBound
    byteValues = [0 .. maxWord]

-- | Allocate a new chunk of the table with the given payload
--
-- The table is assigned a unique ID and added to the table list
newTable :: [(Word8, LinkedTableIndex)] -> TrieM e LinkedTableIndex
newTable payloads = do
  tix <- St.gets tsTblIdSrc
  let a = VU.fromList (fmap snd (L.sortOn fst payloads))
  St.modify' $ \s -> s { tsTables = M.insert tix a (tsTables s)
                       , tsTblIdSrc = nextTableIndex tix
                       }
  return tix

makePayload :: M.Map Pattern (LinkedTableIndex, e)
            -- ^ Valid patterns at this point in the trie
            -> Int
            -- ^ Byte index we are computing
            -> BS.ByteString
            -- ^ bytes we have used to traverse thus far
            -> Word8
            -- ^ The byte we are matching patterns against
            -> TrieM e (Word8, LinkedTableIndex)
makePayload patterns byteIndex bytesSoFar byte =
  case M.toList matchingPatterns of
    [] -> return (byte, defaultElementIndex)
    [(_, (eltIdx, _elt))] -> return (byte, eltIdx)
    _ | all ((> (byteIndex + 1)) . patternBytes) (M.keys matchingPatterns) -> do
          -- If there are more bytes available in the overlapping patterns, extend
          -- the trie to inspect one more byte
          {-

            Instead of this, we should probably choose the pattern that has the
            most required bits in the *current byte*.  We know that the pattern
            already matches due to the computation of 'matchingPatterns'.  If
            there are an equal number of matching bits in the current byte,
            *then* extend the trie to the next level.

          -}
          tix <- buildTableLevel matchingPatterns (byteIndex + 1) bytesSoFar'
          return (byte, tix)
      | M.null negativeMatchingPatterns -> return (byte, defaultElementIndex)
      | Just (mostSpecificEltIdx, _) <- findMostSpecificPatternElt negativeMatchingPatterns -> do
          -- If there are no more bytes *and* one of the patterns is more specific
          -- than all of the others, take the most specific pattern
          return (byte, mostSpecificEltIdx)
      | otherwise -> do
          -- Otherwise, the patterns overlap and we have no way to
          -- choose a winner, so fail
          mapping <- St.gets tsPatternMnemonics

          let pats = map fst (M.toList negativeMatchingPatterns)
              mnemonics = catMaybes $ (flip M.lookup mapping) <$> pats

          traceM $ show (patternBytes <$> M.keys negativeMatchingPatterns)

          E.throwError (OverlappingBitPatternAt byteIndex (BS.unpack bytesSoFar') $ zip3 pats ((:[]) <$> mnemonics) (patternBytes <$> pats))
  where
    bytesSoFar' = BS.snoc bytesSoFar byte
    -- First, filter out the patterns that don't match the current byte at the given
    -- byte index.
    matchingPatterns' = M.filterWithKey (patternMatches byteIndex byte) patterns
    -- FIXME: Next, reduce the matching patterns to only those with shortest
    -- length. This should probably be done at the top level rather than here.
    matchLength = minimum (patternBytes <$> M.keys matchingPatterns')
    matchingPatterns = M.filterWithKey (\p _ -> patternBytes p == matchLength) matchingPatterns'

    -- This should only be used to disambiguate when we no longer have any bytes left.
    negativeMatchingPatterns = M.filterWithKey (negativePatternMatches bytesSoFar') matchingPatterns

-- | Return the element associated with the most specific pattern in the given
-- collection, if any.
--
-- A pattern is the most specific if its required bits are a strict superset of
-- the required bits of the other patterns in the initial collection.
--
-- The required invariant for this function is that all of the patterns in the
-- collection are actually congruent (i.e., *could* have all of their bits
-- matching).
findMostSpecificPatternElt :: M.Map Pattern (LinkedTableIndex, e) -> Maybe (LinkedTableIndex, e)
findMostSpecificPatternElt = findMostSpecific [] . M.toList
  where
    findMostSpecific checked pats =
      case pats of
        [] -> Nothing
        e@(pat, elt) : rest
          | checkPatterns pat checked rest -> Just elt
          | otherwise -> findMostSpecific (e:checked) rest
    -- Return 'True' if the pattern @p@ is more specific than all of the
    -- patterns in @checked@ and @rest@.
    checkPatterns p checked rest =
      all (isMoreSpecific p) checked && all (isMoreSpecific p) rest
    -- Return 'True' if @target@ is more specific than @p@.
    isMoreSpecific target (p, _) = requiredBitCount target > requiredBitCount p
    requiredBitCount bs = sum [ popCount w
                              | w <- BS.unpack (requiredMask bs)
                              ]

-- | Return 'True' if the 'Pattern' *could* match the given byte at the 'Int' byte index
patternMatches :: Int -> Word8 -> Pattern -> e -> Bool
patternMatches byteIndex byte p _ = -- (Pattern { requiredMask = req, trueMask = true }) _ =
  (byte .&. patRequireByte) == patTrueByte
  where
    patRequireByte = requiredMask p `BS.index` byteIndex
    patTrueByte = trueMask p `BS.index` byteIndex

-- | Return 'True' if a 'BS.ByteString' does not match with any of the negative bit
-- masks in a pattern.
-- FIXME: We do not check that the bytestrings have the same length
negativePatternMatches :: BS.ByteString -> Pattern -> e -> Bool
negativePatternMatches bs p _ = all (uncurry (negativeMatch bs)) (negativePairs p)
  where negativeMatch bs' negMask negBits =
          case (all (==0) (BS.unpack negMask)) of
            True -> True
            False -> not (and (zipWith3 negativeByteMatches (BS.unpack negMask) (BS.unpack negBits) (BS.unpack bs')))
        negativeByteMatches :: Word8 -> Word8 -> Word8 -> Bool
        negativeByteMatches negByteMask negByteBits byte = (byte .&. negByteMask) == negByteBits

-- | Assert a mapping from a bit pattern to a value.
--
-- The bit pattern must have a length that is a multiple of 8.  This
-- function can error out with a pure error ('TrieError') if an
-- overlapping bit pattern is asserted.
assertMapping :: String -> BS.ByteString -> BS.ByteString -> [(BS.ByteString, BS.ByteString)] -> a -> TrieM a ()
assertMapping mnemonic patReq patTrue patNegPairs val
  | BS.length patReq /= BS.length patTrue || BS.null patReq =
    E.throwError (InvalidPatternLength pat)
  | otherwise = do
      pats <- St.gets tsPatterns
      case M.lookup pat pats of
        Just _ -> do
            -- Get the mnemonic already mapped to this pattern
            mnemonics <- St.gets tsPatternMnemonics
            case M.lookup pat mnemonics of
              Just oldMnemonic -> E.throwError (OverlappingBitPattern [(pat, [mnemonic, oldMnemonic], patternBytes pat)])
              Nothing -> E.throwError (OverlappingBitPattern [(pat, [mnemonic], patternBytes pat)])
        Nothing -> do
          eid <- St.gets tsEltIdSrc
          patIdNum <- St.gets (M.size . tsPatterns)
          let patSet = PatternSet { patternSetBits = bit patIdNum }
          St.modify' $ \s -> s { tsPatterns = M.insert pat (eid, val) (tsPatterns s)
                               , tsPatternSets = HM.insert pat patSet (tsPatternSets s)
                               , tsPatternMnemonics = M.insert pat mnemonic (tsPatternMnemonics s)
                               , tsEltIdSrc = nextElementIndex eid
                               }
  where
    pat = Pattern patReq patTrue patNegPairs

-- Unsafe things

-- | This constructor is designed for use in Template Haskell-generated code so
-- that the parsing tables can be encoded as an 'Addr#' and turned into a
-- 'ByteTrie' in constant time.
--
-- It is suggested that this is only used with values generated from a
-- safely-constructed 'ByteTrie'
unsafeFromAddr :: [a]
               -- ^ The payloads of the 'ByteTrie'.  Note that this list only
               -- contains the *defined* values.  There is an implicit undefined
               -- value stored at index 0.
               -> P.Addr#
               -- ^ The linearized parsing tables (probably stored in the read-only data section)
               -> Int
               -- ^ The number of 'Int32' entries in the parsing tables
               -> Int
               -- ^ The index to start parsing with
               -> ByteTrie a
unsafeFromAddr payloads addr nElts ix0 = IO.unsafePerformIO $ do
  fp <- FP.newForeignPtr_ (Ptr.Ptr addr)
  return $! ByteTrie { btPayloads = V.fromList (undefined : payloads)
                     , btParseTables = SV.unsafeFromForeignPtr0 fp nElts
                     , btStartIndex = ix0
                     }
{-# NOINLINE unsafeFromAddr #-}

-- | Extract the parse tables of a 'ByteTrie' as a list of 'Word8' values
-- suitable for embedding in TH as an 'Addr#'
--
-- The first 'Int' is the number of 'Int32' entries in the table.
--
-- The second 'Int' is the starting index (i.e., the index to start using the
-- parse tables from)
unsafeByteTrieParseTableBytes :: ByteTrie a -> ([Word8], Int, Int)
unsafeByteTrieParseTableBytes bt =
  (LBS.unpack (P.runPut (SV.mapM_ P.putInt32host tbls)), SV.length tbls, btStartIndex bt)
  where
    tbls = btParseTables bt

-- | Extract the payloads from a 'ByteTrie'
--
-- The list will only contain the values in the real payloads table starting at
-- index 1, as index 0 is undefined and unused.
unsafeByteTriePayloads :: ByteTrie a -> [a]
unsafeByteTriePayloads bt =
  case V.null (btPayloads bt) of
    True -> []
    False -> tail (V.toList (btPayloads bt))

-- Internal helper types

newtype instance VU.Vector LinkedTableIndex = V_FTI (VU.Vector Int32)
newtype instance VUM.MVector s LinkedTableIndex = MV_FTI (VUM.MVector s Int32)

instance VGM.MVector VUM.MVector LinkedTableIndex where
  basicLength (MV_FTI mv) = VGM.basicLength mv
  basicUnsafeSlice i l (MV_FTI mv) = MV_FTI (VGM.basicUnsafeSlice i l mv)
  basicOverlaps (MV_FTI mv) (MV_FTI mv') = VGM.basicOverlaps mv mv'
  basicUnsafeNew l = MV_FTI <$> VGM.basicUnsafeNew l
  basicInitialize (MV_FTI mv) = VGM.basicInitialize mv
  basicUnsafeReplicate i x = MV_FTI <$> VGM.basicUnsafeReplicate i (coerce x)
  basicUnsafeRead (MV_FTI mv) i = coerce <$> VGM.basicUnsafeRead mv i
  basicUnsafeWrite (MV_FTI mv) i x = VGM.basicUnsafeWrite mv i (coerce x)
  basicClear (MV_FTI mv) = VGM.basicClear mv
  basicSet (MV_FTI mv) x = VGM.basicSet mv (coerce x)
  basicUnsafeCopy (MV_FTI mv) (MV_FTI mv') = VGM.basicUnsafeCopy mv mv'
  basicUnsafeMove (MV_FTI mv) (MV_FTI mv') = VGM.basicUnsafeMove mv mv'
  basicUnsafeGrow (MV_FTI mv) n = MV_FTI <$> VGM.basicUnsafeGrow mv n

instance VG.Vector VU.Vector LinkedTableIndex where
  basicUnsafeFreeze (MV_FTI mv) = V_FTI <$> VG.basicUnsafeFreeze mv
  basicUnsafeThaw (V_FTI v) = MV_FTI <$> VG.basicUnsafeThaw v
  basicLength (V_FTI v) = VG.basicLength v
  basicUnsafeSlice i l (V_FTI v) = V_FTI (VG.basicUnsafeSlice i l v)
  basicUnsafeIndexM (V_FTI v) i = coerce <$> VG.basicUnsafeIndexM v i
  basicUnsafeCopy (MV_FTI mv) (V_FTI v) = VG.basicUnsafeCopy mv v
  elemseq (V_FTI v) x y = VG.elemseq v (coerce x) y

-- | This type represents the payload of the initial linked parse tables (in the
-- state of the monad).
--
-- In this representation, negative values name a payload in 'tsPatterns', while
-- non-negative values are table identifiers in 'tsTables'.
newtype LinkedTableIndex = LTI Int32
  deriving (Eq, Ord, Show, VU.Unbox)

-- | This type represents payloads in the 'ByteTrie' type.
--
-- Again, negative values are indices into 'btPayloads'.  Other values are
-- indices into 'btParseTables'.
newtype FlatTableIndex = FTI { unFTI :: Int32 }
  deriving (Eq, Ord, Show)


-- | Convert between table index types.
--
-- The conversion assumes that tables will be laid out in order.  Each table is
-- 256 entries, so that is the conversion factor between table number and index
-- into the 'btParseTables' array.
linkedToFlatIndex :: LinkedTableIndex -> FlatTableIndex
linkedToFlatIndex (LTI i)
  | i < 0 = FTI i
  | otherwise = FTI (i * 256)

defaultElementIndex :: LinkedTableIndex
defaultElementIndex = LTI (-1)

-- | The element indexes start at -2 since the default is reserved for -1
firstElementIndex :: LinkedTableIndex
firstElementIndex = LTI (-2)

firstTableIndex :: LinkedTableIndex
firstTableIndex = LTI 0

nextTableIndex :: LinkedTableIndex -> LinkedTableIndex
nextTableIndex (LTI i) = LTI (i + 1)

nextElementIndex :: LinkedTableIndex -> LinkedTableIndex
nextElementIndex (LTI i) = LTI (i - 1)


{- Note [Trie Structure]

The 'ByteTrie' maps sequences of bytes to payloads of type 'a'.

The 'ByteTrie' is conceptually a DAG of parsing tables linked together, where
each table is 256 elements and intended to be indexed by a byte.  Each lookup
either yields a payload or another parse table (which requires more bytes to
yield a payload).

The actual implementation of the 'ByteTrie' flattens the DAG structure of the
tables into two arrays: an array with indexes into itself ('btParseTables') and
a separate array of payload values ('btPayloads').  A negative value in
'btParseTables' indicates that the value should be negated and used as an index
into 'btPayloads'.  A non-negative value is an index into 'btParseTables'.

When asserting mappings into the trie, we assign a unique numeric identifier to
each payload.  This lets us reference payloads without putting Ord or Hashable
constraints on them.

To construct the trie, pass in the list of all possible patterns and
the byte index to compute (i.e., start with 0).

Enumerate the values of the byte, for each value filtering down a list
of possibly-matching patterns.

* If there are multiple patterns and bits remaining, generate a
  'NextTable' reference and recursively build that table by passing
  the remaining patterns and byte index + 1 to the procedure.  If
  there is overlap, *all* of the patterns must have bytes remaining.

* If there are multiple patterns and no bits remaining in them, raise
  an overlapping pattern error

* If there is a single pattern left, generate an 'Element' node

* If there are no patterns, generate an 'Element' node with the default element

-}
