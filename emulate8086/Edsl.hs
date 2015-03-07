{-# LANGUAGE NoMonomorphismRestriction #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE GADTs #-}
module Edsl
    {-( compileInst
    , Part (..), Exp (..)
    )-} where

import Data.List
import Data.Maybe
import Data.Int
import Data.Word
import Data.Bits
import Control.Applicative
import Control.Monad
import Control.Lens

import Hdis86 hiding (wordSize)
import Hdis86.Incremental

import Helper

----------------------------------------

data Part a where
    IP :: Part Word16
    AX, BX, CX, DX, SI, DI, BP, SP :: Part Word16
    Es, Ds, Ss, Cs :: Part Word16
    Heap8  :: Exp Int -> Part Word8
    Heap16 :: Exp Int -> Part Word16
    Low, High :: Part Word16 -> Part Word8
    CF, PF, AF, ZF, SF, IF, DF, OF :: Part Bool
    Flags :: Part Word16

    DXAX :: Part Word32
    XX :: Part Word16   -- TODO: elim this
    Immed :: Exp a -> Part a  -- TODO: elim this

data Exp a where
    C :: a -> Exp a
    Let :: Exp a -> (Exp a -> Exp b) -> Exp b
    Seq :: Exp b -> Exp a -> Exp a
    Tuple :: Exp a -> Exp b -> Exp (a, b)
    Fst :: Exp (a, b) -> Exp a
    Snd :: Exp (a, b) -> Exp b
    Iterate :: Exp Int -> (Exp a -> Exp a) -> Exp a -> Exp a
    Replicate :: Exp Int -> Exp () -> Exp ()
    If :: Exp Bool -> Exp a -> Exp a -> Exp a
    Error :: Halt -> Exp ()
    Trace :: String -> Exp ()

    Get :: Part a -> Exp a
    Set :: Part a -> Exp a -> Exp ()

    Eq :: Eq a => Exp a -> Exp a -> Exp Bool
    Sub, Add, Mul :: Num a => Exp a -> Exp a -> Exp a
    QuotRem :: Integral a => Exp a -> Exp a -> Exp () -> ((Exp a, Exp a) -> Exp ()) -> Exp ()
    And, Or, Xor :: Bits a => Exp a -> Exp a -> Exp a
    Not, ShiftL, ShiftR, RotateL, RotateR :: Bits a => Exp a -> Exp a
    Bit :: Bits a => Int -> Exp a -> Exp Bool
    SetBit :: Bits a => Int -> Exp Bool -> Exp a -> Exp a
    HighBit :: FiniteBits a => Exp a -> Exp Bool
    SetHighBit :: FiniteBits a => Exp Bool -> Exp a -> Exp a
    EvenParity :: Exp Word8 -> Exp Bool

    Signed :: AsSigned a => Exp a -> Exp (Signed a)
    Extend :: Extend a => Exp a -> Exp (X2 a)
    Convert :: (Integral a, Num b) => Exp a -> Exp b
    SegAddr :: Exp Word16 -> Exp Word16 -> Exp Int

    Input :: Exp Word16 -> Exp Word16
    Output :: Exp Word16 -> Exp Word16 -> Exp ()
    Interrupt :: Exp Word8 -> Exp ()

trace_ = Trace
undefBool = C False
unTup x = (Fst x, Snd x)

instance Num Bool where
    (+) = xor
    (-) = xor
    (*) = (&&)
    abs = id
    signum = id
    fromInteger = toEnum . fromInteger . (`mod` 2)
    
instance Real Bool where
    toRational = toRational . fromEnum

instance Integral Bool where
    toInteger = toInteger . fromEnum
    a `quotRem` 1 = (a, 0)
    a `quotRem` 0 = error $ "quotRem " ++ show a ++ " 0 :: Bool"

instance Functor Exp where
    fmap = undefined
instance Applicative Exp where
    (<*>) = undefined
    pure = C
instance Monad Exp where
    (>>=) = undefined
    C _ >> e = e
    e1 >> e2 = Seq e1 e2
    return = C

modify :: Part a -> (Exp a -> Exp a) -> Exp ()
modify p f = Set p $ f $ Get p

sizeByte_ i@Inst{..}
    | inOpcode `elem` [Icbw, Icmpsb, Imovsb, Istosb, Ilodsb, Iscasb, Ilahf] = 1
    | inOpcode `elem` [Icwd, Icmpsw, Imovsw, Istosw, Ilodsw, Iscasw] = 2
    | inOpcode == Iout  = fromJust $ operandSize $ inOperands !! 1
    | otherwise = fromMaybe (error $ "size: " ++ show i) $ listToMaybe $ catMaybes $ map operandSize inOperands

operandSize = \case
    Reg (Reg16 _)   -> Just 2
    Reg (Reg8 _ _)  -> Just 1
    Mem (Memory Bits8 _ _ _ _)  -> Just 1
    Mem (Memory Bits16 _ _ _ _) -> Just 2
    Imm (Immediate Bits8 v)  -> Just 1
    Imm (Immediate Bits16 v) -> Just 2
    _ -> Nothing

segOf = \case
    RegIP     -> Cs
    Reg16 RSP -> Ss
    Reg16 RBP -> Ss
    _         -> Ds

reg :: Register -> Part Word16
reg = \case
    Reg16 r -> case r of
        RAX -> AX
        RBX -> BX
        RCX -> CX
        RDX -> DX
        RSI -> SI
        RDI -> DI
        RBP -> BP
        RSP -> SP
    RegSeg r -> case r of
        ES -> Es
        DS -> Ds
        SS -> Ss
        CS -> Cs
    RegIP -> IP
    RegNone -> Immed $ C 0

segAddr_ :: Part Word16 -> Exp Word16 -> Exp Int
segAddr_ seg off = SegAddr (Get seg) off

ips, sps :: Exp Int
ips = segAddr_ Cs $ Get IP
sps = segAddr_ Ss $ Get SP

addressOf :: Maybe Segment -> Memory -> Exp Int
addressOf segmentPrefix m
    = segAddr_ (maybe (segOf $ mBase m) (reg . RegSeg) segmentPrefix) (addressOf' m)

addressOf' :: Memory -> Exp Word16
addressOf' (Memory _ r r' 0 i) = Add (C $ imm i) $ Add (Get $ reg r) (Get $ reg r')

byteOperand :: Maybe Segment -> Operand -> Part Word8
byteOperand segmentPrefix x = case x of
    Reg r -> case r of
        Reg8 r L -> case r of
            RAX -> Low AX
            RBX -> Low BX
            RCX -> Low CX
            RDX -> Low DX
        Reg8 r H -> case r of
            RAX -> High AX
            RBX -> High BX
            RCX -> High CX
            RDX -> High DX
    Mem m -> Heap8 $ addressOf segmentPrefix m
    Imm (Immediate Bits8 v) -> Immed $ C $ fromIntegral v
    Hdis86.Const (Immediate Bits0 0) -> Immed $ C 1 -- !!!

wordOperand :: Maybe Segment -> Operand -> Part Word16
wordOperand segmentPrefix x = case x of
    Reg r  -> reg r
    Mem m  -> Heap16 $ addressOf segmentPrefix m
    Imm i  -> Immed $ C $ imm' i
    Jump i -> Immed $ Add (C $ imm i) (Get IP)


imm = fromIntegral . iValue
-- patched version
imm' (Immediate Bits8 i) = fromIntegral (fromIntegral i :: Int8)
imm' i = imm i

memIndex r = Memory undefined (Reg16 r) RegNone 0 $ Immediate Bits0 0

jump :: Exp Word16 -> Exp ()
jump a = Set IP a

stackTop :: Part Word16
stackTop = Heap16 sps

push :: Exp Word16 -> Exp ()
push x = do
    modify SP $ Add $ C $ -2
    Set stackTop x

pop :: Exp Word16
pop = Let (Get stackTop) $ \x -> do
    modify SP $ Add $ C 2
    x

move a b = Set a $ Get b

execInstruction' :: Metadata -> Exp ()
execInstruction' mdat@Metadata{mdInst = i@Inst{..}}
  = case filter nonSeg inPrefixes of
    [Rep, RepE]
        | inOpcode `elem` [Icmpsb, Icmpsw, Iscasb, Iscasw] -> cycle $ Get ZF      -- repe
        | inOpcode `elem` [Imovsb, Imovsw, Ilodsb, Ilodsw, Istosb, Istosw] -> cycle'      -- rep
    [RepNE]
        | inOpcode `elem` [Icmpsb, Icmpsw, Iscasb, Iscasw, Imovsb, Imovsw, Ilodsb, Ilodsw, Istosb, Istosw]
            -> cycle $ Not $ Get ZF
    [] -> body
  where
    body = compileInst $ mdat { mdInst = i { inPrefixes = filter (not . rep) inPrefixes }}

    cycle' = do
        Replicate (Convert $ Get CX) body
        Set CX $ C 0

    cycle cond = do
        If (Eq (C 0) $ Get CX) (return ()) $ do
            body
            modify CX $ Add $ C $ -1
            If cond (cycle cond) (return ())

    rep p = p `elem` [Rep, RepE, RepNE]

nonSeg = \case
    Seg _ -> False
    x -> True


compileInst :: Metadata -> Exp ()
compileInst mdat@Metadata{mdInst = i@Inst{..}} = case inOpcode of

    _ | length inOperands > 2 -> error "more than 2 operands are not supported"

    _ | inOpcode `elem` [Ijmp, Icall] -> do
      case op1 of
        Ptr (Pointer seg (Immediate Bits16 v)) -> do
            when (inOpcode == Icall) $ do
                push $ Get Cs
                push $ Get IP
            Set Cs $ C $ fromIntegral seg
            Set IP $ C $ fromIntegral v
        Mem _ -> do
            when (inOpcode == Icall) $ do
                when far $ push $ Get Cs
                push $ Get IP
            Let (addr op1) $ \ad -> do
                Set IP $ Get $ Heap16 ad
                when far $ Set Cs $ Get $ Heap16 $ Add (C $ 2 ^. byte) ad
        _ -> do
            when (inOpcode == Icall) $ do
                push $ Get IP
            Set IP $ Get op1w

    _ | inOpcode `elem` [Iret, Iretf, Iiretw] -> do
        when (inOpcode == Iiretw) $ trace_ "iret"
        Set IP pop
        when (inOpcode `elem` [Iretf, Iiretw]) $ Set Cs pop
        when (inOpcode == Iiretw) $ Set Flags pop
        when (length inOperands == 1) $ modify SP $ Add (Get op1w)

    Iint  -> Interrupt $ Get $ byteOperand segmentPrefix op1
    Iinto -> If (Get OF) (Interrupt $ C 4) (C ())

    Ihlt  -> Error CleanHalt

    Ijp   -> condJump $ Get PF
    Ijnp  -> condJump $ Not $ Get PF
    Ijz   -> condJump $ Get ZF
    Ijnz  -> condJump $ Not $ Get ZF
    Ijo   -> condJump $ Get OF
    Ijno  -> condJump $ Not $ Get OF
    Ijs   -> condJump $ Get SF
    Ijns  -> condJump $ Not $ Get SF
    Ijb   -> condJump $ Get CF
    Ijae  -> condJump $ Not $ Get CF
    Ijbe  -> condJump $ Or (Get CF) (Get ZF)
    Ija   -> condJump $ Not $ Or (Get CF) (Get ZF)
    Ijl   -> condJump $ Xor (Get SF) (Get OF)
    Ijge  -> condJump $ Not $ Xor (Get SF) (Get OF)
    Ijle  -> condJump $ Or (Xor (Get SF) (Get OF)) (Get ZF)
    Ijg   -> condJump $ Not $ Or (Xor (Get SF) (Get OF)) (Get ZF)

    Ijcxz -> condJump $ Eq (C 0) (Get CX)

    Iloop   -> loop $ C True
    Iloope  -> loop $ Get ZF
    Iloopnz -> loop $ Not $ Get ZF

    Ipush   -> push $ Get op1w
    Ipop    -> Set op1w pop
    Ipusha  -> sequence_ [push $ Get r | r <- [AX,CX,DX,BX,SP,BP,SI,DI]]
    Ipopa   -> sequence_ [Set r pop | r <- [DI,SI,BP,XX,BX,DX,CX,AX]]
    Ipushfw -> push $ Get Flags
    Ipopfw  -> Set Flags pop
    Isahf -> Set (Low  AX) $ Get $ Low Flags
    Ilahf -> Set (High AX) $ Get $ Low Flags

    Iclc  -> Set CF $ C False
    Icmc  -> modify CF Not
    Istc  -> Set CF $ C True
    Icld  -> Set DF $ C False
    Istd  -> Set DF $ C True
    Icli  -> Set IF $ C False
    Isti  -> Set IF $ C True

    Inop  -> return ()

    Ixlatb -> Set (Low AX) $ Get $ Heap8 $ segAddr_ (maybe Ds (reg . RegSeg) segmentPrefix) $ Add (Convert $ Get $ Low AX) (Get BX)

    Ilea -> Set op1w op2addr'
    _ | inOpcode `elem` [Iles, Ilds] -> Let (addr op2) $ \ad -> do
        Set op1w $ Get $ Heap16 ad
        Set (case inOpcode of Iles -> Es; Ilds -> Ds) $ Get $ Heap16 $ Add (C $ 2 ^. byte) ad

    _ -> case sizeByte of
        1 -> withSize byteOperand (Low AX) (High AX) AX
        2 -> withSize wordOperand AX DX DXAX
  where
    withSize :: forall a . (AsSigned a, Extend a, Extend (Signed a), AsSigned (X2 a), X2 (Signed a) ~ Signed (X2 a))
        => (Maybe Segment -> Operand -> Part a)
        -> Part a
        -> Part a
        -> Part (X2 a)
        -> Exp ()
    withSize tr_ alx ahd axd = case inOpcode of
        Imov  -> move op1' op2'
        Ixchg -> Let (Get op1') $ \o1 -> do
            move op1' op2'
            Set op2' o1
        Inot  -> modify op1' Not

        Isal  -> shiftOp $ \_ x -> (HighBit x, ShiftL x)
        Ishl  -> shiftOp $ \_ x -> (HighBit x, ShiftL x)
        Ircl  -> shiftOp $ \c x -> (HighBit x, SetBit 0 c $ ShiftL x)
        Irol  -> shiftOp $ \_ x -> (HighBit x, RotateL x)
        Isar  -> shiftOp $ \_ x -> (Bit 0 x, Convert $ ShiftR $ Signed x)
        Ishr  -> shiftOp $ \_ x -> (Bit 0 x, ShiftR x)
        Ircr  -> shiftOp $ \c x -> (Bit 0 x, SetHighBit c $ ShiftR x)
        Iror  -> shiftOp $ \_ x -> (Bit 0 x, RotateR x)

        Iadd  -> twoOp True  Add
        Isub  -> twoOp True  Sub
        Icmp  -> twoOp False Sub
        Ixor  -> twoOp True  Xor
        Ior   -> twoOp True  Or
        Iand  -> twoOp True  And
        Itest -> twoOp False And
        Iadc  -> twoOp True $ \a b -> Add (Add a b) $ Convert (Get CF)
        Isbb  -> twoOp True $ \a b -> Sub (Sub a b) $ Convert (Get CF)
        Ineg  -> twoOp_ True (flip Sub) op1' $ Immed $ C 0
        Idec  -> twoOp_ True Add op1' $ Immed $ C $ -1
        Iinc  -> twoOp_ True Add op1' $ Immed $ C 1

        Idiv  -> divide id id
        Iidiv -> divide Signed Signed
        Imul  -> multiply id
        Iimul -> multiply Signed

        _ | inOpcode `elem` [Icwd, Icbw] -> Set axd $ Convert $ Signed $ Get alx
          | inOpcode `elem` [Istosb, Istosw] -> move di'' alx >> adjustIndex DI
          | inOpcode `elem` [Ilodsb, Ilodsw] -> move alx si'' >> adjustIndex SI
          | inOpcode `elem` [Imovsb, Imovsw] -> move di'' si'' >> adjustIndex SI >> adjustIndex DI
          | inOpcode `elem` [Iscasb, Iscasw] -> do
            twoOp_ False Sub di'' alx
            adjustIndex DI
          | inOpcode `elem` [Icmpsb, Icmpsw] -> do
            twoOp_ False Sub si'' di''
            adjustIndex SI
            adjustIndex DI

        Iin  -> Set (tr op1) $ Convert $ Input $ Get $ wordOperand segmentPrefix op2
        Iout -> Output (Get $ wordOperand segmentPrefix op1) $ Convert op2v

      where
        si'', di'' :: Part a
        si'' = tr $ Mem $ memIndex RSI
        di'' = tr_ (Just $ fromMaybe ES segmentPrefix) $ Mem $ memIndex RDI

        adjustIndex i = modify i $ \x -> If (Get DF) (Add x $ C $ -sizeByte) (Add x $ C sizeByte)

        op1' = tr op1
        op2' = tr op2
        op1v = Get op1'
        op2v = Get op2'
        tr :: Operand -> Part a
        tr = tr_ segmentPrefix

        divide :: (Integral a, Integral c, Integral (X2 c)) => (Exp a -> Exp c) -> (Exp (X2 a) -> Exp (X2 c)) -> Exp ()
        divide asSigned asSigned' =
            QuotRem (asSigned' $ Get axd) (Convert $ asSigned op1v)
                (Error $ Err $ "divide by zero interrupt is not called (not implemented)") $ \(d, m) -> do
                    Set alx $ Convert d
                    Set ahd $ Convert m

        multiply :: forall c . (Extend c, FiniteBits (X2 c)) => (Exp a -> Exp c) -> Exp ()
        multiply asSigned =
            Let (Mul (Extend $ asSigned $ Get alx) (Extend $ asSigned op1v)) $ \r ->
            Let (Not $ Eq r $ Extend (Convert r :: Exp c)) $ \c -> do
                Set axd $ Convert r
                Set CF c
                Set OF c
                Set SF undefBool
                Set PF undefBool
                Set ZF undefBool

        shiftOp :: (forall b . (AsSigned b) => Exp Bool -> Exp b -> (Exp Bool, Exp b)) -> Exp ()
        shiftOp op = do
            Let (And (C 0x1f) $ Get $ byteOperand segmentPrefix op2) $ \n -> do
            If (Eq (C 0) n) (return ()) $ Let (Iterate (Convert n) (uncurry Tuple . uncurry op . unTup) $ Tuple (Get CF) op1v) $ \t -> do
                let r = Snd t
                Set CF $ Fst t
                Set op1' r
                when (inOpcode `elem` [Isal, Isar, Ishl, Ishr]) $ do
                    Set ZF $ Eq (C 0) r
                    Set SF $ HighBit r
                    Set OF undefBool
                    Set PF $ EvenParity $ Convert r
                    Set AF undefBool
                when (inOpcode `elem` [Ircl, Ircr, Irol, Iror]) $ do
                    Set ZF undefBool
                    Set SF undefBool
                    Set OF undefBool
                    Set PF undefBool
                    Set AF undefBool

        twoOp :: Bool -> (forall b . (Integral b, FiniteBits b) => Exp b -> Exp b -> Exp b) -> Exp ()
        twoOp store op = twoOp_ store op op1' op2'

        twoOp_ :: AsSigned a => Bool -> (forall a . (Integral a, FiniteBits a) => Exp a -> Exp a -> Exp a) -> Part a -> Part a -> Exp ()
        twoOp_ store op op1 op2 = Let (Get op1) $ \a -> Let (Get op2) $ \b -> Let (op a b) $ \r -> do

            when (inOpcode `notElem` [Idec, Iinc]) $
                Set CF $ Not $ Eq (Convert r) $ op (Convert a :: Exp Int) (Convert b)
            Set OF $ Not $ Eq (Convert $ Signed r) $ op (Convert $ Signed a :: Exp Int) (Convert $ Signed b)

            Set ZF $ Eq (C 0) r
            Set SF $ HighBit r
            Set PF $ EvenParity $ Convert r
            Set AF undefBool

            when store $ Set op1 r

    far = " far " `isInfixOf` mdAssembly mdat

    addr op = case op of Mem m -> addressOf segmentPrefix m

    loop cond = do
        modify CX (Add $ C $ -1)
        condJump (And (Not $ Eq (C 0) (Get CX)) cond)

    condJump :: Exp Bool -> Exp ()
    condJump b = If b (jump $ Get op1w) (C ())

    sizeByte :: Word16
    sizeByte = fromIntegral $ sizeByte_ i

    ~(op1: ~(op2:_)) = inOperands
    op1w = wordOperand segmentPrefix op1
    op2addr' = case op2 of Mem m -> addressOf' m

    segmentPrefix :: Maybe Segment
    segmentPrefix = case inPrefixes of
        [Seg s] -> Just s
        [] -> Nothing


interrupt v = do
--    trace_ $ "interrupt " ++ showHex' 2 v
    push $ Get Flags
    push $ Get Cs
    push $ Get IP
    Set IF $ C False
    Set Cs $ Get $ Heap16 $ C (4*fromIntegral v ^. byte + 16)
    Set IP $ Get $ Heap16 $ C (4*fromIntegral v ^. byte)

iret = do
--    trace_ "iret"
    Set IP pop
    Set Cs pop
    Set IF $ Bit 9 pop

