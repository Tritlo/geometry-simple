{- | Tolerance-based noding for precision retries.

Nearby vertices share one stored position. Segments receive shared intersection
nodes and nearby vertices before exact overlay. The algorithm follows the
vertex and near-segment snapping strategy used by GEOS SnappingNoder.
-}
module Data.Geometry.Topology.Snapping (snapPlanars) where

import Data.Geometry.Internal (TopologicalDimension (..))
import Data.Geometry.Topology.Planar
import Data.List (minimumBy, sortOn)
import qualified Data.List as List
import qualified Data.Map.Strict as Map
import Data.Ord (comparing)

{- | Snap two inputs together within a positive distance tolerance.
Process stored vertices before generated intersections. Select representatives
in XY order so operand order does not determine the coordinate choice.
-}
snapPlanars :: Rational -> Planar -> Planar -> (Planar, Planar)
snapPlanars tolerance first second = (finish a, finish b)
  where
    stored = representatives tolerance (unique (allPositions first ++ allPositions second))
    a = mapPositions (stored Map.!) first
    b = mapPositions (stored Map.!) second
    edges = segments a ++ segments b
    queryEdges = segmentQuery edges
    noded = nodeSegments edges []
    nodes = representatives tolerance (unique (allPositions a ++ allPositions b) ++ unique (concatMap (\(p, q) -> [p, q]) noded))
    candidates = segmentQuery [(p, p) | p <- unique (Map.elems nodes)]
    squaredTolerance = tolerance * tolerance
    finish shape = Planar (planarPoints shape ++ collapsed) curves polygons
      where
        paths = map path (planarLines shape)
        collapsed = [p | [p] <- paths]
        curves = [line | line@(_ : _ : _) <- paths]
        polygons = [shell : filter hasArea holes | rings <- planarPolygons shape, shell : holes <- [map path rings], hasArea shell]
    hasArea ring = planarDimension (Planar [] [] [[ring]]) == SurfaceDimension
    path [] = []
    path values@(start : _) = start : concatMap insert (lineSegments values)
    insert edge@(p@(px, py), q@(qx, qy)) = sortOn parameter (filter between (unique (crossings ++ nearby))) ++ [q]
      where
        direction = subtractPosition q p
        parameter point = dot (subtractPosition point p) direction
        between point = parameter point > 0 && parameter point < squaredLength direction
        crossings = [nodes Map.! point | other <- queryEdges edge, point <- segmentIntersection edge other]
        expanded = ((min px qx - tolerance, min py qy - tolerance), (max px qx + tolerance, max py qy + tolerance))
        nearby =
            [ point
            | (point, _) <- candidates expanded
            , squaredLength (subtractPosition point p) >= squaredTolerance
            , squaredLength (subtractPosition point q) >= squaredTolerance
            , squaredLength (segmentOffset point edge) < squaredTolerance
            ]

-- | Transform every position without changing the component structure.
mapPositions :: (Position -> Position) -> Planar -> Planar
mapPositions f (Planar points lines' polygons) = Planar (map f points) (map (map f) lines') (map (map (map f)) polygons)

{- | Select an existing nearby representative or store a rounded position.
The spatial buckets contain only representatives. A chain of nearby inputs
therefore cannot move an endpoint farther than the tolerance.
-}
representatives :: Rational -> [Position] -> Map.Map Position Position
representatives tolerance = snd . List.foldl' add (Map.empty, Map.empty)
  where
    squaredTolerance = tolerance * tolerance
    bucket (x, y) = (floor (x / tolerance) :: Integer, floor (y / tolerance) :: Integer)
    add state@(buckets, assigned) point
        | Map.member point assigned = state
        | otherwise = case nearby of
            [] ->
                let chosen = rounded point
                 in (Map.insertWith (++) (bucket chosen) [chosen] buckets, Map.insert point chosen assigned)
            _ -> (buckets, Map.insert point (minimumBy (comparing (\p -> (distance p, p))) nearby) assigned)
      where
        (i, j) = bucket point
        distance p = squaredLength (subtractPosition p point)
        nearby = [p | x <- [i - 1 .. i + 1], y <- [j - 1 .. j + 1], p <- Map.findWithDefault [] (x, y) buckets, distance p <= squaredTolerance]
    rounded (x, y) = (toRational (fromRational x :: Double), toRational (fromRational y :: Double))
