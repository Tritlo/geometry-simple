{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}

{- | Simple Features accessors, planar topology, and measurements.

Most names follow OGC Simple Feature Access. Indices start at zero, as in
GEOS. The module exports short names such as 'x' and 'area', so import it
qualified:

> import qualified Data.Geometry.SimpleFeatures as SF

Measurements use only X and Y. Z and M stay available through the accessors.
Envelopes and nonempty centroids use t'XY' coordinates. Convex hulls discard M.

Planar operations require finite X and Y. Measurements use 'Double'
arithmetic and can overflow or underflow. Polygon measurements and binary
spatial operations assume valid topology; use 'isValid' to check it.
Area and perimeter close open rings. Topology uses exact rational segment
intersections and rounds constructed coordinates to 'Double'. Buffers
approximate circular arcs with straight segments.

The module covers the Simple Features core for GEOS's seven geometry families.
The additional surface types and reference systems in OGC SFA are outside its scope.
-}
module Data.Geometry.SimpleFeatures (
    -- * Geometry properties
    geometryType,
    dimension,
    coordinateDimension,
    spatialDimension,
    is3D,
    isMeasured,
    isEmpty,

    -- * Coordinate ordinates
    x,
    y,
    z,
    m,

    -- * Members, points, and rings
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

    -- * Measurements and bounds
    envelope,
    area,
    geometryLength,
    curveLength,
    perimeter,
    centroid,
    convexHull,

    -- * Topology
    boundary,
    isSimple,
    isRing,
    isValid,
    pointOnSurface,

    -- * Spatial relations
    relate,
    relatePattern,
    equals,
    disjoint,
    intersects,
    touches,
    crosses,
    within,
    contains,
    overlaps,
    covers,
    coveredBy,

    -- * Distance and geometry construction
    distance,
    intersection,
    union,
    difference,
    symmetricDifference,
    buffer,
    bufferWithSegments,

    -- * Measured locations
    locateAlong,
    locateBetween,
) where

import Control.Applicative ((<|>))
import Data.Geometry.Internal
import Data.Geometry.Topology.Buffer (buffer, bufferWithSegments)
import Data.Geometry.Topology.Measures (locateAlong, locateBetween)
import Data.Geometry.Topology.Overlay (difference, intersection, symmetricDifference, union)
import Data.Geometry.Topology.Relations (contains, coveredBy, covers, crosses, disjoint, distance, equals, intersects, overlaps, relate, relatePattern, touches, within)
import Data.Geometry.Topology.Unary (boundary, isRing, isSimple, isValid, pointOnSurface)
import qualified Data.List as List
import Data.Maybe (fromMaybe)
import Data.Proxy (Proxy (..))
import qualified Data.Vector as V
import qualified Data.Vector.Unboxed as U

-- | The uppercase WKT family name, such as @POLYGON@, without a dimension tag.
geometryType :: Geometry -> String
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
dimension :: Geometry -> Int
dimension = topologicalDimension

{- | The largest number of ordinates in any stored point or sequence: 2, 3,
or 4. XYZ and XYM members together give 3, even though both
'is3D' and 'isMeasured' are true. Atomic empty geometries retain their layout.
Collections without atomic members report 2.
-}
coordinateDimension :: Geometry -> Int
coordinateDimension = geometryCoordinateDimension

-- | The number of spatial ordinates: 3 when 'is3D' is true, or 2 otherwise.
spatialDimension :: Geometry -> Int
spatialDimension geometry = if is3D geometry then 3 else 2

-- | Whether the geometry's coordinate layout has Z. See 'coordinateDimension'.
is3D :: Geometry -> Bool
is3D geometry = geometryDimensions geometry `elem` [DimXYZ, DimXYZM]

-- | Whether the geometry's coordinate layout has M. See 'coordinateDimension'.
isMeasured :: Geometry -> Bool
isMeasured geometry = geometryDimensions geometry `elem` [DimXYM, DimXYZM]

-- | Whether the geometry has no coordinates. A collection of empty members is empty.
isEmpty :: Geometry -> Bool
isEmpty = geometryEmpty

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
numGeometries :: Geometry -> Int
numGeometries geometry = case geometry of
    MultiPoint points -> U.length points
    MultiLineString lineStrings -> V.length lineStrings
    MultiPolygon polygons -> V.length polygons
    GeometryCollection children -> V.length children
    _ -> 1

{- | The direct member at a zero-based index, or 'Nothing' when the index is out
of range. A geometry that is not a collection is its own first member.
-}
geometryN :: Int -> Geometry -> Maybe Geometry
geometryN index geometry = case geometry of
    MultiPoint points -> PointGeometry <$> points U.!? index
    MultiLineString lineStrings -> LineString <$> lineStrings V.!? index
    MultiPolygon polygons -> Polygon <$> polygons V.!? index
    GeometryCollection children -> children V.!? index
    _ -> if index == 0 then Just geometry else Nothing

-- | The number of coordinates in a 'LineString'. Other families give 'Nothing'.
numPoints :: Geometry -> Maybe Int
numPoints (LineString points) = Just (withCoordinates U.length points)
numPoints _ = Nothing

{- | The 'LineString' point at a zero-based index. Return 'Nothing' for an
index out of range or another geometry family. Omit NaN Z and M ordinates
from the returned point's layout.
-}
pointN :: Int -> Geometry -> Maybe Point
pointN index (LineString points) = withCoordinates (\values -> coordinatePoint <$> values U.!? index) points
pointN _ _ = Nothing

-- | Construct a point with the non-NaN Z and M ordinates of a coordinate.
coordinatePoint :: (Coordinate c) => c -> Point
coordinatePoint coordinate = case (z coordinate, m coordinate) of
    (Just elevation, Just measure) | not (isNaN elevation || isNaN measure) -> PointXYZM (XYZM a b elevation measure)
    (Just elevation, _) | not (isNaN elevation) -> PointXYZ (XYZ a b elevation)
    (_, Just measure) | not (isNaN measure) -> PointXYM (XYM a b measure)
    _ -> PointXY (XY a b)
  where
    (a, b) = xy coordinate

-- | The first point of a 'LineString', or 'Nothing' for an empty line or another family.
startPoint :: Geometry -> Maybe Point
startPoint = pointN 0

-- | The last point of a 'LineString', or 'Nothing' for an empty line or another family.
endPoint :: Geometry -> Maybe Point
endPoint geometry@(LineString points) = pointN (withCoordinates U.length points - 1) geometry
endPoint _ = Nothing

{- | Whether a nonempty 'LineString' starts and ends at the same XY position.
A 'MultiLineString' is closed when it has lines and all of them are closed.
Other families give 'False'. The test does not check whether a line is simple.
-}
isClosed :: Geometry -> Bool
isClosed geometry = case geometry of
    LineString points -> withCoordinates closed points
    MultiLineString lineStrings -> not (V.null lineStrings) && V.all (withCoordinates closed) lineStrings
    _ -> False
  where
    closed points = not (U.null points) && xy (U.head points) == xy (U.last points)

-- | The exterior ring of a 'Polygon', including its empty layout. Other families give 'Nothing'.
exteriorRing :: Geometry -> Maybe Coordinates
exteriorRing (Polygon (PolygonRings shell _)) = Just shell
exteriorRing _ = Nothing

-- | The number of holes in a 'Polygon'. Other families give 'Nothing'.
numInteriorRings :: Geometry -> Maybe Int
numInteriorRings (Polygon (PolygonRings _ holes)) = Just (V.length holes)
numInteriorRings _ = Nothing

{- | The 'Polygon' hole at a zero-based index. Index 0 is the first hole.
Return 'Nothing' for an index out of range or another geometry family.
-}
interiorRingN :: Int -> Geometry -> Maybe Coordinates
interiorRingN index (Polygon (PolygonRings _ holes)) = holes V.!? index
interiorRingN _ _ = Nothing

{- | The smallest XY bounding rectangle, as a counterclockwise 'Polygon'.
Empty input gives an empty point. A single XY location gives a point.
Horizontal and vertical bounds give a polygon with repeated corners.
-}
envelope :: Geometry -> Geometry
envelope geometry
    | minX > maxX = PointGeometry (EmptyPoint DimXY)
    | minX == maxX && minY == maxY = PointGeometry (PointXY (XY minX minY))
    | otherwise = Polygon (PolygonRings (CoordinatesXY (U.fromList [XY minX minY, XY maxX minY, XY maxX maxY, XY minX maxY, XY minX minY])) V.empty)
  where
    -- An inverted infinite box remains inverted when there are no coordinates.
    (minX, minY, maxX, maxY) = foldCoordinates extend (infinity, infinity, -infinity, -infinity) geometry
    infinity = 1 / 0
    extend (!left, !bottom, !right, !top) coordinate =
        (min left (x coordinate), min bottom (y coordinate), max right (x coordinate), max top (y coordinate))

{- | The total polygon area in square coordinate units. The first ring of each
polygon is the exterior, and the other rings are holes. Ring orientation does
not matter. Other families add zero. The cross products of each ring use its
first vertex as the origin, which limits cancellation far from zero.
-}
area :: Geometry -> Double
area geometry = let (weight, _, _) = surfaceMoments (0, 0) geometry in weight / 2

-- | The total XY length of lines and polygon boundaries, including holes.
geometryLength :: Geometry -> Double
geometryLength geometry = curveLength geometry + perimeter geometry

{- | The total length of all lines, including lines in collections, in coordinate
units. Polygon boundaries and points add zero.
-}
curveLength :: Geometry -> Double
curveLength geometry = case geometry of
    LineString points -> withCoordinates (pathLength False) points
    MultiLineString lineStrings -> V.foldl' (\total points -> total + withCoordinates (pathLength False) points) 0 lineStrings
    GeometryCollection children -> V.foldl' (\total child -> total + curveLength child) 0 children
    _ -> 0

-- | The total length of all polygon rings, including holes. Lines and points add zero.
perimeter :: Geometry -> Double
perimeter geometry = case geometry of
    Polygon (PolygonRings shell holes) -> V.foldl' (\total points -> total + withCoordinates (pathLength True) points) (withCoordinates (pathLength True) shell) holes
    MultiPolygon polygons -> V.foldl' (\total rings -> total + perimeter (Polygon rings)) 0 polygons
    GeometryCollection children -> V.foldl' (\total child -> total + perimeter child) 0 children
    _ -> 0

{- | The XY centroid, or 'EmptyPoint' for empty input. An empty result uses XY,
XYZ, or XYZM when 'coordinateDimension' is 2, 3, or 4. Polygons are weighted by
area. If the total area is zero, segments are weighted by length. If all
segments have zero length, the result is the mean of the points, and each
line or ring counts as one point at its first coordinate, as in GEOS.
Lower-dimensional parts do not affect a higher-dimensional centroid.
The centroid can be outside the geometry, for example in a hole.

Compensated sums retain small contributions when large moments cancel.
Polygon positions and local moments stay separate until summation. Moments
can overflow when a polygon spans more than about 1e100 units or a line more
than about 1e150 units. They can underflow below about 1e-100 units for polygons
or 1e-150 units for lines. Products still round to 'Double'. Strong cancellation
between products can reduce accuracy even when all intermediate values are finite.
-}
centroid :: Geometry -> Point
centroid geometry = fromMaybe (EmptyPoint emptyDimensions) (weightedMean 2 <|> weightedMean 1 <|> weightedMean 0)
  where
    emptyDimensions = case coordinateDimension geometry of
        3 -> DimXYZ
        4 -> DimXYZM
        _ -> DimXY
    weightedMean dimensionToMeasure =
        let (weight, mx, my) = moments dimensionToMeasure 1
         in if weight == 0
                then Nothing
                else
                    if finite mx && finite my
                        then Just (PointXY (XY (mx / weight) (my / weight)))
                        else
                            -- Normalize before summation only when raw moments overflow.
                            let (_, normalizedX, normalizedY) = moments dimensionToMeasure weight
                             in Just (PointXY (XY (if finite mx then mx / weight else normalizedX) (if finite my then my / weight else normalizedY)))
    moments dimensionToMeasure divisor =
        let CentroidMoments w wc mx mxc my myc = foldCentroidMoments dimensionToMeasure divisor (CentroidMoments 0 0 0 0 0 0) geometry
         in (compensatedValue (w, wc), compensatedValue (mx, mxc), compensatedValue (my, myc))

{- | The convex hull, from Andrew's monotone chain algorithm. The result is
an empty XY collection, a point, a line, or a clockwise polygon. M is discarded.
The first output vertex determines the layout: XYZ when its Z is not NaN, or
XY otherwise. Missing Z values become NaN in an XYZ hull. Polygon rings start
at the lowest Y, then X. Two unique positions retain their input order.
For duplicate XY positions, keep the first coordinate. GEOS can select another
duplicate in large collinear inputs. The orientation tests are exact.
-}
convexHull :: Geometry -> Geometry
convexHull geometry = hullGeometry hull
  where
    coordinates = reverse (foldCoordinates (\rest coordinate -> XYZ (x coordinate) (y coordinate) (fromMaybe (0 / 0) (z coordinate)) : rest) [] geometry)
    points = [point | point : _ <- List.groupBy sameXY (List.sortBy compareXY coordinates)]
    sameXY a b = xy a == xy b
    compareXY a b = compare (xy a) (xy b)
    compareYX a b = compare (y a, x a) (y b, x b)
    hull = case points of
        [] -> []
        [point] -> [point]
        [a, b] -> case coordinates of
            first : _ | sameXY first b -> [b, a]
            _ -> [a, b]
        _ -> rotate (reverse (init (chain points) ++ init (chain (reverse points))))
    chain = reverse . List.foldl' push []
    push (b : a : rest) point
        | orientation (xy a) (xy b) (xy point) /= GT = push (a : rest) point
    push rest point = point : rest
    rotate [] = []
    rotate vertices =
        let first = List.minimumBy compareYX vertices
            (before, after) = break (sameXY first) vertices
         in after ++ before

-- | Construct a hull with the layout selected by its first vertex.
hullGeometry :: [XYZ] -> Geometry
hullGeometry [] = GeometryCollection V.empty
hullGeometry points@(first@(XYZ a b elevation) : _) = case points of
    [_] -> PointGeometry (if hasZ then PointXYZ first else PointXY (XY a b))
    [_, _] -> LineString (coordinates points)
    _ -> Polygon (PolygonRings (coordinates (points ++ take 1 points)) V.empty)
  where
    hasZ = not (isNaN elevation)
    coordinates values
        | hasZ = CoordinatesXYZ (U.fromList values)
        | otherwise = CoordinatesXY (U.fromList [XY u v | XYZ u v _ <- values])

-- | Extract the planar coordinate pair.
xy :: (Coordinate c) => c -> (Double, Double)
xy coordinate = (x coordinate, y coordinate)

-- | Fold coordinates in stored order. Skip explicit empty points.
foldCoordinates :: (forall c. (Coordinate c) => a -> c -> a) -> a -> Geometry -> a
foldCoordinates step initial geometry = case geometry of
    PointGeometry point -> fromMaybe initial (withPoint (step initial) point)
    LineString points -> sequenceFold initial points
    Polygon rings -> polygonFold initial rings
    MultiPoint points -> U.foldl' (\total point -> fromMaybe total (withPoint (step total) point)) initial points
    MultiLineString lineStrings -> V.foldl' sequenceFold initial lineStrings
    MultiPolygon polygons -> V.foldl' polygonFold initial polygons
    GeometryCollection children -> V.foldl' (foldCoordinates step) initial children
  where
    sequenceFold total = withCoordinates (U.foldl' step total)
    polygonFold total (PolygonRings shell holes) = V.foldl' sequenceFold (sequenceFold total shell) holes

-- | Fold adjacent pairs and optionally close the path.
foldSegments :: (U.Unbox c) => Bool -> (a -> c -> c -> a) -> a -> U.Vector c -> a
foldSegments close step initial points
    | U.null points = initial
    | otherwise =
        let result = U.foldl' (\total (a, b) -> step total a b) initial (U.zip points (U.tail points))
         in if close then step result (U.last points) (U.head points) else result

{- | The XY distance. Scale before the square root so that the squares cannot
overflow or underflow.
-}
segmentLength :: (Coordinate c) => c -> c -> Double
segmentLength a b
    | large == 0 = 0
    | otherwise = large * sqrt (1 + ratio * ratio)
  where
    deltaX = abs (x b - x a)
    deltaY = abs (y b - y a)
    large = max deltaX deltaY
    ratio = min deltaX deltaY / large

-- | Sum XY segment lengths. Optionally include the final closing segment.
pathLength :: (Coordinate c) => Bool -> U.Vector c -> Double
pathLength close = foldSegments close (\total a b -> total + segmentLength a b) 0

-- | A weight and the weighted X and Y offsets from an origin.
type Moments = (Double, Double, Double)

-- | Add contributions to one centroid.
addMoments :: Moments -> Moments -> Moments
addMoments (weight, mx, my) (otherWeight, otherX, otherY) =
    let !total = weight + otherWeight
        !totalX = mx + otherX
        !totalY = my + otherY
     in (total, totalX, totalY)

{- | Calculate twice the ring area and its moments about an origin, whatever
the ring winding. The cross products use the first ring vertex as a local
origin, which limits cancellation far from zero.
-}
ringMoments :: (Coordinate c) => (Double, Double) -> U.Vector c -> Moments
ringMoments (originX, originY) ring
    | U.null ring = (0, 0, 0)
    | otherwise =
        let (weight, mx, my) = foldSegments True step (0, 0, 0) ring
            size = abs weight
            direction = signum weight
         in (size, size * (baseX - originX) + direction * mx / 3, size * (baseY - originY) + direction * my / 3)
  where
    (baseX, baseY) = xy (U.head ring)
    step (!weight, !mx, !my) a b =
        let ax = x a - baseX
            ay = y a - baseY
            bx = x b - baseX
            by = y b - baseY
            cross = ax * by - bx * ay
         in (weight + cross, mx + (ax + bx) * cross, my + (ay + by) * cross)

-- | Add exterior ring moments and subtract hole moments, regardless of winding.
surfaceMoments :: (Double, Double) -> Geometry -> Moments
surfaceMoments origin geometry = case geometry of
    Polygon (PolygonRings shell holes) -> V.foldl' subtractRing (withCoordinates (ringMoments origin) shell) holes
    MultiPolygon polygons -> V.foldl' (\total rings -> addMoments total (surfaceMoments origin (Polygon rings))) (0, 0, 0) polygons
    GeometryCollection children -> V.foldl' (\total child -> addMoments total (surfaceMoments origin child)) (0, 0, 0) children
    _ -> (0, 0, 0)
  where
    subtractRing total ring =
        let (weight, mx, my) = withCoordinates (ringMoments origin) ring
         in addMoments total (-weight, -mx, -my)

-- | A sum and the rounding error retained by Neumaier summation.
type Compensated = (Double, Double)

-- | Strict sums and corrections for the weight, X moment, and Y moment.
data CentroidMoments = CentroidMoments !Double !Double !Double !Double !Double !Double

-- | Add one value without discarding small terms when larger terms cancel.
addCompensated :: Compensated -> Double -> Compensated
{-# INLINE addCompensated #-}
addCompensated (total, correction) value =
    let !next = total + value
        !errorTerm = if abs total >= abs value then (total - next) + value else (value - next) + total
        !nextCorrection = correction + errorTerm
     in (next, nextCorrection)

-- | Include the retained rounding error in the result.
compensatedValue :: Compensated -> Double
compensatedValue (total, correction) = total + correction

{- | Fold weights and separate moment contributions for one centroid dimension.
Keep polygon bases separate from local moments, and keep segment endpoints
separate. Rounding their absolute centroids first would discard small offsets.
The divisor scales moments on the overflow retry. Weights stay unscaled.
-}
foldCentroidMoments :: Int -> Double -> CentroidMoments -> Geometry -> CentroidMoments
{-# INLINE foldCentroidMoments #-}
foldCentroidMoments dimensionToMeasure divisor = go
  where
    go initial geometry = case geometry of
        PointGeometry point | dimensionToMeasure == 0 -> fromMaybe initial (withPoint (single initial) point)
        LineString points -> case dimensionToMeasure of
            1 -> withCoordinates (foldSegments False segment initial) points
            0 -> first initial points
            _ -> initial
        Polygon rings@(PolygonRings shell holes) -> case dimensionToMeasure of
            2 -> surface initial rings
            1 -> V.foldl' path (path initial shell) holes
            _ -> V.foldl' first (first initial shell) holes
        MultiPoint points | dimensionToMeasure == 0 -> U.foldl' (\total point -> fromMaybe total (withPoint (single total) point)) initial points
        MultiLineString lineStrings -> V.foldl' (\total points -> recurse total (LineString points)) initial lineStrings
        MultiPolygon polygons -> V.foldl' (\total rings -> recurse total (Polygon rings)) initial polygons
        GeometryCollection children -> V.foldl' recurse initial children
        _ -> initial
    recurse = go
    step (CentroidMoments w wc mx mxc my myc) a b c =
        let (w', wc') = addCompensated (w, wc) a
            (mx', mxc') = addCompensated (mx, mxc) b
            (my', myc') = addCompensated (my, myc) c
         in CentroidMoments w' wc' mx' mxc' my' myc'
    single total coordinate = step total 1 (x coordinate / divisor) (y coordinate / divisor)
    -- A zero-length line or ring counts as one point in the point fallback.
    first total = withCoordinates (\points -> maybe total (single total) (points U.!? 0))
    path total = withCoordinates (foldSegments True segment total)
    segment total a b
        | weight == 0 = total
        | otherwise = step (step total weight (factor * x a) (factor * y a)) 0 (factor * x b) (factor * y b)
      where
        weight = segmentLength a b
        factor = (weight / divisor) / 2
    surface total rings@(PolygonRings shell _) = case withCoordinates (\points -> xy <$> points U.!? 0) shell of
        Nothing -> total
        Just (baseX, baseY) ->
            -- Subtract holes locally before multiplying by the polygon position.
            let (weight, mx, my) = surfaceMoments (baseX, baseY) (Polygon rings)
                factor = weight / divisor
             in if weight == 0 then total else step (step total weight (factor * baseX) (factor * baseY)) 0 (mx / divisor) (my / divisor)

{- | The turn of three XY points: 'GT' for counterclockwise, 'LT' for clockwise,
and 'EQ' for collinear. Use the Double determinant when its error bound
decides the sign (Shewchuk 1997). Otherwise use exact Rational arithmetic.
-}
orientation :: (Double, Double) -> (Double, Double) -> (Double, Double) -> Ordering
orientation (ax, ay) (bx, by) (cx, cy)
    | magnitude >= 9.332636185032189e-302 && abs determinant > 4.440892098500626e-16 * magnitude = compare determinant 0
    | otherwise = compare exact 0
  where
    left = (bx - ax) * (cy - ay)
    right = (by - ay) * (cx - ax)
    determinant = left - right
    -- The bound 2^-51 * magnitude exceeds the rounding error of the
    -- determinant. The limit 2^-1000 also covers products that underflow.
    -- Overflow gives NaN or infinity, which fail both tests.
    magnitude = abs left + abs right
    exact =
        (toRational bx - toRational ax) * (toRational cy - toRational ay)
            - (toRational by - toRational ay) * (toRational cx - toRational ax)
