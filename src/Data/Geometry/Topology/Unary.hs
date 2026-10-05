-- | Boundary, topology validation, and representative interior points.
module Data.Geometry.Topology.Unary (
    boundary,
    isSimple,
    isRing,
    isValid,
    pointOnSurface,
) where

import Control.Applicative ((<|>))
import Data.Geometry.Internal
import Data.Geometry.Topology.Planar
import qualified Data.Graph as Graph
import Data.List (group, sort)
import qualified Data.List as List
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe, listToMaybe, mapMaybe)
import Data.Ord (comparing)
import qualified Data.Set as Set
import qualified Data.Vector as V
import qualified Data.Vector.Unboxed as U

{- | The topological boundary. Geometry collections have no boundary operation
in GEOS and return 'Nothing'. Line endpoints use the mod-2 boundary rule.
-}
boundary :: Geometry -> Maybe Geometry
boundary geometry = case geometry of
    PointGeometry _ -> Just (GeometryCollection V.empty)
    MultiPoint _ -> Just (GeometryCollection V.empty)
    LineString line -> Just (MultiPoint (U.fromList (lineBoundary line)))
    MultiLineString lines' -> Just (MultiPoint (U.fromList endpoints))
      where
        counts = Map.fromListWith (\(_, n) (old, m) -> (old, n + m)) [(pointXY point, (point, 1 :: Int)) | point <- foldMap lineEnds lines']
        selected = [point | (point, count) <- Map.elems counts, odd count]
        withZ = any (not . isNaN . elevationOrNaN) selected
        endpoints = map (boundaryPoint withZ) selected
    Polygon rings@(PolygonRings shell holes)
        | geometryEmpty (Polygon rings) -> Just (MultiLineString V.empty)
        | V.null holes -> Just (LineString shell)
        | otherwise -> Just (MultiLineString (V.cons shell holes))
    MultiPolygon polygons -> Just (MultiLineString (V.fromList (foldMap polygonBoundary polygons)))
    GeometryCollection _ -> Nothing

-- | Return the rings of a nonempty polygon.
polygonBoundary :: PolygonRings -> [Coordinates]
polygonBoundary rings@(PolygonRings shell holes)
    | geometryEmpty (Polygon rings) = []
    | otherwise = shell : V.toList holes

-- | Return the two endpoints, also for a closed line.
lineEnds :: Coordinates -> [Point]
lineEnds line = withCoordinates endpoints line
  where
    endpoints points = case U.uncons points of
        Nothing -> []
        Just (first, _) -> map (pointFromComponents (dimensionsOf line) . coordinateComponents) [first, U.last points]

-- | Return the distinct endpoints of an open line.
lineBoundary :: Coordinates -> [Point]
lineBoundary line = case lineEnds line of
    [a, b] | pointXY a /= pointXY b -> [a, b]
    _ -> []

-- | Copy coordinates without changing their layout.
coordinatePoints :: Coordinates -> [Point]
coordinatePoints coordinates = withCoordinates (map (pointFromComponents (dimensionsOf coordinates) . coordinateComponents) . U.toList) coordinates

-- | Read the XY ordinates of a nonempty point.
pointXY :: Point -> (Double, Double)
pointXY point = case withPoint coordinateComponents point of
    Just (x, y, _, _) -> (x, y)
    Nothing -> (0 / 0, 0 / 0)

-- | Read elevation, with NaN for absent Z.
elevationOrNaN :: Point -> Double
elevationOrNaN (PointXYZ (XYZ _ _ z)) = z
elevationOrNaN (PointXYZM (XYZM _ _ z _)) = z
elevationOrNaN _ = 0 / 0

-- | Multi-line boundaries discard M and share their output coordinate layout.
boundaryPoint :: Bool -> Point -> Point
boundaryPoint withZ point =
    let (x, y) = pointXY point
     in if withZ then PointXYZ (XYZ x y (elevationOrNaN point)) else PointXY (XY x y)

{- | Whether curves have no self-intersections except their closing endpoint,
and multi-points have no duplicate XY positions. Polygon rings are checked
separately. Geometry collection members are checked separately, as in GEOS.
The planar tests require finite XY coordinates.
-}
isSimple :: Geometry -> Bool
isSimple geometry = case geometry of
    PointGeometry _ -> True
    MultiPoint points -> let xy = mapMaybe (withPoint position) (U.toList points) in length xy == Set.size (Set.fromList xy)
    LineString line -> simpleLines [positions line]
    MultiLineString lines' -> simpleLines (map positions (V.toList lines'))
    Polygon (PolygonRings shell holes) -> all (simpleLines . (: []) . positions) (shell : V.toList holes)
    MultiPolygon polygons -> V.all (isSimple . Polygon) polygons
    GeometryCollection children -> V.all isSimple children

-- | Whether a line string is both closed and simple. Other families return false.
isRing :: Geometry -> Bool
isRing geometry@(LineString line) = case lineEnds line of
    [a, b] -> pointXY a == pointXY b && isSimple geometry
    _ -> False
isRing _ = False

-- | Compare segment intersections after removing adjacent repeated positions.
simpleLines :: [[Position]] -> Bool
simpleLines lines' = all allowed (overlappingPairs [(edge, value) | value@(_, _, _, _, edge) <- indexed])
  where
    indexed = [(lineIndex, edgeIndex, length points - 2, first == last points, edge) | (lineIndex, input) <- zip [0 :: Int ..] lines', let points = [p | p : _ <- group input], first : _ <- [points], (edgeIndex, edge) <- zip [0 :: Int ..] (lineSegments points)]
    allowed ((lineA, indexA, lastA, closedA, edgeA), (lineB, indexB, lastB, closedB, edgeB)) = case segmentIntersection edgeA edgeB of
        [] -> True
        [p]
            | p `notElem` ends edgeA || p `notElem` ends edgeB -> False
            | lineA == lineB && abs (indexA - indexB) == 1 -> True
            | otherwise -> endpoint p indexA lastA edgeA && endpoint p indexB lastB edgeB && (lineA == lineB || not (closedA || closedB))
        _ -> False
    endpoint p i lastIndex (a, b) = (i == 0 && p == a) || (i == lastIndex && p == b)
    ends (a, b) = [a, b]

{- | Check finite XY positions and the Simple Features topology rules.
Polygon holes must lie inside the shell. Ring contacts must leave the
polygon interior connected. Multi-polygon interiors must be disjoint.
-}
isValid :: Geometry -> Bool
isValid geometry =
    finiteGeometry geometry && case geometry of
        PointGeometry _ -> True
        MultiPoint _ -> True
        LineString line -> validLine (positions line)
        MultiLineString lines' -> V.all (validLine . positions) lines'
        Polygon rings -> validPolygon (polygonPositions rings)
        MultiPolygon polygons -> all validPolygon rings && all disjointPolygons (overlappingPairs [(bounds, polygon) | polygon <- rings, Just bounds <- [pointBounds (concat polygon)]])
          where
            rings = map polygonPositions (V.toList polygons)
        GeometryCollection children -> V.all isValid children

-- | Check XY only. Elevations and measures do not affect topology.
finiteGeometry :: Geometry -> Bool
finiteGeometry geometry = case geometry of
    PointGeometry point -> maybe True finiteCoordinate (withPoint coordinateComponents point)
    MultiPoint points -> U.all (finiteGeometry . PointGeometry) points
    LineString line -> finiteLine line
    MultiLineString lines' -> V.all finiteLine lines'
    Polygon (PolygonRings shell holes) -> finiteLine shell && V.all finiteLine holes
    MultiPolygon polygons -> V.all (finiteGeometry . Polygon) polygons
    GeometryCollection children -> V.all finiteGeometry children
  where
    finiteCoordinate (x, y, _, _) = finite x && finite y
    finiteLine = withCoordinates (U.all (finiteCoordinate . coordinateComponents))

-- | Read the shell followed by holes in the XY plane.
polygonPositions :: PolygonRings -> [[Position]]
polygonPositions (PolygonRings shell holes) = map positions (shell : V.toList holes)

-- | Nonempty valid lines have at least two distinct XY positions.
validLine :: [Position] -> Bool
validLine [] = True
validLine (first : rest) = any (/= first) rest

-- | Nonempty valid rings are closed, simple, and have three distinct vertices.
validRing :: [Position] -> Bool
validRing [] = True
validRing points@(first : _) = first == last points && Set.size (Set.fromList points) >= 3 && simpleLines [points]

-- | Validate rings, containment, hole separation, and contact cycles.
validPolygon :: [[Position]] -> Bool
validPolygon [] = True
validPolygon (shell : holes)
    | null shell = all null holes
    | otherwise = all validRing rings && all noOverlap ringPairs && all insideShell nonemptyHoles && all separateHoles holePairs && acyclic contacts
  where
    nonemptyHoles = filter (not . null) holes
    rings = shell : nonemptyHoles
    ringPairs = overlappingPairs [(bounds, (i, ring)) | (i, ring) <- zip [0 :: Int ..] rings, Just bounds <- [pointBounds ring]]
    holePairs = [(a, b) | ((i, a), (j, b)) <- ringPairs, i > 0, j > 0]
    noOverlap ((_, a), (_, b)) = not (sharedEdge a b)
    locateShell = prepareRing shell
    insideShell hole = all ((/= Exterior) . locateShell) (ringSamples hole shell)
    separateHoles (a, b) = all ((/= Interior) . prepareRing b) (ringSamples a b) && all ((/= Interior) . prepareRing a) (ringSamples b a)
    contacts = Set.toList (Set.fromList [(Left k, Right p) | ((i, a), (j, b)) <- ringPairs, p <- ringIntersections a b, k <- [i, j]])

-- | The intersection positions of two ring boundaries.
ringIntersections :: [Position] -> [Position] -> [Position]
ringIntersections a b = unique (concat [segmentIntersection x y | x <- ringSegments a, y <- query x])
  where
    query = segmentQuery (ringSegments b)

-- | Whether ring boundaries share a segment of positive length.
sharedEdge :: [Position] -> [Position] -> Bool
sharedEdge a b = any ((> 1) . length) [segmentIntersection x y | x <- ringSegments a, y <- query x]
  where
    query = segmentQuery (ringSegments b)

-- | Sample every open edge portion after all intersections with another ring.
ringSamples :: [Position] -> [Position] -> [Position]
ringSamples ring other = ringSamplesAgainst ring (ringSegments other)

-- | Split one ring against a set of boundary edges before sampling it.
ringSamplesAgainst :: [Position] -> [Segment] -> [Position]
ringSamplesAgainst ring edges = concatMap sample (ringSegments ring)
  where
    query = segmentQuery edges
    sample edge@(a, b) = map midpoint (lineSegments (unique (a : b : concatMap (segmentIntersection edge) (query edge))))

{- | A cycle through distinct contact positions disconnects a polygon interior.
An undirected graph is acyclic when its edge count is its vertex count minus
its connected-component count. Each tree in the DFS forest is one component.
-}
acyclic :: [(Either Int Position, Either Int Position)] -> Bool
acyclic contacts = length contacts == Map.size adjacent - length (Graph.dff graph)
  where
    adjacent = Map.fromListWith (++) [(a, [b]) | (first, second) <- contacts, (a, b) <- [(first, second), (second, first)]]
    (graph, _, _) = Graph.graphFromEdges [((), point, neighbors) | (point, neighbors) <- Map.toList adjacent]

-- | Multi-polygons can touch at isolated points but cannot share interior area.
disjointPolygons :: ([[Position]], [[Position]]) -> Bool
disjointPolygons (a, b) =
    not (any (uncurry sharedEdge) [(x, y) | x <- a, y <- b])
        && all ((/= Interior) . preparePolygon b) (samples a b)
        && all ((/= Interior) . preparePolygon a) (samples b a)
  where
    samples rings other = concatMap (\ring -> ringSamplesAgainst ring (concatMap ringSegments other)) rings

{- | Choose a point on a nonempty component, preferring polygons, then lines,
then points. For polygons, use an interior horizontal interval. For lines,
prefer an interior stored vertex, then an endpoint. Empty components are skipped.
Results use XY coordinates. Empty input gives an empty XY point.
The selected point can differ from other implementations.
-}
pointOnSurface :: Geometry -> Point
pointOnSurface geometry = fromMaybe (EmptyPoint DimXY) (surfacePoint <|> storedPoint)
  where
    surfacePoint = snd <$> listToMaybe (mapMaybe polygonInterior (polygonMembers geometry))
    storedPoint = boundaryPoint False <$> listToMaybe (interiors ++ concatMap endpoints lines' ++ mapMaybe pointCoordinate (pointMembers geometry))
    lines' = map coordinatePoints (lineMembers geometry)
    interiors = concatMap (drop 1 . takeInterior) lines'
    takeInterior [] = []
    takeInterior points = init points
    endpoints [] = []
    endpoints points@(first : _) = [first, last points]
    pointCoordinate (EmptyPoint _) = Nothing
    pointCoordinate point = Just point

-- | List atomic point members in input order.
pointMembers :: Geometry -> [Point]
pointMembers (PointGeometry point) = [point]
pointMembers (MultiPoint points) = U.toList points
pointMembers (GeometryCollection children) = foldMap pointMembers children
pointMembers _ = []

-- | List atomic line members in input order.
lineMembers :: Geometry -> [Coordinates]
lineMembers (LineString line) = [line]
lineMembers (MultiLineString lines') = V.toList lines'
lineMembers (GeometryCollection children) = foldMap lineMembers children
lineMembers _ = []

-- | List atomic polygon members in input order.
polygonMembers :: Geometry -> [PolygonRings]
polygonMembers (Polygon rings) = [rings]
polygonMembers (MultiPolygon polygons) = V.toList polygons
polygonMembers (GeometryCollection children) = foldMap polygonMembers children
polygonMembers _ = []

-- | Select the midpoint of the widest horizontal interior interval.
polygonInterior :: PolygonRings -> Maybe (Double, Point)
polygonInterior (PolygonRings shell holes) = case map pointXY (coordinatePoints shell) of
    [] -> Nothing
    shellPoints@((x, y) : _) -> Just (List.maximumBy (comparing fst) ((0, PointXY (XY x y)) : intervals))
      where
        rings = shellPoints : map (map pointXY . coordinatePoints) (V.toList holes)
        ys = map snd (concat rings)
        lo = minimum (map snd shellPoints)
        hi = maximum (map snd shellPoints)
        center = (lo + hi) / 2
        below = maximum (lo : filter (<= center) ys)
        above = minimum (hi : filter (> center) ys)
        scanY = (below + above) / 2
        crossings = sort [crossing a b | ring <- rings, (a@(_, ay), b@(_, by)) <- zip ring (drop 1 ring), ay /= by, min ay by <= scanY, max ay by >= scanY, not (ay == scanY && by < scanY), not (by == scanY && ay < scanY)]
        crossing (ax, ay) (bx, by) = if ax == bx then ax else ax + (scanY - ay) / ((by - ay) / (bx - ax))
        intervals = [(b - a, PointXY (XY ((a + b) / 2) scanY)) | (a, b) <- adjacentPairs crossings, a < b]

-- | Pair sorted crossings into interior intervals.
adjacentPairs :: [a] -> [(a, a)]
adjacentPairs (a : b : rest) = (a, b) : adjacentPairs rest
adjacentPairs _ = []
