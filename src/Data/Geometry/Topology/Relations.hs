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

import Data.Geometry.Internal (Geometry (..), withPoint)
import Data.Geometry.Topology.Planar
import Data.List (minimumBy)
import qualified Data.List as List
import Data.Ord (comparing)

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
    nodes = unique (inputVertices ++ concatMap (\(p, q) -> [p, q]) edges)
    samples =
        [(locate a p, locate b p, 0) | p <- nodes]
            ++ [(locate a p, locate b p, 1) | edge <- edges, let p = midpoint edge]
            ++ [ (areaLocation a p, areaLocation b p, 2)
               | edge <- edges
               , let (left, right) = sidePoints edges edge
               , p <- [left, right]
               ]
    areaLocation shape p = if polygonContains shape p then Interior else Exterior
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
equals first second = matrix == "FFFFFFFF2" || matches "T*F**FFF*" matrix
  where
    matrix = relate first second

-- | Test whether the geometries have no point in common.
disjoint :: Geometry -> Geometry -> Bool
disjoint first second = not (intersects first second)

{- | Test whether the geometries have at least one point in common.
Reject disjoint envelopes, then test component points and segment contacts.
Stop when an intersection is found without constructing a relation matrix.
-}
intersects :: Geometry -> Geometry -> Bool
intersects first second =
    not (disjointBounds (vertices a) (vertices b))
        && ( any (coversPosition b) (componentPoints a)
                || any (coversPosition a) (componentPoints b)
                || segmentsIntersect (segments a) (segments b)
           )
  where
    a = planar first
    b = planar second

-- | Test whether the geometries meet but their interiors do not intersect.
touches :: Geometry -> Geometry -> Bool
touches first second = any (`matches` matrix) ["FT*******", "F**T*****", "F***T****"]
  where
    matrix = relate first second

{- | Whether the geometries cross in their interiors.
For different dimensions, the interiors must intersect and the geometry with
the lower dimension must extend outside the other. Two lines cross when
their interiors meet at points. Other equal-dimension pairs return 'False'.
-}
crosses :: Geometry -> Geometry -> Bool
crosses first second
    | dimensionA < dimensionB = matches "T*T******" matrix
    | dimensionA > dimensionB = matches "T*****T**" matrix
    | dimensionA == 1 = matches "0********" matrix
    | otherwise = False
  where
    matrix = relate first second
    (dimensionA, dimensionB) = matrixDimensions matrix

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
contains first second = relatePattern "T*****FF*" first second

{- | Test whether geometries of the same dimension share an interior part
of that dimension and each has a part outside the other.
-}
overlaps :: Geometry -> Geometry -> Bool
overlaps first second
    | dimensionA /= dimensionB = False
    | dimensionA == 1 = matches "1*T***T**" matrix
    | dimensionA == 0 || dimensionA == 2 = matches "T*T***T**" matrix
    | otherwise = False
  where
    matrix = relate first second
    (dimensionA, dimensionB) = matrixDimensions matrix

{- | Test whether the second geometry has no point outside the first.
Return 'False' if either geometry is empty. Boundary points are included.
-}
covers :: Geometry -> Geometry -> Bool
covers first (PointGeometry point) = maybe False (coversPosition (planar first)) (withPoint position point)
covers first second = matches "******FF*" matrix && not (matches "FF*FF****" matrix)
  where
    matrix = relate first second

-- | Whether the first geometry is covered by the second, including its boundary.
coveredBy :: Geometry -> Geometry -> Bool
coveredBy first second = covers second first

-- | Recover the dimensions of the nonempty point sets from their matrix.
matrixDimensions :: String -> (Int, Int)
matrixDimensions matrix = (dimension [0, 1, 2, 3, 4, 5], dimension [0, 1, 3, 4, 6, 7])
  where
    dimension = maximum . map (value . (matrix !!))
    value '0' = 0
    value '1' = 1
    value '2' = 2
    value _ = -1

{- | Return the minimum Euclidean distance in the XY plane.
Empty geometries return NaN. Intersecting geometries return zero.
Exact projections avoid overflow and cancellation before the final square root.
-}
distance :: Geometry -> Geometry -> Double
distance first second
    | null verticesA || null verticesB = 0 / 0
    | any ((/= Exterior) . locate b) verticesA || any ((/= Exterior) . locate a) verticesB = 0
    | any (not . null) [segmentIntersection edgeA edgeB | edgeA <- edgesA, edgeB <- edgesB] = 0
    | otherwise = vectorLength (minimumBy (comparing squaredLength) candidates)
  where
    a = planar first
    b = planar second
    verticesA = vertices a
    verticesB = vertices b
    edgesA = segments a
    edgesB = segments b
    candidates =
        [subtractPosition p q | p <- verticesA, q <- verticesB]
            ++ [segmentOffset p edge | p <- verticesA, edge <- edgesB]
            ++ [segmentOffset p edge | p <- verticesB, edge <- edgesA]

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
