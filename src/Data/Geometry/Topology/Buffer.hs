{- | Round planar buffers with polygonal approximations of circular arcs.

The arc and corner rules follow GEOS 3.13.1. See
<https://github.com/libgeos/geos/blob/3.13.1/src/operation/buffer/OffsetSegmentGenerator.cpp OffsetSegmentGenerator>.
The relative distance thresholds below match that implementation.
-}
module Data.Geometry.Topology.Buffer (buffer, bufferWithSegments) where

import Data.Geometry.Internal
import Data.Geometry.Topology.Overlay
import Data.Geometry.Topology.Planar
import Data.List (group, groupBy)
import Data.Maybe (catMaybes)
import qualified Data.Vector as V

{- | Buffer by a distance in coordinate units, with eight segments per quadrant.
Positive distances expand geometry. Negative distances erode polygons and give
empty polygons for points and lines. All results use XY coordinates.
A zero distance extracts polygonal regions. Invalid input can lose regions,
such as one lobe of a self-crossing bowtie. It is not a general validity repair.
The distance and XY coordinates must be finite. Rounded results use the same
validation and bounded snapping as 'intersection'. Return 'Left' when construction
fails; a 'Right' result has valid topology. Return 'Left' 'CoordinateOverflow'
when an offset coordinate cannot fit in a finite Double.
-}
buffer :: Double -> Geometry -> Either TopologyException Geometry
buffer = bufferWithSegments 8

{- | Construct a round buffer with the requested number of segments per quadrant.
Values below one use one segment. The distance and XY coordinates must be finite.
The distance and coordinate-layout rules are the same as for 'buffer'.
-}
bufferWithSegments :: Int -> Double -> Geometry -> Either TopologyException Geometry
bufferWithSegments quadrants radius geometry =
    robustOperation SurfaceDimension (max 0 (toRational radius)) (\source _ -> bufferPlanar (max 1 quadrants) radius source) (planar geometry) (Planar [] [] [])

-- | Build buffer boundaries from source coordinates at one precision attempt.
bufferPlanar :: Int -> Double -> Planar -> Either TopologyException Geometry
bufferPlanar count radius source = do
    lines' <- if radius > 0 then concat <$> traverse (lineBuffer count width) (planarLines source) else pure []
    rings <- traverse checkedCurve (lines' ++ [circle count width (toDouble p) | radius > 0, p <- planarPoints source])
    offsetRings <- if radius == 0 then pure [] else concat <$> traverse (offsetPolygon count radius) (planarPolygons source)
    let surfaces = Planar [] [] (planarPolygons source)
        bands = Planar [] [] [[map toExact ring] | ring <- rings]
        edges = nodeSegments ((if radius /= 0 then concatMap ringSegments offsetRings else segments surfaces) ++ segments bands) []
        queryEdges = segmentQuery edges
        depths = map prepareDepth (planarPolygons source)
        offsetWinding = prepareWinding (concatMap ringSegments (offsetRings ++ map (map toExact) rings))
        selected p
            | radius == 0 = any (\depth -> depth p > 0) depths
            | otherwise = offsetWinding p < 0
        boundary =
            [ if leftInside then (a, b) else (b, a)
            | edge@(a, b) <- edges
            , let (left, right) = sidePoints queryEdges edge
            , let leftInside = selected left
            , leftInside /= selected right
            ]
    polygons <- polygonize boundary
    pure (assemble SurfaceDimension polygons [] [])
  where
    width = abs radius

-- | Reject nonfinite offset coordinates before conversion to exact positions.
checkedCurve :: [FloatingPosition] -> Either TopologyException [FloatingPosition]
checkedCurve points
    | all (\(x, y) -> finite x && finite y) points = Right points
    | otherwise = Left CoordinateOverflow

-- | Prepare ring winding and orientation for zero-buffer queries.
prepareDepth :: [[Position]] -> Position -> Int
prepareDepth [] = const 0
prepareDepth (shell : holes) = \point -> shellDepth point - sum (map ($ point) holeDepths)
  where
    shellDepth = depth shell
    holeDepths = map depth holes
    depth ring =
        let sign = if ringArea ring > 0 then 1 else -1
            winding = prepareWinding (ringSegments ring)
         in \point -> sign * winding point

{- | Offset shells clockwise and holes counterclockwise, with interior on the right.
GEOS discards inverted erosion curves whose samples all lie within 0.99 of
the requested radius from the source boundary. See
<https://github.com/libgeos/geos/blob/3.13.1/src/operation/buffer/BufferCurveSetBuilder.cpp#L418 BufferCurveSetBuilder>.
-}
offsetPolygon :: Int -> Double -> [[Position]] -> Either TopologyException [[Position]]
offsetPolygon _ _ [] = Right []
offsetPolygon count distance (shell : holes)
    | distance < 0 && eroded shell = Right []
    | otherwise = do
        shellCurve <- offset (distance < 0) shell
        if distance < 0 && inverted shell shellCurve
            then pure []
            else (shellCurve :) . catMaybes <$> traverse holeCurve holes
  where
    radius = abs distance
    holeCurve hole
        | distance >= 0 && eroded hole = Right Nothing
        | otherwise = do
            curve <- offset (distance > 0) hole
            pure (if distance >= 0 && inverted hole curve then Nothing else Just curve)
    offset ccw ring = do
        let flipped = (ringArea ring > 0) /= ccw
            simplified = simplify (if flipped then LT else GT) (radius / 100) (map toDouble ring)
            input = if flipped then reverse simplified else simplified
        curve <- map toExact <$> (offsetRing count radius flipped input >>= checkedCurve)
        pure (if distance < 0 then reverse curve else curve)
    eroded [] = True
    eroded ring
        | length (unique ring) == 3 = toRational radius * sum [vectorMagnitude (subtractPosition b a) | (a, b) <- ringSegments ring] > abs (ringArea ring)
        | otherwise =
            let xs = map fst ring
                ys = map snd ring
             in 2 * toRational radius > min (maximum xs - minimum xs) (maximum ys - minimum ys)
    inverted ring curve = not (any farEnough (curve ++ map midpoint (ringSegments curve)))
      where
        query = segmentQuery (ringSegments ring)
        reach = toRational (0.99 * radius)
        farEnough point@(x, y) = all ((> reach ^ (2 :: Int)) . squaredLength . segmentOffset point) (query ((x - reach, y - reach), (x + reach, y + reach)))

-- | Build a connected left offset curve before resolving its self-intersections.
offsetRing :: Int -> Double -> Bool -> [FloatingPosition] -> Either TopologyException [FloatingPosition]
offsetRing count radius flipped original = case points of
    [] -> Right []
    [p] -> Right (circle count radius p)
    _ -> close . separate radius . concat <$> traverse (offsetCorner count radius flipped) (zip3 (last points : init points) points (drop 1 points ++ take 1 points))
  where
    uniquePoints = [p | p : _ <- group original]
    points = case uniquePoints of
        first : _ | first == last uniquePoints -> init uniquePoints
        _ -> uniquePoints

{- | Join two left offset segments, rounding convex turns and trimming concave turns.
The 1e-3 relative separation and 80:1 inside-corner connector match GEOS.
-}
offsetCorner :: Int -> Double -> Bool -> (FloatingPosition, FloatingPosition, FloatingPosition) -> Either TopologyException [FloatingPosition]
offsetCorner count radius flipped (a, b, c) = do
    _ <- checkedCurve [end, start]
    case turn of
        LT | separation < radius * 1e-3 -> pure [end]
        LT -> checkedCurve (arc count radius b before after True)
        EQ -> checkedCurve (if (a < b) /= (b < c) then arc count radius b before after (not flipped) else [])
        GT -> do
            _ <- checkedCurve [plus a before, plus c after]
            checkedCurve $ case segmentIntersection (toExact (plus a before), toExact end) (toExact start, toExact (plus c after)) of
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
    toward (x, y) = let (u, v) = b in (weighted x u, weighted y v)
    weighted x y =
        let result = (factor * x + y) / (factor + 1)
         in if finite result then result else fromRational ((toRational factor * toRational x + toRational y) / toRational (factor + 1))

-- | Construct one connected outline for an open line, or two offsets for a ring.
lineBuffer :: Int -> Double -> [Position] -> Either TopologyException [[FloatingPosition]]
lineBuffer count radius original = case points of
    [] -> Right []
    [point] -> Right [circle count radius point]
    first : _ : _
        | first == last points -> map (map toDouble) <$> offsetPolygon count radius [map toExact points, map toExact points]
        | otherwise -> do
            left <- leftSide leftPath
            right <- leftSide rightPath
            outline <- checkedCurve (left ++ cap leftPath ++ right ++ cap rightPath)
            pure [close (separate radius outline)]
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
    leftSide path@(_ : _ : _) = do
        corners <- concat <$> traverse (offsetCorner count radius False) (zip3 path (drop 1 path) (drop 2 path))
        pure (corners ++ [plus (last path) (normal radius (path !! (length path - 2)) (last path))])
    leftSide _ = Right []

-- | Match GEOS's minimum vertex separation of 1e-4 times the buffer radius.
separate :: Double -> [FloatingPosition] -> [FloatingPosition]
separate radius points = [first | first : _ <- groupBy (\a b -> pointDistance a b < radius * 1e-4) points]

-- | The Euclidean distance used by native buffer vertex thresholds.
pointDistance :: FloatingPosition -> FloatingPosition -> Double
pointDistance a@(x, y) b@(u, v)
    | finite squared && (squared > 0 || a == b) = sqrt squared
    | otherwise = vectorLength (subtractPosition (toExact a) (toExact b))
  where
    squared = (x - u) * (x - u) + (y - v) * (y - v)

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
    shallow middle first final = squaredLength (segmentOffset (exact middle) (exact first, exact final)) < threshold
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
Keep the usual evaluation order. Use exact scaling when a product overflows
or loses a nonzero displacement to underflow.
-}
normal :: Double -> FloatingPosition -> FloatingPosition -> FloatingPosition
normal radius a@(x, y) b@(u, v)
    | finite nx && finite ny && (nx /= 0 || dy == 0 || radius == 0) && (ny /= 0 || dx == 0 || radius == 0) = (nx, ny)
    | otherwise = toDouble (scalePosition (toRational radius / vectorMagnitude direction) (-ey, ex))
  where
    dx = u - x
    dy = v - y
    distance = pointDistance a b
    nx = -(radius * dy / distance)
    ny = radius * dx / distance
    direction@(ex, ey) = subtractPosition (toExact b) (toExact a)

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
