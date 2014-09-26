{-# LANGUAGE ScopedTypeVariables, TypeFamilies #-}
{-# LANGUAGE RecordWildCards #-}
module MOS6502.CPU where

import MOS6502.Types
import MOS6502.Utils

import Language.KansasLava
import Data.Sized.Ix
import Data.Bits

data CPUIn clk = CPUIn
    { cpuMemR :: Signal clk Byte
    -- , cpuDBE :: Signal clk Bool
    -- , cpuRDY :: Signal clk Bool
    , cpuIRQ :: Signal clk ActiveLow
    , cpuNMI :: Signal clk ActiveLow
    -- , cpuSO :: Signal clk ActiveLow
    , cpuWait :: Signal clk Bool -- XXX KLUDGE
    }

data CPUOut clk = CPUOut
    { cpuMemA :: Signal clk Addr
    , cpuMemW :: Signal clk (Enabled Byte)
    -- , cpuSync :: Signal clk Bool
    }

data CPUDebug clk = CPUDebug
    { cpuState :: Signal clk State
    , cpuArgLo :: Signal clk Byte
    , cpuA :: Signal clk Byte
    , cpuX :: Signal clk Byte
    , cpuY :: Signal clk Byte
    , cpuP :: Signal clk Byte
    , cpuSP :: Signal clk Byte
    , cpuPC :: Signal clk Addr
    , cpuOp :: Signal clk Opcode
    }

data State = Init
           | FetchVector1
           | FetchVector2
           | Fetch1
           | Fetch2
           | Fetch3
           | WaitMem
           | Halt
           deriving (Show, Eq, Enum, Bounded)
type StateSize = X8

instance Rep State where
    type W State = X3 -- W StateSize
    newtype X State = XState{ unXState :: Maybe State }

    unX = unXState
    optX = XState
    toRep s = toRep . optX $ s'
      where
        s' :: Maybe StateSize
        s' = fmap (fromIntegral . fromEnum) $ unX s
    fromRep rep = optX $ fmap (toEnum . fromIntegral . toInteger) $ unX x
      where
        x :: X StateSize
        x = sizedFromRepToIntegral rep

    repType _ = repType (Witness :: Witness StateSize)

data Opcode = LDA_Imm
            | STA_Abs
            | STA_Abs_X
            | INX
            | LDX_Imm
            | JMP_Abs
            | BRK
            deriving (Eq, Bounded, Enum)

instance Rep Opcode where
    type W Opcode = X8
    newtype X Opcode = XOpcode{ unXOpcode :: Maybe Opcode }

    unX = unXOpcode
    optX = XOpcode

    toRep = toRep . optX . fmap encode . unX
      where
        encode :: Opcode -> Byte
        encode LDA_Imm = 0xA9
        encode STA_Abs = 0x8D
        encode STA_Abs_X = 0x9D
        encode INX = 0xE8
        encode LDX_Imm = 0xA2
        encode JMP_Abs = 0x4C
        encode BRK = 0x00

    fromRep = optX . fmap decode . unX . sizedFromRepToIntegral
      where
        decode :: Byte -> Opcode
        decode 0xA9 = LDA_Imm
        decode 0x8D = STA_Abs
        decode 0x9D = STA_Abs_X
        decode 0xE8 = INX
        decode 0xA2 = LDX_Imm
        decode 0x4C = JMP_Abs
        decode _ = BRK

    repType _ = repType (Witness :: Witness Byte)

data Microcode s clk = Opcode0 (RTL s clk ())
                     | Opcode1 (Signal clk Byte -> (RTL s clk ()))
                     | Opcode2 (Signal clk Addr -> (RTL s clk ()))
                     | Jam

cpu :: forall clk. (Clock clk) => CPUIn clk -> (CPUOut clk, CPUDebug clk)
cpu CPUIn{..} = runRTL $ do
    -- State
    s <- newReg Init
    rOp <- newReg BRK
    rArgLo <- newReg 0x00

    -- Registers
    rA <- newReg 0x00
    rX <- newReg 0x00
    rY <- newReg 0x00
    rSP <- newReg 0x00
    rP <- newReg 0x00
    rPC <- newReg 0x0000 -- To be filled in by Init

    rNextA <- newReg 0x0000
    rNextW <- newReg Nothing

    let write addr val = do
            rNextA := addr
            rNextW := enabledS val
            s := pureS WaitMem

    let op LDA_Imm = Opcode1 $ \imm -> do
            rA := imm
        op STA_Abs = Opcode2 $ \addr -> do
            write addr (reg rA)
        op STA_Abs_X = Opcode2 $ \addr -> do
            let addr' = addr + unsigned (reg rX)
            write addr' (reg rA)
        op LDX_Imm = Opcode1 $ \imm -> do
            rX := imm
        op INX = Opcode0 $ do
            rX := reg rX + 1
        op JMP_Abs = Opcode2 $ \addr -> do
            rPC := addr

        op _ = Jam

    WHEN (bitNot cpuWait) $
      switch (reg s) $ \state -> case state of
          Init -> do
              rNextA := pureS resetVector
              s := pureS FetchVector1
          FetchVector1 -> do
              rPC := unsigned cpuMemR
              rNextA := reg rNextA + 1
              s := pureS FetchVector2
          FetchVector2 -> do
              rPC := (reg rPC .&. 0xFF) .|. (unsigned cpuMemR `shiftL` 8)
              rNextA := var rPC
              s := pureS Fetch1
          Fetch1 -> do
              rOp := bitwise cpuMemR
              switch (var rOp) $ \k -> case op k of
                  Jam -> do
                      s := pureS Halt
                  Opcode0 act -> do
                      act
                  _ -> do
                      s := pureS Fetch2
              rPC := reg rPC + 1
              rNextA := var rPC
              s := pureS Fetch1
          Fetch2 -> do
              switch (reg rOp) $ \k -> case op k of
                  Opcode1 act -> do
                      let arg = cpuMemR
                      act arg
                  Opcode2 _ -> do
                      rArgLo := cpuMemR
                      s := pureS Fetch3
                  _ -> do
                      s := pureS Halt
              rPC := reg rPC + 1
              rNextA := var rPC
              s := pureS Fetch1
          Fetch3 -> do
              switch (reg rOp) $ \k -> case op k of
                  Opcode2 act -> do
                      let arg = (unsigned cpuMemR `shiftL` 8) .|. unsigned (reg rArgLo)
                      act arg
                  _ -> do
                      s := pureS Halt
              rPC := reg rPC + 1
              rNextA := var rPC
              s := pureS Fetch1
          WaitMem -> do
              rNextW := disabledS
              rNextA := reg rPC
              s := pureS Fetch1
          _ -> do
              s := pureS Halt

    let cpuMemA = var rNextA
        cpuMemW = var rNextW

    -- Debug view
    let cpuState = reg s
        cpuOp = reg rOp
        cpuArgLo = reg rArgLo
    let cpuA = reg rA
        cpuX = reg rX
        cpuY = reg rY
        cpuSP = reg rSP
        cpuP = reg rP
        cpuPC = reg rPC

    return (CPUOut{..}, CPUDebug{..})

resetVector :: Addr
resetVector = 0xFFFC

nmiVector :: Addr
nmiVector = 0xFFFA

irqVector :: Addr
irqVector = 0xFFFE
