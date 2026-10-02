{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE ScopedTypeVariables #-}

{- | Simple Features accessors and planar measurements.

Most names follow OGC Simple Feature Access. Indices start at one, as in the
standard. The module exports short names such as 'x' and 'area', so import it
qualified:

> import qualified Data.Geometry.SimpleFeatures as SF

Measurements use only X and Y. Z and M stay available through the accessors.
Computed geometries use t'XY' coordinates.

The planar operations require finite X and Y values. Polygon measurements
assume valid topology, and these functions do not check it. Area and perimeter
close open rings. For spatial predicates, validity checks, distance, buffers,
and overlay operations, use the @geos@ package.
-}
module Data.Geometry.SimpleFeatures (
    geometryType,
    dimension,
    coordinateDimension,
    spatialDimension,
    is3D,
    isMeasured,
    isEmpty,
    x,
    y,
    z,
    m,
    numGeometries,
    geometryN,
    numPoints,
    pointN,
    startPoint,
    endPoint,
    isClosed,
    exteriorRing,
    numInteriorRings,
    interiorRingN,
    envelope,
    area,
    curveLength,
    perimeter,
    centroid,
    convexHull,
) where

import Data.Geometry.Internal
import qualified Data.List as List
import Data.Proxy (Proxy (..))
import qualified Data.Vector as V
import qualified Data.Vector.Unboxed as U

-- | The uppercase WKT family name, such as @POLYGON@, without a dimension tag.
geometryType :: Geometry c -> String
geometryType geometry = case geometry of
    PointGeometry _ -> "POINT"
    LineString _ -> "LINESTRING"
    Polygon _ -> "POLYGON"
    MultiPoint _ -> "MULTIPOINT"
    MultiLineString _ -> "MULTILINESTRING"
    MultiPolygon _ -> "MULTIPOLYGON"
    GeometryCollection _ -> "GEOMETRYCOLLECTION"

{- | The topological dimension: 0 for points, 1 for lines, and 2 for polygons.
Empty values keep their family's dimension. A collection has the largest
dimension of its members, or -1 when it has no members.
-}
dimension :: Geometry c -> Int
dimension geometry = case geometry of
    PointGeometry _ -> 0
    MultiPoint _ -> 0
    LineString _ -> 1
    MultiLineString _ -> 1
    Polygon _ -> 2
    MultiPolygon _ -> 2
    GeometryCollection children -> V.foldl' (\n child -> max n (dimension child)) (-1) children

-- | The number of ordinates in each coordinate: 2, 3, or 4.
coordinateDimension :: forall c. (Coordinate c) => Geometry c -> Int
coordinateDimension _ = case coordinateDimensions (Proxy :: Proxy c) of
    DimXY -> 2
    DimXYZM -> 4
    _ -> 3

-- | 2 for t'XY' and t'XYM', or 3 for t'XYZ' and t'XYZM'.
spatialDimension :: (Coordinate c) => Geometry c -> Int
spatialDimension geometry = if is3D geometry then 3 else 2

-- | Whether the coordinate type has Z. The value depends only on the type.
is3D :: forall c. (Coordinate c) => Geometry c -> Bool
is3D _ = coordinateDimensions (Proxy :: Proxy c) `elem` [DimXYZ, DimXYZM]

-- | Whether the coordinate type has M. The value depends only on the type.
isMeasured :: forall c. (Coordinate c) => Geometry c -> Bool
isMeasured _ = coordinateDimensions (Proxy :: Proxy c) `elem` [DimXYM, DimXYZM]

-- | Whether the geometry has no coordinates. A collection of empty members is empty.
isEmpty :: (Coordinate c) => Geometry c -> Bool
isEmpty geometry = case geometry of
    PointGeometry point -> point == EmptyPoint
    LineString points -> U.null points
    Polygon rings -> V.all U.null rings
    MultiPoint points -> U.all (== EmptyPoint) points
    MultiLineString lineStrings -> V.all U.null lineStrings
    MultiPolygon polygons -> V.all (V.all U.null) polygons
    GeometryCollection children -> V.all isEmpty children

-- | The X ordinate.
x :: (Coordinate c) => c -> Double
x coordinate = let (value, _, _, _) = coordinateComponents coordinate in value

-- | The Y ordinate.
y :: (Coordinate c) => c -> Double
y coordinate = let (_, value, _, _) = coordinateComponents coordinate in value

-- | The Z ordinate, or 'Nothing' when the coordinate type has no Z.
z :: forall c. (Coordinate c) => c -> Maybe Double
z coordinate = case coordinateDimensions (Proxy :: Proxy c) of
    DimXYZ -> Just value
    DimXYZM -> Just value
    _ -> Nothing
  where
    (_, _, value, _) = coordinateComponents coordinate

-- | The M ordinate, or 'Nothing' when the coordinate type has no M.
m :: forall c. (Coordinate c) => c -> Maybe Double
m coordinate = case coordinateDimensions (Proxy :: Proxy c) of
    DimXYM -> Just value
    DimXYZM -> Just value
    _ -> Nothing
  where
    (_, _, _, value) = coordinateComponents coordinate

{- | The number of direct members of a multi-geometry or collection, including
empty members. Other geometries count as one member, also when empty.
-}
numGeometries :: (Coordinate c) => Geometry c -> Int
numGeometries geometry = case geometry of
    MultiPoint points -> U.length points
    MultiLineString lineStrings -> V.length lineStrings
    MultiPolygon polygons -> V.length polygons
    GeometryCollection children -> V.length children
    _ -> 1

{- | The direct member at a one-based index, or 'Nothing' when the index is out
of range. A geometry that is not a collection is its own first member.
-}
geometryN :: (Coordinate c) => Int -> Geometry c -> Maybe (Geometry c)
geometryN index geometry
    | index < 1 = Nothing
    | otherwise = case geometry of
        MultiPoint points -> PointGeometry <$> points U.!? (index - 1)
        MultiLineString lineStrings -> LineString <$> lineStrings V.!? (index - 1)
        MultiPolygon polygons -> Polygon <$> polygons V.!? (index - 1)
        GeometryCollection children -> children V.!? (index - 1)
        _ -> if index == 1 then Just geometry else Nothing

-- | The number of coordinates in a 'LineString'. Other families give 'Nothing'.
numPoints :: (Coordinate c) => Geometry c -> Maybe Int
numPoints (LineString points) = Just (U.length points)
numPoints _ = Nothing

-- | The 'LineString' coordinate at a one-based index.
pointN :: (Coordinate c) => Int -> Geometry c -> Maybe c
pointN index (LineString points)
    | index >= 1 = points U.!? (index - 1)
pointN _ _ = Nothing

-- | The first coordinate of a nonempty 'LineString'.
startPoint :: (Coordinate c) => Geometry c -> Maybe c
startPoint = pointN 1

-- | The last coordinate of a nonempty 'LineString'.
endPoint :: (Coordinate c) => Geometry c -> Maybe c
endPoint (LineString points) = points U.!? (U.length points - 1)
endPoint _ = Nothing

{- | Whether a nonempty 'LineString' starts and ends at the same XY position.
A 'MultiLineString' is closed when it has lines and all of them are closed.
Other families give 'False'. The test does not check whether a line is simple.
-}
isClosed :: (Coordinate c) => Geometry c -> Bool
isClosed geometry = case geometry of
    LineString points -> closed points
    MultiLineString lineStrings -> not (V.null lineStrings) && V.all closed lineStrings
    _ -> False
  where
    closed points = not (U.null points) && xy (U.head points) == xy (U.last points)

-- | The exterior ring of a 'Polygon', or 'Nothing' when it has no rings.
exteriorRing :: Geometry c -> Maybe (U.Vector c)
exteriorRing (Polygon rings) = rings V.!? 0
exteriorRing _ = Nothing

-- | The number of holes in a 'Polygon'. Other families give 'Nothing'.
numInteriorRings :: Geometry c -> Maybe Int
numInteriorRings (Polygon rings) = Just (max 0 (V.length rings - 1))
numInteriorRings _ = Nothing

-- | The 'Polygon' hole at a one-based index. Index 1 is the first hole.
interiorRingN :: Int -> Geometry c -> Maybe (U.Vector c)
interiorRingN index (Polygon rings)
    | index >= 1 = rings V.!? index
interiorRingN _ _ = Nothing

{- | The smallest XY bounding rectangle, as a counterclockwise 'Polygon'.
Empty input gives an empty collection. Degenerate bounds give a point or a
two-point line.
-}
envelope :: (Coordinate c) => Geometry c -> Geometry XY
envelope geometry = case foldCoordinates extend Nothing geometry of
    Nothing -> GeometryCollection V.empty
    Just (minX, minY, maxX, maxY)
        | minX == maxX && minY == maxY -> PointGeometry (Point (XY minX minY))
        | minX == maxX || minY == maxY -> LineString (U.fromList [XY minX minY, XY maxX maxY])
        | otherwise -> Polygon (V.singleton (U.fromList [XY minX minY, XY maxX minY, XY maxX maxY, XY minX maxY, XY minX minY]))
  where
    extend Nothing coordinate = Just (x coordinate, y coordinate, x coordinate, y coordinate)
    extend (Just (!minX, !minY, !maxX, !maxY)) coordinate =
        Just (min minX (x coordinate), min minY (y coordinate), max maxX (x coordinate), max maxY (y coordinate))

{- | The total polygon area in square coordinate units. The first ring of each
polygon is the exterior, and the other rings are holes. Ring orientation does
not matter. Other families add zero.
Use exact cross products before conversion to Double to avoid cancellation.
-}
area :: (Coordinate c) => Geometry c -> Double
area geometry = let (weight, _, _) = surfaceMoments geometry in fromRational (weight / 2)

{- | The total length of all lines, including lines in collections, in coordinate
units. Polygon boundaries and points add zero.
-}
curveLength :: (Coordinate c) => Geometry c -> Double
curveLength geometry = case geometry of
    LineString points -> pathLength False points
    MultiLineString lineStrings -> V.foldl' (\total points -> total + pathLength False points) 0 lineStrings
    GeometryCollection children -> V.foldl' (\total child -> total + curveLength child) 0 children
    _ -> 0

-- | The total length of all polygon rings, including holes. Lines and points add zero.
perimeter :: (Coordinate c) => Geometry c -> Double
perimeter geometry = case geometry of
    Polygon rings -> V.foldl' (\total points -> total + pathLength True points) 0 rings
    MultiPolygon polygons -> V.foldl' (\total rings -> total + perimeter (Polygon rings)) 0 polygons
    GeometryCollection children -> V.foldl' (\total child -> total + perimeter child) 0 children
    _ -> 0

{- | The XY centroid, or 'EmptyPoint' for empty input. Polygons are weighted by
area. If the total area is zero, segments are weighted by length. If all
segments have zero length, the result is the mean of the coordinates.
Lower-dimensional parts do not affect a higher-dimensional centroid. The
centroid can be outside the geometry, for example in a hole.
-}
centroid :: (Coordinate c) => Geometry c -> Point XY
centroid geometry = case surfaceMoments geometry of
    (weight, mx, my) | weight /= 0 -> mean weight mx my
    _ -> case linearMoments geometry of
        (weight, mx, my) | weight /= 0 -> mean weight mx my
        _ -> case foldCoordinates addPoint (0, 0, 0) geometry of
            (0, _, _) -> EmptyPoint
            (weight, mx, my) -> mean weight mx my
  where
    mean weight mx my = Point (XY (fromRational (mx / weight)) (fromRational (my / weight)))
    addPoint (!weight, !mx, !my) coordinate = (weight + 1, mx + toRational (x coordinate), my + toRational (y coordinate))

{- | The XY convex hull, from Andrew's monotone chain algorithm. The result is
an empty collection, a point, a line, or a counterclockwise polygon, depending
on the hull dimension. The hull has no duplicate or collinear vertices.
Exact orientation tests avoid floating-point cancellation.
-}
convexHull :: (Coordinate c) => Geometry c -> Geometry XY
convexHull geometry = case points of
    [] -> GeometryCollection V.empty
    [point] -> PointGeometry (Point (uncurry XY point))
    _ -> case hull of
        [a, b] -> LineString (U.fromList [uncurry XY a, uncurry XY b])
        _ -> Polygon (V.singleton (U.fromList (map (uncurry XY) (hull ++ take 1 hull))))
  where
    points = [point | point : _ <- List.group (List.sort (foldCoordinates (\rest coordinate -> xy coordinate : rest) [] geometry))]
    hull = init (chain points) ++ init (chain (reverse points))
    chain = reverse . List.foldl' push []
    push (b : a : rest) point
        | orientation a b point <= 0 = push (a : rest) point
    push rest point = point : rest

-- | Extract the planar coordinate pair.
xy :: (Coordinate c) => c -> (Double, Double)
xy coordinate = (x coordinate, y coordinate)

-- | Fold coordinates in stored order. Skip explicit empty points.
foldCoordinates :: (Coordinate c) => (a -> c -> a) -> a -> Geometry c -> a
foldCoordinates step initial geometry = case geometry of
    PointGeometry EmptyPoint -> initial
    PointGeometry (Point coordinate) -> step initial coordinate
    LineString points -> U.foldl' step initial points
    Polygon rings -> V.foldl' (U.foldl' step) initial rings
    MultiPoint points -> U.foldl' (\total point -> case point of EmptyPoint -> total; Point coordinate -> step total coordinate) initial points
    MultiLineString lineStrings -> V.foldl' (U.foldl' step) initial lineStrings
    MultiPolygon polygons -> V.foldl' (V.foldl' (U.foldl' step)) initial polygons
    GeometryCollection children -> V.foldl' (foldCoordinates step) initial children

-- | Fold adjacent pairs and optionally close the path.
foldSegments :: (U.Unbox c) => Bool -> (a -> c -> c -> a) -> a -> U.Vector c -> a
foldSegments close step initial points
    | U.null points = initial
    | otherwise =
        let result = U.ifoldl' (\total i point -> if i == 0 then total else step total (points U.! (i - 1)) point) initial points
         in if close then step result (U.last points) (U.head points) else result

-- | Scale each segment before its square root to avoid intermediate overflow.
segmentWeight :: (Coordinate c) => c -> c -> Rational
segmentWeight a b
    | scale == 0 = 0
    | otherwise = scale * toRational (sqrt (dx * dx + dy * dy))
  where
    deltaX = toRational (x b) - toRational (x a)
    deltaY = toRational (y b) - toRational (y a)
    scale = max (abs deltaX) (abs deltaY)
    dx = fromRational (deltaX / scale) :: Double
    dy = fromRational (deltaY / scale) :: Double

-- | Sum XY segment lengths. Optionally include the final closing segment.
pathLength :: (Coordinate c) => Bool -> U.Vector c -> Double
pathLength close = fromRational . foldSegments close (\total a b -> total + segmentWeight a b) 0

-- | A weight and its two weighted coordinate sums.
type Moments = (Rational, Rational, Rational)

-- | Add contributions to one centroid.
addMoments :: Moments -> Moments -> Moments
addMoments (weight, mx, my) (otherWeight, otherX, otherY) =
    let !total = weight + otherWeight
        !totalX = mx + otherX
        !totalY = my + otherY
     in (total, totalX, totalY)

-- | Calculate twice-area and centroid moments independently of ring winding.
ringMoments :: (Coordinate c) => U.Vector c -> Moments
ringMoments points =
    let (weight, mx, my) = foldSegments True step (0, 0, 0) points
        direction = signum weight
     in (abs weight, direction * mx / 3, direction * my / 3)
  where
    step (!weight, !mx, !my) a b =
        let ax = toRational (x a)
            ay = toRational (y a)
            bx = toRational (x b)
            by = toRational (y b)
            cross = ax * by - bx * ay
         in (weight + cross, mx + (ax + bx) * cross, my + (ay + by) * cross)

-- | Add exterior ring moments and subtract hole moments, regardless of winding.
surfaceMoments :: (Coordinate c) => Geometry c -> Moments
surfaceMoments geometry = case geometry of
    Polygon rings -> V.ifoldl' addRing (0, 0, 0) rings
    MultiPolygon polygons -> V.foldl' (\total rings -> addMoments total (surfaceMoments (Polygon rings))) (0, 0, 0) polygons
    GeometryCollection children -> V.foldl' (\total child -> addMoments total (surfaceMoments child)) (0, 0, 0) children
    _ -> (0, 0, 0)
  where
    addRing total index ring =
        let (weight, mx, my) = ringMoments ring
         in addMoments total (if index == 0 then (weight, mx, my) else (-weight, -mx, -my))

-- | Use segment lengths as weights. Include polygon rings for zero-area fallback.
linearMoments :: (Coordinate c) => Geometry c -> Moments
linearMoments geometry = case geometry of
    LineString points -> path False points
    Polygon rings -> V.foldl' (\total points -> addMoments total (path True points)) (0, 0, 0) rings
    MultiLineString lineStrings -> V.foldl' (\total points -> addMoments total (path False points)) (0, 0, 0) lineStrings
    MultiPolygon polygons -> V.foldl' (\total rings -> addMoments total (linearMoments (Polygon rings))) (0, 0, 0) polygons
    GeometryCollection children -> V.foldl' (\total child -> addMoments total (linearMoments child)) (0, 0, 0) children
    _ -> (0, 0, 0)
  where
    path close = foldSegments close step (0, 0, 0)
    step total a b =
        let weight = segmentWeight a b
            midX = (toRational (x a) + toRational (x b)) / 2
            midY = (toRational (y a) + toRational (y b)) / 2
         in addMoments total (weight, weight * midX, weight * midY)

-- | Return the exact turn determinant for three finite XY points.
orientation :: (Double, Double) -> (Double, Double) -> (Double, Double) -> Rational
orientation (ax, ay) (bx, by) (cx, cy) =
    (toRational bx - toRational ax) * (toRational cy - toRational ay)
        - (toRational by - toRational ay) * (toRational cx - toRational ax)
