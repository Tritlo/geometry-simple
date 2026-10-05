-- | Boundary, topology validation, and representative interior points.
module Data.Geometry.Topology.Unary (
    boundary,
    isSimple,
    isRing,
    isValid,
    pointOnSurface,
) where

import Data.Geometry.Internal
import Data.Geometry.Topology.Planar
import Data.List (group, sort)
import qualified Data.List as List
import qualified Data.Map.Strict as Map
import Data.Maybe (mapMaybe)
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
        counts = List.foldl' addEndpoint Map.empty (concatMap lineEnds (V.toList lines'))
        selected = [point | (point, count) <- Map.elems counts, odd count]
        withZ = any (not . isNaN . pointZ) selected
        endpoints = map (boundaryPoint withZ) selected
        addEndpoint table point = Map.insertWith (\(_, n) (old, m) -> (old, n + m)) (pointXY point) (point, 1 :: Int) table
    Polygon rings@(PolygonRings shell holes)
        | geometryEmpty (Polygon rings) -> Just (MultiLineString V.empty)
        | V.null holes -> Just (LineString shell)
        | otherwise -> Just (MultiLineString (V.cons shell holes))
    MultiPolygon polygons -> Just (MultiLineString (V.fromList (concatMap polygonBoundary (V.toList polygons))))
    GeometryCollection _ -> Nothing

-- | Return the rings of a nonempty polygon.
polygonBoundary :: PolygonRings -> [Coordinates]
polygonBoundary rings@(PolygonRings shell holes)
    | geometryEmpty (Polygon rings) = []
    | otherwise = shell : V.toList holes

-- | Return the two endpoints, also for a closed line.
lineEnds :: Coordinates -> [Point]
lineEnds line = case coordinatePoints line of
    [] -> []
    points@(first : _) -> [first, last points]

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
pointZ :: Point -> Double
pointZ (PointXYZ (XYZ _ _ z)) = z
pointZ (PointXYZM (XYZM _ _ z _)) = z
pointZ _ = 0 / 0

-- | Multi-line boundaries discard M and share their output coordinate layout.
boundaryPoint :: Bool -> Point -> Point
boundaryPoint withZ point =
    let (x, y) = pointXY point
     in if withZ then PointXYZ (XYZ x y (pointZ point)) else PointXY (XY x y)

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
    MultiPolygon polygons -> all (isSimple . Polygon) (V.toList polygons)
    GeometryCollection children -> all isSimple (V.toList children)

-- | Whether a line string is both closed and simple. Other families return false.
isRing :: Geometry -> Bool
isRing geometry@(LineString line) = case lineEnds line of
    [a, b] -> pointXY a == pointXY b && isSimple geometry
    _ -> False
isRing _ = False

-- | Compare segment intersections after removing adjacent repeated positions.
simpleLines :: [[Position]] -> Bool
simpleLines lines' = all allowed (pairs indexed)
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

-- | Enumerate each unordered pair once.
pairs :: [a] -> [(a, a)]
pairs [] = []
pairs (x : xs) = map ((,) x) xs ++ pairs xs

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
        MultiLineString lines' -> all (validLine . positions) (V.toList lines')
        Polygon rings -> validPolygon (polygonPositions rings)
        MultiPolygon polygons -> all validPolygon rings && all disjointPolygons (pairs (filter (not . all null) rings))
          where
            rings = map polygonPositions (V.toList polygons)
        GeometryCollection children -> all isValid (V.toList children)

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
    | otherwise = all validRing rings && all noOverlap (pairs rings) && all insideShell nonemptyHoles && all separateHoles (pairs nonemptyHoles) && acyclic contacts
  where
    nonemptyHoles = filter (not . null) holes
    rings = shell : nonemptyHoles
    noOverlap (a, b) = not (sharedEdge a b)
    insideShell hole = all ((/= Exterior) . (`ringLocation` shell)) (ringSamples hole shell)
    separateHoles (a, b) = all ((/= Interior) . (`ringLocation` b)) (ringSamples a b) && all ((/= Interior) . (`ringLocation` a)) (ringSamples b a)
    contacts = Set.toList (Set.fromList [(Left k, Right p) | ((i, a), (j, b)) <- pairs (zip [0 :: Int ..] rings), p <- ringIntersections a b, k <- [i, j]])

-- | The intersection positions of two ring boundaries.
ringIntersections :: [Position] -> [Position] -> [Position]
ringIntersections a b = unique (concat [segmentIntersection x y | x <- ringSegments a, y <- ringSegments b])

-- | Whether ring boundaries share a segment of positive length.
sharedEdge :: [Position] -> [Position] -> Bool
sharedEdge a b = any ((> 1) . length) [segmentIntersection x y | x <- ringSegments a, y <- ringSegments b]

-- | Sample every open edge portion after all intersections with another ring.
ringSamples :: [Position] -> [Position] -> [Position]
ringSamples ring other = ringSamplesAgainst ring (ringSegments other)

-- | Split one ring against a set of boundary edges before sampling it.
ringSamplesAgainst :: [Position] -> [Segment] -> [Position]
ringSamplesAgainst ring edges = concatMap sample (ringSegments ring)
  where
    sample edge@(a, b) = map midpoint (lineSegments (unique (a : b : concatMap (segmentIntersection edge) edges)))

-- | A cycle through distinct contact positions disconnects a polygon interior.
acyclic :: [(Either Int Position, Either Int Position)] -> Bool
acyclic = go Map.empty
  where
    root forest x = maybe x (root forest) (Map.lookup x forest)
    go _ [] = True
    go forest ((a, b) : rest)
        | ra == rb = False
        | otherwise = go (Map.insert ra rb forest) rest
      where
        ra = root forest a
        rb = root forest b

-- | Multi-polygons can touch at isolated points but cannot share interior area.
disjointPolygons :: ([[Position]], [[Position]]) -> Bool
disjointPolygons (a, b) =
    not (any (uncurry sharedEdge) [(x, y) | x <- a, y <- b])
        && all ((/= Interior) . (`polygonLocation` b)) (samples a b)
        && all ((/= Interior) . (`polygonLocation` a)) (samples b a)
  where
    samples rings other = concatMap (\ring -> ringSamplesAgainst ring (concatMap ringSegments other)) rings

{- | Choose a representative point with the GEOS selection rules.
For polygons, use a horizontal scan line through the interior. For lines,
choose the interior vertex nearest the centroid, or an endpoint when there
are no interior vertices. Point collections use the point nearest their
centroid. Line results retain Z and discard M.

Empty input gives an empty point. Its layout is XY, XYZ, or XYZM for a source
coordinate count of 2, 3, or 4, respectively.
-}
pointOnSurface :: Geometry -> Point
pointOnSurface geometry = case topologicalDimension geometry of
    0 -> choose False (mapMaybe pointCoordinate (pointMembers geometry))
    1 -> choose True (if null interiors then concatMap endpoints lines' else interiors)
    _ -> case polygonCandidates of
        [] -> emptyResult
        first : rest -> snd (List.foldl' (\best candidate -> if fst candidate > fst best then candidate else best) first rest)
  where
    emptyResult = EmptyPoint (case geometryCoordinateDimension geometry of 3 -> DimXYZ; 4 -> DimXYZM; _ -> DimXY)
    center = selectionCenter geometry
    choose withZ points = case points of
        [] -> emptyResult
        first : rest -> let selected = List.foldl' (\best candidate -> if distance candidate < distance best then candidate else best) first rest in boundaryPoint (withZ && not (isNaN (pointZ selected))) selected
    distance point = let (x, y) = pointXY point; (cx, cy) = center in sqrt ((x - cx) * (x - cx) + (y - cy) * (y - cy))
    lines' = map coordinatePoints (lineMembers geometry)
    interiors = concatMap (drop 1 . takeInterior) lines'
    takeInterior [] = []
    takeInterior points = init points
    endpoints [] = []
    endpoints points@(first : _) = [first, last points]
    polygonCandidates = mapMaybe polygonInterior (polygonMembers geometry)
    pointCoordinate (EmptyPoint _) = Nothing
    pointCoordinate point = Just point

{- | Accumulate the selection centroid in GEOS evaluation order. A rounding
difference can select a different vertex when distances are nearly equal.
-}
selectionCenter :: Geometry -> (Double, Double)
selectionCenter geometry
    | total > 0 = (wx / total, wy / total)
    | otherwise = (sx / count, sy / count)
  where
    (sx, sy, count, wx, wy, total) = accumulate (0, 0, 0, 0, 0, 0) geometry
    addPoint (a, b, n, c, d, len) point = let (x, y) = pointXY point in (a + x, b + y, n + 1, c, d, len)
    accumulate state shape = case shape of
        PointGeometry (EmptyPoint _) -> state
        PointGeometry point -> addPoint state point
        MultiPoint points -> U.foldl' (\acc point -> accumulate acc (PointGeometry point)) state points
        LineString line -> addLine state (coordinatePoints line)
        MultiLineString lines' -> V.foldl' (\acc line -> accumulate acc (LineString line)) state lines'
        GeometryCollection children -> V.foldl' accumulate state children
        _ -> state
    addLine state [] = state
    addLine (a, b, n, c, d, len) points@(first : _) =
        let (u, v, lineLength) = List.foldl' addSegment (c, d, 0) (zip points (drop 1 points))
            next = (a, b, n, u, v, len + lineLength)
         in if lineLength == 0 then addPoint next first else next
    addSegment state@(a, b, len) (first, second) =
        let (x, y) = pointXY first
            (u, v) = pointXY second
            size = sqrt ((u - x) * (u - x) + (v - y) * (v - y))
         in if size == 0 then state else (a + size * ((x + u) / 2), b + size * ((y + v) / 2), len + size)

-- | List atomic point members in input order.
pointMembers :: Geometry -> [Point]
pointMembers (PointGeometry point) = [point]
pointMembers (MultiPoint points) = U.toList points
pointMembers (GeometryCollection children) = concatMap pointMembers (V.toList children)
pointMembers _ = []

-- | List atomic line members in input order.
lineMembers :: Geometry -> [Coordinates]
lineMembers (LineString line) = [line]
lineMembers (MultiLineString lines') = V.toList lines'
lineMembers (GeometryCollection children) = concatMap lineMembers (V.toList children)
lineMembers _ = []

-- | List atomic polygon members in input order.
polygonMembers :: Geometry -> [PolygonRings]
polygonMembers (Polygon rings) = [rings]
polygonMembers (MultiPolygon polygons) = V.toList polygons
polygonMembers (GeometryCollection children) = concatMap polygonMembers (V.toList children)
polygonMembers _ = []

-- | Select the midpoint of the widest horizontal interior interval.
polygonInterior :: PolygonRings -> Maybe (Double, Point)
polygonInterior (PolygonRings shell holes) = case map pointXY (coordinatePoints shell) of
    [] -> Nothing
    shellPoints@((x, y) : _) -> Just (List.foldl' widest (0, PointXY (XY x y)) intervals)
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
        intervals = adjacentPairs crossings
        widest best (a, b) = if b - a > fst best then (b - a, PointXY (XY ((a + b) / 2) scanY)) else best

-- | Pair sorted crossings into interior intervals.
adjacentPairs :: [a] -> [(a, a)]
adjacentPairs (a : b : rest) = (a, b) : adjacentPairs rest
adjacentPairs _ = []
