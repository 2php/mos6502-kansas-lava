{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
module MOS6502.ALU where

import MOS6502.Types

import Language.KansasLava
import Data.Sized.Unsigned
import Data.Sized.Matrix
import Data.Bits

data ALUIn clk = ALUIn { aluInC :: Signal clk Bool
                       , aluInD :: Signal clk Bool
                       }

data ALUOut clk = ALUOut{ aluOutC :: Signal clk Bool
                        , aluOutZ :: Signal clk Bool
                        , aluOutN :: Signal clk Bool
                        , aluOutV :: Signal clk Bool
                        }

data BinOp = Or
           | And
           | XOr
           | Add
           | Sub
           | Copy
           deriving (Show, Eq, Enum, Bounded)
type BinOpSize = X6

instance Rep BinOp where
    type W BinOp = X3 -- W BinOpSize
    newtype X BinOp = XBinOp{ unXBinOp :: Maybe BinOp }

    unX = unXBinOp
    optX = XBinOp
    toRep s = toRep . optX $ s'
      where
        s' :: Maybe BinOpSize
        s' = fmap (fromIntegral . fromEnum) $ unX s
    fromRep rep = optX $ fmap (toEnum . fromIntegral . toInteger) $ unX x
      where
        x :: X BinOpSize
        x = sizedFromRepToIntegral rep

    repType _ = repType (Witness :: Witness BinOpSize)

data UnOp = Inc
          | Dec
          | ShiftL
          | ShiftR
          | RotateL
          | RotateR
          deriving (Show, Eq, Enum, Bounded)
type UnOpSize = X6

instance Rep UnOp where
    type W UnOp = X3 -- W UnOpSize
    newtype X UnOp = XUnOp{ unXUnOp :: Maybe UnOp }

    unX = unXUnOp
    optX = XUnOp
    toRep s = toRep . optX $ s'
      where
        s' :: Maybe UnOpSize
        s' = fmap (fromIntegral . fromEnum) $ unX s
    fromRep rep = optX $ fmap (toEnum . fromIntegral . toInteger) $ unX x
      where
        x :: X UnOpSize
        x = sizedFromRepToIntegral rep

    repType _ = repType (Witness :: Witness UnOpSize)

addExtend :: (Clock clk)
          => Signal clk Bool
          -> Signal clk Byte
          -> Signal clk Byte
          -> Signal clk U9
addExtend c x y = unsigned x + unsigned y + unsigned c

addCarry :: (Clock clk)
         => Signal clk Bool
         -> Signal clk Byte
         -> Signal clk Byte
         -> (Signal clk Bool, Signal clk Bool, Signal clk Byte)
addCarry c x y = (carry, overflow, unsigned z)
  where
    z = addExtend c x y
    carry = testABit z 8
    overflow = bitNot $ 0x80 .<=. z .&&. z .<. 0x180

subExtend :: (Clock clk)
          => Signal clk Bool
          -> Signal clk Byte
          -> Signal clk Byte
          -> Signal clk U9
subExtend c x y = unsigned x - unsigned y - unsigned (bitNot c)

subCarry :: (Clock clk)
         => Signal clk Bool
         -> Signal clk Byte
         -> Signal clk Byte
         -> (Signal clk Bool, Signal clk Bool, Signal clk Byte)
subCarry c x y = (carry, overflow, unsigned z)
  where
    z = subExtend c x y
    carry = testABit z 8
    overflow = -128 .<=. z .&&. z .<. 128

binaryALU :: forall clk. (Clock clk)
          => Signal clk BinOp
          -> ALUIn clk -> Signal clk Byte -> Signal clk Byte
          -> (ALUOut clk, Signal clk Byte)
binaryALU op ALUIn{..} arg1 arg2 = (ALUOut{..}, result)
  where
    (result, aluOutC, aluOutV) = unpack $ ops .!. bitwise op
    aluOutZ = result .==. 0
    aluOutN = result `testABit` 7

    ops :: Signal clk (Matrix BinOpSize (Byte, Bool, Bool))
    ops = pack $ matrix $ map pack $
          [ orS
          , andS
          , xorS
          , addS
          , subS
          , copyS
          ]

    logicS f = (z, low, low)
      where
        z = f arg1 arg2

    orS = logicS (.|.)
    andS = logicS (.&.)
    xorS = logicS xor
    addS = (z, c, v)
      where
        (c, v, z) = addCarry aluInC arg1 arg2
    subS = (z, c, v)
      where
        (c, v, z) = subCarry aluInC arg1 arg2
    copyS = logicS (\_x y -> y)

unaryALU :: forall clk. (Clock clk)
         => Signal clk UnOp
         -> ALUIn clk -> Signal clk Byte
         -> (ALUOut clk, Signal clk Byte)
unaryALU op ALUIn{..} arg1 = (ALUOut{..}, result)
  where
    (result, aluOutC) = unpack $ ops .!. bitwise op
    aluOutV = low
    aluOutZ = result .==. 0
    aluOutN = result `testABit` 7

    ops :: Signal clk (Matrix UnOpSize (Byte, Bool))
    ops = pack $ matrix $ map pack $
          [ incS
          , decS
          , shiftLS
          , shiftRS
          , rotateLS
          , rotateRS
          ]

    incS = (arg1 + 1, low)
    decS = (arg1 - 1, low)
    shiftLS = (arg1 `shiftL` 1, arg1 `testABit` 7)
    shiftRS = (arg1 `shiftR` 1, arg1 `testABit` 0)
    rotateLS = (arg1 `shiftL` 1 .|. unsigned aluInC, arg1 `testABit` 7)
    rotateRS = (arg1 `shiftR` 1 .|. unsigned aluInC `shiftL` 7, arg1 `testABit` 0)

cmp :: (Clock clk)
    => Signal clk Byte
    -> Signal clk Byte
    -> (Signal clk Bool, Signal clk Bool, Signal clk Bool)
cmp x y = (c, z, n)
  where
    c = x .>=. y
    z = x .==. y
    n = (x - y) `testABit` 7