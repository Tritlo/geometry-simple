-- | Planar spatial relations and distance. Coordinates must have finite XY values.
module Data.Geometry.Topology.Relations (
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
    distance,
) where

import Data.Geometry.Internal (Geometry (..), TopologicalDimension (..), withPoint)
import Data.Geometry.Topology.Planar
import qualified Data.List as List
import qualified Data.Set as Set

{- | Return the nine-character DE-9IM intersection matrix in row-major order.
Rows and columns denote interior, boundary, and exterior. Each character is
@F@ for an empty intersection, or @0@, @1@, or @2@ for its dimension.
Z and M ordinates do not affect the result. Line boundaries use the mod-2 rule.
-}
relate :: Geometry -> Geometry -> String
relate first second = map symbol (List.foldl' record (replicate 8 (-1) ++ [2]) samples)
  where
    a = planar first
    b = planar second
    inputVertices = vertices a ++ vertices b
    edges = nodeSegments (segments a ++ segments b) inputVertices
    queryEdges = segmentQuery edges
    nodes = unique (inputVertices ++ concatMap (\(p, q) -> [p, q]) edges)
    (locateA, insideA) = prepareLocations a
    (locateB, insideB) = prepareLocations b
    samples =
        [(locateA p, locateB p, 0) | p <- nodes]
            ++ [(locateA p, locateB p, 1) | edge <- edges, let p = midpoint edge]
            ++ [ (areaLocation insideA p, areaLocation insideB p, 2)
               | edge <- edges
               , let (left, right) = sidePoints queryEdges edge
               , p <- [left, right]
               ]
    areaLocation containsPoint p = if containsPoint p then Interior else Exterior
    record :: [Int] -> (Location, Location, Int) -> [Int]
    record matrix (row, column, dimension) =
        zipWith (\index old -> if index == locationIndex row * 3 + locationIndex column then max old dimension else old) [0 ..] matrix
    symbol dimension = case dimension of
        0 -> '0'
        1 -> '1'
        2 -> '2'
        _ -> 'F'

-- | Convert the location order to the DE-9IM row and column order.
locationIndex :: Location -> Int
locationIndex location = case location of
    Interior -> 0
    Boundary -> 1
    Exterior -> 2

{- | Test a DE-9IM pattern. The pattern must contain nine characters from
@TF*012@. Invalid patterns return 'False'.
-}
relatePattern :: String -> Geometry -> Geometry -> Bool
relatePattern pattern first second = matches pattern (relate first second)

-- | Validate a pattern and match it against a complete intersection matrix.
matches :: String -> String -> Bool
matches pattern matrix = length pattern == 9 && all (`elem` "TF*012") pattern && and (zipWith match pattern matrix)
  where
    match '*' _ = True
    match 'T' actual = actual /= 'F'
    match expected actual = expected == actual

{- | Test whether both geometries contain the same XY point set.
All empty geometries are spatially equal, regardless of their family.
-}
equals :: Geometry -> Geometry -> Bool
equals first second =
    planarDimension a == planarDimension b
        && pointBounds (allPositions a) == pointBounds (allPositions b)
        && (matrix == "FFFFFFFF2" || matches "T*F**FFF*" matrix)
  where
    a = planar first
    b = planar second
    matrix = relate first second

-- | Test whether the geometries have no point in common.
disjoint :: Geometry -> Geometry -> Bool
disjoint first second = not (intersects first second)

{- | Test whether the geometries have at least one point in common.
Reject disjoint envelopes, then test component points and segment contacts.
Stop when an intersection is found without constructing a relation matrix.
-}
intersects :: Geometry -> Geometry -> Bool
intersects first second = planarIntersects (planar first) (planar second)

-- | Reuse projected components when testing contact before a distance search.
planarIntersects :: Planar -> Planar -> Bool
planarIntersects a b =
    not (disjointBounds (allPositions a) (allPositions b))
        && ( any (coversPosition b) (componentPoints a)
                || any (coversPosition a) (componentPoints b)
                || segmentsIntersect (segments a) (segments b)
           )

-- | Test whether the geometries meet but their interiors do not intersect.
touches :: Geometry -> Geometry -> Bool
touches first second
    | not (planarIntersects a b) = False
    | any (polygonContains a) (componentPoints b) || any (polygonContains b) (componentPoints a) = False
    | otherwise = any (`matches` matrix) ["FT*******", "F**T*****", "F***T****"]
  where
    a = planar first
    b = planar second
    matrix = relate first second

{- | Whether the geometries cross in their interiors.
For different dimensions, the interiors must intersect and the geometry with
the lower dimension must extend outside the other. Two lines cross when
their interiors meet at points. Other equal-dimension pairs return 'False'.
-}
crosses :: Geometry -> Geometry -> Bool
crosses first second
    | dimensionA == dimensionB && dimensionA /= CurveDimension = False
    | disjointBounds (allPositions a) (allPositions b) = False
    | dimensionA < dimensionB = matches "T*T******" matrix
    | dimensionA > dimensionB = matches "T*****T**" matrix
    | dimensionA == CurveDimension = matches "0********" matrix
    | otherwise = False
  where
    matrix = relate first second
    a = planar first
    b = planar second
    dimensionA = planarDimension a
    dimensionB = planarDimension b

{- | Test whether the first geometry lies in the second geometry and their
interiors intersect. A geometry on only the second boundary is not within it.
-}
within :: Geometry -> Geometry -> Bool
within first second = contains second first

{- | Whether the second geometry lies in the first and their interiors intersect.
Contact confined to the boundary does not count. Use 'covers' to include it.
-}
contains :: Geometry -> Geometry -> Bool
contains first (PointGeometry point) = maybe False ((== Interior) . locate (planar first)) (withPoint position point)
contains first second =
    planarDimension a >= planarDimension b
        && enclosesBounds (allPositions a) (allPositions b)
        && relatePattern "T*****FF*" first second
  where
    a = planar first
    b = planar second

{- | Test whether geometries of the same dimension share an interior part
of that dimension and each has a part outside the other.
-}
overlaps :: Geometry -> Geometry -> Bool
overlaps first second
    | dimensionA /= dimensionB = False
    | disjointBounds (allPositions a) (allPositions b) = False
    | dimensionA == CurveDimension = matches "1*T***T**" matrix
    | dimensionA == PointDimension || dimensionA == SurfaceDimension = matches "T*T***T**" matrix
    | otherwise = False
  where
    matrix = relate first second
    a = planar first
    b = planar second
    dimensionA = planarDimension a
    dimensionB = planarDimension b

{- | Test whether the second geometry has no point outside the first.
Return 'False' if either geometry is empty. Boundary points are included.
-}
covers :: Geometry -> Geometry -> Bool
covers first (PointGeometry point) = maybe False (coversPosition (planar first)) (withPoint position point)
covers first second =
    planarDimension a >= planarDimension b
        && enclosesBounds (allPositions a) (allPositions b)
        && matches "******FF*" matrix
        && not (matches "FF*FF****" matrix)
  where
    a = planar first
    b = planar second
    matrix = relate first second

-- | Whether the first geometry is covered by the second, including its boundary.
coveredBy :: Geometry -> Geometry -> Bool
coveredBy first second = covers second first

{- | Return the minimum Euclidean distance in the XY plane.
Empty geometries return NaN. Intersecting geometries return zero.
Exact projections avoid overflow and cancellation before the final square root.
-}
distance :: Geometry -> Geometry -> Double
distance first second = case (verticesA, verticesB) of
    (p : _, q : _)
        | planarIntersects a b -> 0
        | otherwise ->
            let offset = subtractPosition p q
                initial = (offset, squaredLength offset)
                closest = case (treeA, treeB) of
                    (Just firstTree, Just secondTree) -> nearestPair firstTree secondTree initial
                    _ -> initial
             in vectorLength (fst closest)
    _ -> 0 / 0
  where
    a = planar first
    b = planar second
    verticesA = vertices a
    verticesB = vertices b
    edgesA = segments a
    edgesB = segments b
    treeA = distanceIndex verticesA edgesA
    treeB = distanceIndex verticesB edgesB

-- | Index segments and retain isolated vertices as zero-length segments.
distanceIndex :: [Position] -> [Segment] -> Maybe SegmentIndex
distanceIndex points edges = indexSegments (edges ++ [(p, p) | p <- points, Set.notMember p endpoints])
  where
    endpoints = Set.fromList (concatMap (\(a, b) -> [a, b]) edges)

-- | Search pairs of subtrees, pruning whole groups by their exact distance bounds.
nearestPair :: SegmentIndex -> SegmentIndex -> (Position, Rational) -> (Position, Rational)
nearestPair first second = visit (bound first second) first second
  where
    bound a b = boxesDistanceSquared (indexBounds a) (indexBounds b)
    visit lowerBound a b best@(_, bestSquared)
        | lowerBound >= bestSquared = best
        | otherwise = case (a, b) of
            (SegmentLeaf firstEdge@(p, q), SegmentLeaf secondEdge@(r, s)) ->
                List.foldl' closer best [offset p secondEdge, offset q secondEdge, offset r firstEdge, offset s firstEdge]
            (SegmentBranch _ left right, SegmentLeaf _) -> descend left b right b best
            (SegmentLeaf _, SegmentBranch _ left right) -> descend a left a right best
            (SegmentBranch _ leftA rightA, SegmentBranch _ leftB rightB)
                | extent a >= extent b -> descend leftA b rightA b best
                | otherwise -> descend a leftB a rightB best
    descend a b c d best
        | firstBound <= secondBound = visit secondBound c d (visit firstBound a b best)
        | otherwise = visit firstBound a b (visit secondBound c d best)
      where
        firstBound = bound a b
        secondBound = bound c d
    extent tree = let ((x, y), (u, v)) = indexBounds tree in max (abs (u - x)) (abs (v - y))
    offset point edge@(a, b) = if a == b then subtractPosition point a else segmentOffset point edge
    closer best@(_, current) candidate = let squared = squaredLength candidate in if squared < current then (candidate, squared) else best

-- | The exact squared distance between two closed axis-aligned bounding boxes.
boxesDistanceSquared :: Segment -> Segment -> Rational
boxesDistanceSquared ((ax, ay), (bx, by)) ((cx, cy), (dx, dy)) = squaredLength (gap ax bx cx dx, gap ay by cy dy)
  where
    gap a b c d = max 0 (max (min a b - max c d) (min c d - max a b))

-- | Return the vector from the closest point on a segment to a point.
segmentOffset :: Position -> Segment -> Position
segmentOffset point (a, b) = subtractPosition offset (scalePosition fraction direction)
  where
    offset = subtractPosition point a
    direction = subtractPosition b a
    fraction = max 0 (min 1 (dot offset direction / squaredLength direction))

-- | The exact scalar product of two vectors.
dot :: Position -> Position -> Rational
dot (x, y) (u, v) = x * u + y * v

-- | The exact squared length of a vector.
squaredLength :: Position -> Rational
squaredLength vector = dot vector vector

-- | Scale a vector before conversion to avoid squared-coordinate overflow.
vectorLength :: Position -> Double
vectorLength (x, y)
    | scale == 0 = 0
    | otherwise = fromRational scale * sqrt (1 + fromRational (ratio * ratio))
  where
    scale = max (abs x) (abs y)
    ratio = min (abs x) (abs y) / scale
