{- | Round planar buffers with polygonal approximations of circular arcs.

The arc and corner rules follow GEOS 3.13.1. See
<https://github.com/libgeos/geos/blob/3.13.1/src/operation/buffer/OffsetSegmentGenerator.cpp OffsetSegmentGenerator>.
The relative distance thresholds below match that implementation.
-}
module Data.Geometry.Topology.Buffer (buffer, bufferWithSegments) where

import Data.Geometry.Internal
import Data.Geometry.Topology.Overlay
import Data.Geometry.Topology.Planar
import Data.List (group)
import qualified Data.Vector as V

{- | Buffer by a distance in coordinate units, with eight segments per quadrant.
Positive distances expand geometry. Negative distances erode polygons and give
empty polygons for points and lines. All results use XY coordinates.
A zero distance returns polygon components and repairs their topology.
The distance and XY coordinates must be finite.
-}
buffer :: Double -> Geometry -> Geometry
buffer = bufferWithSegments 8

{- | Construct a round buffer with the requested number of segments per quadrant.
Values below one use one segment. The distance and XY coordinates must be finite.
The distance and coordinate-layout rules are the same as for 'buffer'.
-}
bufferWithSegments :: Int -> Double -> Geometry -> Geometry
bufferWithSegments quadrants radius geometry = assemble SurfaceDimension (polygonize boundary) [] []
  where
    count = max 1 quadrants
    width = abs radius
    source = planar geometry
    surfaces = Planar [] [] (planarPolygons source)
    rings = (if radius > 0 then concatMap (lineBuffer count width) (planarLines source) else []) ++ [circle count width (toDouble p) | radius > 0, p <- planarPoints source]
    bands = Planar [] [] [[map toExact ring] | ring <- rings]
    offsetRings = concatMap (offsetPolygon count radius) (planarPolygons source)
    edges = nodeSegments ((if radius /= 0 then concatMap ringSegments offsetRings else segments surfaces) ++ (if radius == 0 then [] else segments bands)) []
    selected p
        | radius == 0 = any ((> 0) . polygonDepth p) (planarPolygons source)
        | otherwise = sum (map (winding p) (offsetRings ++ map (map toExact) rings)) < 0
    boundary =
        [ if leftInside then (a, b) else (b, a)
        | edge@(a, b) <- edges
        , let (left, right) = sidePoints edges edge
        , let leftInside = selected left
        , leftInside /= selected right
        ]

-- | Count directed boundary crossings around a point.
winding :: Position -> [Position] -> Int
winding point@(_, y) ring = sum (map crossing (ringSegments ring))
  where
    crossing (a@(_, ay), b@(_, by))
        | ay <= y && by > y && orientation a b point == GT = 1
        | by <= y && ay > y && orientation a b point == LT = -1
        | otherwise = 0

-- | Apply shell and hole orientation to preserve GEOS repair semantics.
polygonDepth :: Position -> [[Position]] -> Int
polygonDepth _ [] = 0
polygonDepth point (shell : holes) = depth shell - sum (map depth holes)
  where
    depth ring = (if ringArea ring > 0 then 1 else -1) * winding point ring

{- | Offset shells clockwise and holes counterclockwise, with interior on the right.
GEOS discards inverted erosion curves whose samples all lie within 0.99 of
the requested radius from the source boundary. See
<https://github.com/libgeos/geos/blob/3.13.1/src/operation/buffer/BufferCurveSetBuilder.cpp#L418 BufferCurveSetBuilder>.
-}
offsetPolygon :: Int -> Double -> [[Position]] -> [[Position]]
offsetPolygon _ _ [] = []
offsetPolygon count distance (shell : holes)
    | distance < 0 && (eroded shell || inverted shell shellCurve) = []
    | otherwise = shellCurve : [curve | hole <- holes, distance < 0 || not (eroded hole), let curve = offset (distance > 0) hole, distance < 0 || not (inverted hole curve)]
  where
    radius = abs distance
    shellCurve = offset (distance < 0) shell
    offset ccw ring =
        let flipped = (ringArea ring > 0) /= ccw
            simplified = simplify (if flipped then LT else GT) (radius / 100) (map toDouble ring)
            input = if flipped then reverse simplified else simplified
            curve = map toExact (offsetRing count radius flipped input)
         in if distance < 0 then reverse curve else curve
    eroded [] = True
    eroded ring
        | length (unique ring) == 3 = radius > fromRational (abs (ringArea ring)) / sum [let (x, y) = toDouble (subtractPosition b a) in sqrt (x * x + y * y) | (a, b) <- ringSegments ring]
        | otherwise =
            let xs = map fst ring
                ys = map snd ring
             in 2 * toRational radius > min (maximum xs - minimum xs) (maximum ys - minimum ys)
    inverted ring curve = not (any farEnough (curve ++ map midpoint (ringSegments curve)))
      where
        farEnough point = all ((> toRational (0.99 * radius) ^ (2 :: Int)) . segmentDistanceSquared point) (ringSegments ring)

-- | The squared exact distance from a point to a segment.
segmentDistanceSquared :: Position -> Segment -> Rational
segmentDistanceSquared point (a, b)
    | a == b = dot offset offset
    | otherwise = dot residual residual
  where
    delta = subtractPosition b a
    offset = subtractPosition point a
    t = max 0 (min 1 (dot offset delta / dot delta delta))
    residual = subtractPosition offset (scalePosition t delta)
    dot (x, y) (u, v) = x * u + y * v

-- | Build a connected left offset curve before resolving its self-intersections.
offsetRing :: Int -> Double -> Bool -> [FloatingPosition] -> [FloatingPosition]
offsetRing count radius flipped original = case points of
    [] -> []
    [p] -> circle count radius p
    _ -> close (separate radius (concatMap (offsetCorner count radius flipped) (zip3 (last points : init points) points (drop 1 points ++ take 1 points))))
  where
    uniquePoints = [p | p : _ <- group original]
    points = case uniquePoints of
        first : _ | first == last uniquePoints -> init uniquePoints
        _ -> uniquePoints

{- | Join two left offset segments, rounding convex turns and trimming concave turns.
The 1e-3 relative separation and 80:1 inside-corner connector match GEOS.
-}
offsetCorner :: Int -> Double -> Bool -> (FloatingPosition, FloatingPosition, FloatingPosition) -> [FloatingPosition]
offsetCorner count radius flipped (a, b, c)
    | turn == LT && separation < radius * 1e-3 = [end]
    | turn == LT = arc count radius b before after True
    | turn == EQ = if (a < b) /= (b < c) then arc count radius b before after (not flipped) else []
    | otherwise = case segmentIntersection (toExact (plus a before), toExact end) (toExact start, toExact (plus c after)) of
        p : _ -> [toDouble p]
        [] -> if separation < radius * 1e-3 then [end] else [end, toward end, toward start, start]
  where
    turn = orientation (toExact a) (toExact b) (toExact c)
    before = normal radius a b
    after = normal radius b c
    end = plus b before
    start = plus b after
    separation = pointDistance end start
    factor = if count >= 8 then 80 else 1
    toward (x, y) = let (u, v) = b in ((factor * x + u) / (factor + 1), (factor * y + v) / (factor + 1))

-- | Construct one connected outline for an open line, or two offsets for a ring.
lineBuffer :: Int -> Double -> [Position] -> [[FloatingPosition]]
lineBuffer count radius original = case points of
    [] -> []
    [point] -> [circle count radius point]
    first : _ : _
        | first == last points -> map (map toDouble) (offsetPolygon count radius [map toExact points, map toExact points])
        | otherwise -> [close (separate radius (leftSide leftPath ++ cap leftPath ++ leftSide rightPath ++ cap rightPath))]
      where
        leftPath = simplify GT (radius / 100) points
        rightPath = reverse (simplify LT (radius / 100) points)
        cap path =
            let final = last path
                penultimate = path !! (length path - 2)
                endNormal = normal radius penultimate final
             in arc count radius final endNormal (opposite endNormal) True
  where
    points = [point | point : _ <- group (map toDouble original)]
    leftSide path@(_ : _ : _) =
        concatMap (offsetCorner count radius False) (zip3 path (drop 1 path) (drop 2 path))
            ++ [plus (last path) (normal radius (path !! (length path - 2)) (last path))]
    leftSide _ = []

-- | Match GEOS's minimum vertex separation of 1e-4 times the buffer radius.
separate :: Double -> [FloatingPosition] -> [FloatingPosition]
separate _ [] = []
separate radius (first : rest) = first : go first rest
  where
    go _ [] = []
    go previous (point : points)
        | pointDistance previous point < radius * 1e-4 = go previous points
        | otherwise = point : go point points

-- | The Euclidean distance used by native buffer vertex thresholds.
pointDistance :: FloatingPosition -> FloatingPosition -> Double
pointDistance (x, y) (u, v) = sqrt ((x - u) * (x - u) + (y - v) * (y - v))

{- | Remove shallow concave vertices in the same directed passes as GEOS.
GEOS uses a tolerance of radius / 100. See
<https://github.com/libgeos/geos/blob/3.13.1/src/operation/buffer/BufferInputLineSimplifier.cpp BufferInputLineSimplifier>.
-}
simplify :: Ordering -> Double -> [FloatingPosition] -> [FloatingPosition]
simplify direction tolerance points = map (input V.!) (repeatPass [0 .. V.length input - 1])
  where
    input = V.fromList points
    exact index = toExact (input V.! index)
    threshold = toRational tolerance ^ (2 :: Int)
    shallow middle first final = segmentDistanceSquared (exact middle) (exact first, exact final) < threshold
    deletable a b c = orientation (exact a) (exact b) (exact c) == direction && shallow b a c && all (shallow b a) [a, a + max 1 ((c - a) `div` 10) .. c - 1]
    pass (first : rest) = first : scan rest
    pass [] = []
    scan (a : b : c : rest)
        | deletable a b c = a : scan (c : rest)
        | otherwise = a : scan (b : c : rest)
    scan rest = rest
    repeatPass indexes = let next = pass indexes in if next == indexes then indexes else repeatPass next

-- | A floating-point position used to approximate circular arcs.
type FloatingPosition = (Double, Double)

-- | Round an exact position once for metric calculations.
toDouble :: Position -> FloatingPosition
toDouble (x, y) = (fromRational x, fromRational y)

-- | Preserve the exact binary coordinates of an approximate arc.
toExact :: FloatingPosition -> Position
toExact (x, y) = (toRational x, toRational y)

-- | Add a displacement to a position.
plus :: FloatingPosition -> FloatingPosition -> FloatingPosition
plus (x, y) (u, v) = (x + u, y + v)

-- | Negate a displacement.
opposite :: FloatingPosition -> FloatingPosition
opposite (x, y) = (-x, -y)

{- | The left perpendicular displacement at the requested distance.
The evaluation order matches GEOS. Intermediate Double values can overflow.
-}
normal :: Double -> FloatingPosition -> FloatingPosition -> FloatingPosition
normal radius (x, y) (u, v) = (-(radius * dy / distance), radius * dx / distance)
  where
    dx = u - x
    dy = v - y
    distance = sqrt (dx * dx + dy * dy)

-- | Close a nonempty polygon ring.
close :: [a] -> [a]
close [] = []
close points@(first : _) = points ++ [first]

-- | Approximate a clockwise circle with a fixed quadrant resolution.
circle :: Int -> Double -> FloatingPosition -> [FloatingPosition]
circle count radius center = close [plus center (radial radius angle) | i <- [0 .. 4 * count - 1], let angle = negate (fromIntegral i * (2 * pi / fromIntegral (4 * count)))]

{- | Match GEOS snapping of trigonometric values at the coordinate axes.
The 5e-16 threshold comes from
<https://github.com/libgeos/geos/blob/3.13.1/include/geos/algorithm/Angle.h#L232 Angle.sinCosSnap>.
-}
radial :: Double -> Double -> FloatingPosition
radial radius angle = (radius * snap (cos angle), radius * snap (sin angle))
  where
    snap value = if abs value < 5e-16 then 0 else value

-- | Approximate the directed arc between two radial displacement vectors.
arc :: Int -> Double -> FloatingPosition -> FloatingPosition -> FloatingPosition -> Bool -> [FloatingPosition]
arc count radius center first last' clockwise = plus center first : interior ++ [plus center last']
  where
    direction endpoint = let (x, y) = plus center endpoint; (cx, cy) = center in atan2 (y - cy) (x - cx)
    initial = direction first
    end = direction last'
    start
        | clockwise && initial <= end = initial + 2 * pi
        | not clockwise && initial >= end = initial - 2 * pi
        | otherwise = initial
    total = abs (start - end)
    steps = max 1 (floor (total / ((pi / 2) / fromIntegral count) + 0.5) :: Int)
    increment = (if clockwise then -1 else 1) * (total / fromIntegral steps)
    interior = [plus center (radial radius angle) | i <- [1 .. steps - 1], let angle = start + fromIntegral i * increment]
