{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}

-- | Types and coordinate operations used by the public geometry modules.
module Data.Geometry.Internal where

import qualified Data.Vector as V
import qualified Data.Vector.Generic as G
import qualified Data.Vector.Generic.Mutable as M
import qualified Data.Vector.Unboxed as U

-- | Two spatial coordinates.
data XY = XY !Double !Double deriving (Eq, Show, Read)

-- | Three spatial coordinates.
data XYZ = XYZ !Double !Double !Double deriving (Eq, Show, Read)

-- | Two spatial coordinates and a measure.
data XYM = XYM !Double !Double !Double deriving (Eq, Show, Read)

-- | Three spatial coordinates and a measure.
data XYZM = XYZM !Double !Double !Double !Double deriving (Eq, Show, Read)

-- | The coordinate dimensions stored by a geometry.
data Dimensions = DimXY | DimXYZ | DimXYM | DimXYZM
    deriving (Eq, Ord, Show, Read, Enum, Bounded)

{- | A supported coordinate type. Instances are supplied for @XY@, @XYZ@,
@XYM@, and @XYZM@. The public module keeps the methods private.
-}
class (Eq c, Show c, Read c, U.Unbox c) => Coordinate c where
    coordinateDimensions :: proxy c -> Dimensions
    coordinateComponents :: c -> (Double, Double, Double, Double)
    coordinateFromComponents :: (Double, Double, Double, Double) -> c

instance Coordinate XY where
    coordinateDimensions _ = DimXY
    coordinateComponents (XY x y) = (x, y, 0, 0)
    coordinateFromComponents (x, y, _, _) = XY x y

instance Coordinate XYZ where
    coordinateDimensions _ = DimXYZ
    coordinateComponents (XYZ x y z) = (x, y, z, 0)
    coordinateFromComponents (x, y, z, _) = XYZ x y z

instance Coordinate XYM where
    coordinateDimensions _ = DimXYM
    coordinateComponents (XYM x y m) = (x, y, 0, m)
    coordinateFromComponents (x, y, _, m) = XYM x y m

instance Coordinate XYZM where
    coordinateDimensions _ = DimXYZM
    coordinateComponents (XYZM x y z m) = (x, y, z, m)
    coordinateFromComponents (x, y, z, m) = XYZM x y z m

{- | A coordinate or an empty point. An empty point is a geometry value,
not a database NULL.
-}
data Point c = EmptyPoint | Point !c deriving (Eq, Show, Read)

{- | The seven simple geometry families. Each child uses the same coordinate
type as its parent. Empty vectors represent empty shapes. Rings and lines
do not have minimum lengths or closure requirements at this level.
-}
data Geometry c
    = PointGeometry !(Point c)
    | LineString !(U.Vector c)
    | Polygon !(V.Vector (U.Vector c))
    | MultiPoint !(U.Vector (Point c))
    | MultiLineString !(V.Vector (U.Vector c))
    | MultiPolygon !(V.Vector (V.Vector (U.Vector c)))
    | GeometryCollection !(V.Vector (Geometry c))

deriving instance (Coordinate c) => Eq (Geometry c)
deriving instance (Coordinate c) => Show (Geometry c)
deriving instance (Coordinate c) => Read (Geometry c)

-- | A geometry whose coordinate dimensions are known at runtime.
data AnyGeometry
    = GeometryXY !(Geometry XY)
    | GeometryXYZ !(Geometry XYZ)
    | GeometryXYM !(Geometry XYM)
    | GeometryXYZM !(Geometry XYZM)
    deriving (Eq, Show, Read)

newtype instance U.MVector s XY = MVXY (U.MVector s (Double, Double))
newtype instance U.Vector XY = VXY (U.Vector (Double, Double))

instance M.MVector U.MVector XY where
    basicLength (MVXY v) = M.basicLength v
    basicUnsafeSlice i n (MVXY v) = MVXY (M.basicUnsafeSlice i n v)
    basicOverlaps (MVXY a) (MVXY b) = M.basicOverlaps a b
    basicUnsafeNew n = MVXY <$> M.basicUnsafeNew n
    basicInitialize (MVXY v) = M.basicInitialize v
    basicUnsafeRead (MVXY v) i = do
        (x, y) <- M.basicUnsafeRead v i
        pure (XY x y)
    basicUnsafeWrite (MVXY v) i (XY x y) = M.basicUnsafeWrite v i (x, y)
    basicUnsafeCopy (MVXY a) (MVXY b) = M.basicUnsafeCopy a b
    basicUnsafeMove (MVXY a) (MVXY b) = M.basicUnsafeMove a b
    basicUnsafeGrow (MVXY v) n = MVXY <$> M.basicUnsafeGrow v n

instance G.Vector U.Vector XY where
    basicUnsafeFreeze (MVXY v) = VXY <$> G.basicUnsafeFreeze v
    basicUnsafeThaw (VXY v) = MVXY <$> G.basicUnsafeThaw v
    basicLength (VXY v) = G.basicLength v
    basicUnsafeSlice i n (VXY v) = VXY (G.basicUnsafeSlice i n v)
    basicUnsafeIndexM (VXY v) i = do
        (x, y) <- G.basicUnsafeIndexM v i
        pure (XY x y)
    basicUnsafeCopy (MVXY a) (VXY b) = G.basicUnsafeCopy a b
    elemseq _ (XY x y) z = x `seq` y `seq` z

instance U.Unbox XY

newtype instance U.MVector s XYZ = MVXYZ (U.MVector s (Double, Double, Double))
newtype instance U.Vector XYZ = VXYZ (U.Vector (Double, Double, Double))

instance M.MVector U.MVector XYZ where
    basicLength (MVXYZ v) = M.basicLength v
    basicUnsafeSlice i n (MVXYZ v) = MVXYZ (M.basicUnsafeSlice i n v)
    basicOverlaps (MVXYZ a) (MVXYZ b) = M.basicOverlaps a b
    basicUnsafeNew n = MVXYZ <$> M.basicUnsafeNew n
    basicInitialize (MVXYZ v) = M.basicInitialize v
    basicUnsafeRead (MVXYZ v) i = do
        (x, y, z) <- M.basicUnsafeRead v i
        pure (XYZ x y z)
    basicUnsafeWrite (MVXYZ v) i (XYZ x y z) = M.basicUnsafeWrite v i (x, y, z)
    basicUnsafeCopy (MVXYZ a) (MVXYZ b) = M.basicUnsafeCopy a b
    basicUnsafeMove (MVXYZ a) (MVXYZ b) = M.basicUnsafeMove a b
    basicUnsafeGrow (MVXYZ v) n = MVXYZ <$> M.basicUnsafeGrow v n

instance G.Vector U.Vector XYZ where
    basicUnsafeFreeze (MVXYZ v) = VXYZ <$> G.basicUnsafeFreeze v
    basicUnsafeThaw (VXYZ v) = MVXYZ <$> G.basicUnsafeThaw v
    basicLength (VXYZ v) = G.basicLength v
    basicUnsafeSlice i n (VXYZ v) = VXYZ (G.basicUnsafeSlice i n v)
    basicUnsafeIndexM (VXYZ v) i = do
        (x, y, z) <- G.basicUnsafeIndexM v i
        pure (XYZ x y z)
    basicUnsafeCopy (MVXYZ a) (VXYZ b) = G.basicUnsafeCopy a b
    elemseq _ (XYZ x y z) result = x `seq` y `seq` z `seq` result

instance U.Unbox XYZ

newtype instance U.MVector s XYM = MVXYM (U.MVector s (Double, Double, Double))
newtype instance U.Vector XYM = VXYM (U.Vector (Double, Double, Double))

instance M.MVector U.MVector XYM where
    basicLength (MVXYM v) = M.basicLength v
    basicUnsafeSlice i n (MVXYM v) = MVXYM (M.basicUnsafeSlice i n v)
    basicOverlaps (MVXYM a) (MVXYM b) = M.basicOverlaps a b
    basicUnsafeNew n = MVXYM <$> M.basicUnsafeNew n
    basicInitialize (MVXYM v) = M.basicInitialize v
    basicUnsafeRead (MVXYM v) i = do
        (x, y, z) <- M.basicUnsafeRead v i
        pure (XYM x y z)
    basicUnsafeWrite (MVXYM v) i (XYM x y z) = M.basicUnsafeWrite v i (x, y, z)
    basicUnsafeCopy (MVXYM a) (MVXYM b) = M.basicUnsafeCopy a b
    basicUnsafeMove (MVXYM a) (MVXYM b) = M.basicUnsafeMove a b
    basicUnsafeGrow (MVXYM v) n = MVXYM <$> M.basicUnsafeGrow v n

instance G.Vector U.Vector XYM where
    basicUnsafeFreeze (MVXYM v) = VXYM <$> G.basicUnsafeFreeze v
    basicUnsafeThaw (VXYM v) = MVXYM <$> G.basicUnsafeThaw v
    basicLength (VXYM v) = G.basicLength v
    basicUnsafeSlice i n (VXYM v) = VXYM (G.basicUnsafeSlice i n v)
    basicUnsafeIndexM (VXYM v) i = do
        (x, y, z) <- G.basicUnsafeIndexM v i
        pure (XYM x y z)
    basicUnsafeCopy (MVXYM a) (VXYM b) = G.basicUnsafeCopy a b
    elemseq _ (XYM x y z) result = x `seq` y `seq` z `seq` result

instance U.Unbox XYM

newtype instance U.MVector s XYZM = MVXYZM (U.MVector s (Double, Double, Double, Double))
newtype instance U.Vector XYZM = VXYZM (U.Vector (Double, Double, Double, Double))

instance M.MVector U.MVector XYZM where
    basicLength (MVXYZM v) = M.basicLength v
    basicUnsafeSlice i n (MVXYZM v) = MVXYZM (M.basicUnsafeSlice i n v)
    basicOverlaps (MVXYZM a) (MVXYZM b) = M.basicOverlaps a b
    basicUnsafeNew n = MVXYZM <$> M.basicUnsafeNew n
    basicInitialize (MVXYZM v) = M.basicInitialize v
    basicUnsafeRead (MVXYZM v) i = do
        (x, y, z, m) <- M.basicUnsafeRead v i
        pure (XYZM x y z m)
    basicUnsafeWrite (MVXYZM v) i (XYZM x y z m) = M.basicUnsafeWrite v i (x, y, z, m)
    basicUnsafeCopy (MVXYZM a) (MVXYZM b) = M.basicUnsafeCopy a b
    basicUnsafeMove (MVXYZM a) (MVXYZM b) = M.basicUnsafeMove a b
    basicUnsafeGrow (MVXYZM v) n = MVXYZM <$> M.basicUnsafeGrow v n

instance G.Vector U.Vector XYZM where
    basicUnsafeFreeze (MVXYZM v) = VXYZM <$> G.basicUnsafeFreeze v
    basicUnsafeThaw (VXYZM v) = MVXYZM <$> G.basicUnsafeThaw v
    basicLength (VXYZM v) = G.basicLength v
    basicUnsafeSlice i n (VXYZM v) = VXYZM (G.basicUnsafeSlice i n v)
    basicUnsafeIndexM (VXYZM v) i = do
        (x, y, z, m) <- G.basicUnsafeIndexM v i
        pure (XYZM x y z m)
    basicUnsafeCopy (MVXYZM a) (VXYZM b) = G.basicUnsafeCopy a b
    elemseq _ (XYZM x y z m) result = x `seq` y `seq` z `seq` m `seq` result

instance U.Unbox XYZM

newtype instance U.MVector s (Point c) = MVPoint (U.MVector s (Bool, c))
newtype instance U.Vector (Point c) = VPoint (U.Vector (Bool, c))

instance (Coordinate c) => M.MVector U.MVector (Point c) where
    basicLength (MVPoint v) = M.basicLength v
    basicUnsafeSlice i n (MVPoint v) = MVPoint (M.basicUnsafeSlice i n v)
    basicOverlaps (MVPoint a) (MVPoint b) = M.basicOverlaps a b
    basicUnsafeNew n = MVPoint <$> M.basicUnsafeNew n
    basicInitialize (MVPoint v) = M.basicInitialize v
    basicUnsafeRead (MVPoint v) i = do
        (present, coordinate) <- M.basicUnsafeRead v i
        pure (if present then Point coordinate else EmptyPoint)
    basicUnsafeWrite (MVPoint v) i point = M.basicUnsafeWrite v i $ case point of
        EmptyPoint -> (False, coordinateFromComponents (0, 0, 0, 0))
        Point coordinate -> (True, coordinate)
    basicUnsafeCopy (MVPoint a) (MVPoint b) = M.basicUnsafeCopy a b
    basicUnsafeMove (MVPoint a) (MVPoint b) = M.basicUnsafeMove a b
    basicUnsafeGrow (MVPoint v) n = MVPoint <$> M.basicUnsafeGrow v n

instance (Coordinate c) => G.Vector U.Vector (Point c) where
    basicUnsafeFreeze (MVPoint v) = VPoint <$> G.basicUnsafeFreeze v
    basicUnsafeThaw (VPoint v) = MVPoint <$> G.basicUnsafeThaw v
    basicLength (VPoint v) = G.basicLength v
    basicUnsafeSlice i n (VPoint v) = VPoint (G.basicUnsafeSlice i n v)
    basicUnsafeIndexM (VPoint v) i = do
        (present, coordinate) <- G.basicUnsafeIndexM v i
        pure (if present then Point coordinate else EmptyPoint)
    basicUnsafeCopy (MVPoint a) (VPoint b) = G.basicUnsafeCopy a b
    elemseq _ EmptyPoint result = result
    elemseq _ (Point coordinate) result = coordinate `seq` result

instance (Coordinate c) => U.Unbox (Point c)
