module Dismantle.Tablegen (
  parseTablegen,
  filterISA,
  makeParseTables,
  module Dismantle.Tablegen.ISA,
  module Dismantle.Tablegen.Types
  ) where

import qualified GHC.Err.Located as L

import Control.Arrow ( (&&&) )
import Control.Monad ( guard )
import qualified Data.Array.Unboxed as UA
import Data.CaseInsensitive ( CI )
import qualified Data.CaseInsensitive as CI
import qualified Data.Foldable as F
import qualified Data.List.Split as L
import qualified Data.Map.Strict as M
import Data.Maybe ( mapMaybe )

import Dismantle.Tablegen.ISA
import Dismantle.Tablegen.Parser ( parseTablegen )
import Dismantle.Tablegen.Parser.Types
import Dismantle.Tablegen.Types
import qualified Dismantle.Tablegen.ByteTrie as BT

makeParseTables :: [InstructionDescriptor] -> Either BT.TrieError (BT.ByteTrie (Maybe InstructionDescriptor))
makeParseTables = BT.byteTrie Nothing . map (idMask &&& Just)

filterISA :: ISA -> Records -> [InstructionDescriptor]
filterISA isa = mapMaybe (instructionDescriptor isa) . tblDefs

toTrieBit :: Maybe BitRef -> BT.Bit
toTrieBit br =
  case br of
    Just (ExpectedBit b) -> BT.ExpectedBit b
    _ -> BT.Any

named :: String -> Named DeclItem -> Bool
named s n = namedName n == s

instructionDescriptor :: ISA -> Def -> Maybe InstructionDescriptor
instructionDescriptor isa def = do
  Named _ (FieldBits mbits) <- F.find (named "Inst") (defDecls def)
  Named _ (DagItem outs) <- F.find (named "OutOperandList") (defDecls def)
  Named _ (DagItem ins) <- F.find (named "InOperandList") (defDecls def)

  Named _ (StringItem ns) <- F.find (named "Namespace") (defDecls def)
  Named _ (StringItem decoder) <- F.find (named "DecoderNamespace") (defDecls def)
  Named _ (StringItem asmStr) <- F.find (named "AsmString") (defDecls def)
  Named _ (BitItem b) <- F.find (named "isPseudo") (defDecls def)
  let i = InstructionDescriptor { idMask = map toTrieBit mbits
                                , idMnemonic = defName def
                                , idNamespace = ns
                                , idDecoder = decoder
                                , idAsmString = asmStr
                                , idFields = fieldDescriptors isa (defName def) ins outs mbits
                                , idPseudo = b
                                }
  guard (isaInstructionFilter isa i)
  return i

fieldDescriptors :: ISA
                 -> String
                 -- ^ The instruction mnemonic
                 -> SimpleValue
                 -- ^ The "ins" DAG item (to let us identify instruction input types)
                 -> SimpleValue
                 -- ^ The "outs" DAG item (to let us identify instruction outputs)
                 -> [Maybe BitRef]
                 -- ^ The bits descriptor (so we can pick out fields)
                 -> [FieldDescriptor]
fieldDescriptors isa iname ins outs bits = map toFieldDescriptor (M.toList groups)
  where
    groups = foldr addBit M.empty (zip [0..] bits)
    inputFields = dagVarRefs iname "ins" ins
    outputFields = dagVarRefs iname "outs" outs

    addBit (bitNum, mbr) m =
      case mbr of
        Just (FieldBit fldName fldIdx) ->
          M.insertWith (++) fldName [(bitNum, fldIdx)] m
        _ -> m

    toFieldDescriptor :: (String, [(Int, Int)]) -> FieldDescriptor
    toFieldDescriptor (fldName, bitPositions) =
      let arrVals = [ (fldIdx, fromIntegral bitNum)
                    | (bitNum, fldIdx) <- bitPositions
                    ]
          (ty, dir) = fieldMetadata isa inputFields outputFields fldName
          fldRange = findFieldBitRange bitPositions
      in FieldDescriptor { fieldName = fldName
                         , fieldDirection = dir
                         , fieldType = ty
                         , fieldBits = UA.array fldRange arrVals
                         }

-- | Find the actual length of a field.
--
-- The bit positions tell us which bits are encoded in the
-- instruction, but some values have implicit bits that are not
-- actually in the instruction.
findFieldBitRange :: [(Int, Int)] -> (Int, Int)
findFieldBitRange bitPositions = (minimum (map snd bitPositions), maximum (map snd bitPositions))

fieldMetadata :: ISA -> M.Map (CI String) String -> M.Map (CI String) String -> String -> (FieldType, RegisterDirection)
fieldMetadata isa ins outs name =
  let cin = CI.mk name
  in case (M.lookup cin ins, M.lookup cin outs) of
    (Just kIn, Just kOut)
      | kIn == kOut -> (isaFieldType isa kIn, Both)
      | otherwise -> L.error ("Field type mismatch for in vs. out: " ++ show name)
    (Just kIn, Nothing) -> (isaFieldType isa kIn, In)
    (Nothing, Just kOut) -> (isaFieldType isa kOut, Out)
    -- FIXME: This might or might not be true.. need to look at more
    -- cases
    (Nothing, Nothing) -> (Immediate, In) -- L.error ("No field type for " ++ name)

dagVarRefs :: String
           -> String
           -- ^ The Dag head operator (e.g., "ins" or "outs")
           -> SimpleValue
           -> M.Map (CI String) String
dagVarRefs iname expectedOperator v =
  case v of
    VDag (DagArg (Identifier hd) _) args
      | hd == expectedOperator -> foldr argVarName M.empty args
    _ -> L.error ("Unexpected SimpleValue while looking for dag head " ++ expectedOperator ++ ": " ++ show v)
  where
    argVarName a m =
      case a of
        DagArg (Identifier i) _
          | [klass,var] <- L.splitOn ":" i -> M.insert (CI.mk var) klass m
          | i == "variable_ops" -> m -- See Note [variable_ops]
        _ -> L.error ("Unexpected variable reference in a DAG for " ++ iname ++ ": " ++ show a)

{- Note [variable_ops]

Sparc has a call instruction (at least) that lists "variable_ops" as
input operands.  This virtual operand doesn't have a type annotation,
so fails our first condition that tries to find the type.  We don't
need to make an entry for it because no operand actually goes by that
name.

-}
