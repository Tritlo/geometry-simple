{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE ScopedTypeVariables #-}

{- | Pure properties, accessors, and planar measurements for Simple Features.

Operations use Cartesian XY coordinates. Z and M remain available through
accessors. Computed geometries use @XY@. Component indices start at one.

Planar operations require finite X and Y ordinates. Polygon measurements
require valid topology. Rings are closed implicitly for area and perimeter.
These functions do not validate topology. Use the @geos@ package for spatial
predicates, validity checks, distance, boundaries, buffers, and polygon set
operations.
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

-- | Return the uppercase WKT family name without a coordinate suffix.
geometryType :: Geometry c -> String
geometryType geometry = case geometry of
    PointGeometry _ -> "POINT"
    LineString _ -> "LINESTRING"
    Polygon _ -> "POLYGON"
    MultiPoint _ -> "MULTIPOINT"
    MultiLineString _ -> "MULTILINESTRING"
    MultiPolygon _ -> "MULTIPOLYGON"
    GeometryCollection _ -> "GEOMETRYCOLLECTION"

{- | Return the family's topological dimension, including for empty values.
Collections use the maximum child dimension. An empty collection returns -1.
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

-- | Return the number of ordinates, including Z and M when present.
coordinateDimension :: forall c. (Coordinate c) => Geometry c -> Int
coordinateDimension _ = case coordinateDimensions (Proxy :: Proxy c) of
    DimXY -> 2
    DimXYZM -> 4
    _ -> 3

-- | Return two for XY and XYM, or three for XYZ and XYZM.
spatialDimension :: (Coordinate c) => Geometry c -> Int
spatialDimension geometry = if is3D geometry then 3 else 2

-- | Test whether the coordinate layout includes Z, including for empty values.
is3D :: forall c. (Coordinate c) => Geometry c -> Bool
is3D _ = coordinateDimensions (Proxy :: Proxy c) `elem` [DimXYZ, DimXYZM]

-- | Test whether the coordinate layout includes M, including for empty values.
isMeasured :: forall c. (Coordinate c) => Geometry c -> Bool
isMeasured _ = coordinateDimensions (Proxy :: Proxy c) `elem` [DimXYM, DimXYZM]

-- | Test whether the geometry has no coordinates. Inspect collection children.
isEmpty :: (Coordinate c) => Geometry c -> Bool
isEmpty geometry = case geometry of
    PointGeometry point -> point == EmptyPoint
    LineString points -> U.null points
    Polygon rings -> V.all U.null rings
    MultiPoint points -> U.all (== EmptyPoint) points
    MultiLineString lineStrings -> V.all U.null lineStrings
    MultiPolygon polygons -> V.all (V.all U.null) polygons
    GeometryCollection children -> V.all isEmpty children

-- | Return the X ordinate.
x :: (Coordinate c) => c -> Double
x coordinate = let (value, _, _, _) = coordinateComponents coordinate in value

-- | Return the Y ordinate.
y :: (Coordinate c) => c -> Double
y coordinate = let (_, value, _, _) = coordinateComponents coordinate in value

-- | Return the Z ordinate when the coordinate layout includes it.
z :: forall c. (Coordinate c) => c -> Maybe Double
z coordinate = case coordinateDimensions (Proxy :: Proxy c) of
    DimXYZ -> Just value
    DimXYZM -> Just value
    _ -> Nothing
  where
    (_, _, value, _) = coordinateComponents coordinate

-- | Return the M ordinate when the coordinate layout includes it.
m :: forall c. (Coordinate c) => c -> Maybe Double
m coordinate = case coordinateDimensions (Proxy :: Proxy c) of
    DimXYM -> Just value
    DimXYZM -> Just value
    _ -> Nothing
  where
    (_, _, _, value) = coordinateComponents coordinate

{- | Count immediate collection members, including empty members.
An atomic geometry counts as one, including an empty atomic geometry.
-}
numGeometries :: (Coordinate c) => Geometry c -> Int
numGeometries geometry = case geometry of
    MultiPoint points -> U.length points
    MultiLineString lineStrings -> V.length lineStrings
    MultiPolygon polygons -> V.length polygons
    GeometryCollection children -> V.length children
    _ -> 1

{- | Select an immediate member by its one-based index.
An atomic geometry has one member: itself. Invalid indices return 'Nothing'.
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

-- | Count coordinates in a LineString. Other families return 'Nothing'.
numPoints :: (Coordinate c) => Geometry c -> Maybe Int
numPoints (LineString points) = Just (U.length points)
numPoints _ = Nothing

-- | Select a LineString coordinate by its one-based index.
pointN :: (Coordinate c) => Int -> Geometry c -> Maybe c
pointN index (LineString points)
    | index >= 1 = points U.!? (index - 1)
pointN _ _ = Nothing

-- | Return the first LineString coordinate, or 'Nothing' for other or empty values.
startPoint :: (Coordinate c) => Geometry c -> Maybe c
startPoint = pointN 1

-- | Return the last LineString coordinate, or 'Nothing' for other or empty values.
endPoint :: (Coordinate c) => Geometry c -> Maybe c
endPoint (LineString points) = points U.!? (U.length points - 1)
endPoint _ = Nothing

{- | Test XY closure of a nonempty LineString or MultiLineString.
Every line in a MultiLineString must be nonempty and closed. Other families
return 'False'. Closure does not test whether a line is simple.
-}
isClosed :: (Coordinate c) => Geometry c -> Bool
isClosed geometry = case geometry of
    LineString points -> closed points
    MultiLineString lineStrings -> not (V.null lineStrings) && V.all closed lineStrings
    _ -> False
  where
    closed points = not (U.null points) && xy (U.head points) == xy (U.last points)

-- | Return a Polygon's exterior ring, or 'Nothing' when no ring is present.
exteriorRing :: Geometry c -> Maybe (U.Vector c)
exteriorRing (Polygon rings) = rings V.!? 0
exteriorRing _ = Nothing

-- | Count a Polygon's holes. Other families return 'Nothing'.
numInteriorRings :: Geometry c -> Maybe Int
numInteriorRings (Polygon rings) = Just (max 0 (V.length rings - 1))
numInteriorRings _ = Nothing

-- | Select a Polygon hole by its one-based index. The exterior ring is excluded.
interiorRingN :: Int -> Geometry c -> Maybe (U.Vector c)
interiorRingN index (Polygon rings)
    | index >= 1 = rings V.!? index
interiorRingN _ _ = Nothing

{- | Return the minimum XY bounding rectangle.
Empty input returns an empty collection. Degenerate bounds return a point
or a two-point line.
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

{- | Sum polygon areas in square coordinate units. Subtract holes by position.
Ring orientation does not affect the result. Other families contribute zero.
Use exact cross products before conversion to Double to avoid cancellation.
-}
area :: (Coordinate c) => Geometry c -> Double
area geometry = let (weight, _, _) = surfaceMoments geometry in fromRational (weight / 2)

{- | Sum LineString lengths in coordinate units, including collection children.
Polygon boundaries and points contribute zero. Z and M do not affect length.
-}
curveLength :: (Coordinate c) => Geometry c -> Double
curveLength geometry = case geometry of
    LineString points -> pathLength False points
    MultiLineString lineStrings -> V.foldl' (\total points -> total + pathLength False points) 0 lineStrings
    GeometryCollection children -> V.foldl' (\total child -> total + curveLength child) 0 children
    _ -> 0

-- | Sum polygon ring lengths, including holes. Lines and points contribute zero.
perimeter :: (Coordinate c) => Geometry c -> Double
perimeter geometry = case geometry of
    Polygon rings -> V.foldl' (\total points -> total + pathLength True points) 0 rings
    MultiPolygon polygons -> V.foldl' (\total rings -> total + perimeter (Polygon rings)) 0 polygons
    GeometryCollection children -> V.foldl' (\total child -> total + perimeter child) 0 children
    _ -> 0

{- | Return the centroid in XY. Empty input returns 'EmptyPoint'.
Use polygon area weights when nonzero. Otherwise use segment length weights,
then coordinate counts if all segments have zero length. Lower-dimensional
components do not affect a higher-dimensional centroid. A centroid can lie
outside the geometry, including inside a polygon hole.
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

{- | Compute the XY convex hull with the monotone chain algorithm.
Return an empty collection, point, line, or counterclockwise polygon according
to the hull dimension. Ignore duplicate XY coordinates and interior collinear
vertices. Exact orientation tests avoid floating-point cancellation.
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
