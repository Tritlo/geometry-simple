-- | Planar set operations over exact segment arrangements.
module Data.Geometry.Topology.Overlay where

import Data.Geometry.Internal
import Data.Geometry.Topology.Planar
import Data.List (minimumBy, sortBy)
import qualified Data.Map.Strict as Map
import Data.Ord (comparing)
import qualified Data.Set as Set
import qualified Data.Vector as V
import qualified Data.Vector.Unboxed as U

-- | The points common to both geometries. Coordinates must have finite XY values.
intersection :: Geometry -> Geometry -> Geometry
intersection a b = overlay (&&) (min (topologicalDimension a) (topologicalDimension b)) a b

-- | The points in either geometry. Coordinates must have finite XY values.
union :: Geometry -> Geometry -> Geometry
union a b = overlay (||) (max (topologicalDimension a) (topologicalDimension b)) a b

-- | The closure of the points in the first geometry but not the second.
difference :: Geometry -> Geometry -> Geometry
difference a b = overlay (\x y -> x && not y) (topologicalDimension a) a b

-- | The closure of the points in exactly one geometry.
symmetricDifference :: Geometry -> Geometry -> Geometry
symmetricDifference a b = overlay (/=) (max (topologicalDimension a) (topologicalDimension b)) a b

-- | Evaluate a Boolean set operation on faces, edges, and vertices.
overlay :: (Bool -> Bool -> Bool) -> TopologicalDimension -> Geometry -> Geometry -> Geometry
overlay select emptyDimension first second
    | earlyEmpty = emptyGeometry emptyDimension
    | separate && singleComponent a && singleComponent b =
        assemble emptyDimension (concatMap planarPolygons retained) (concatMap planarLines retained) (concatMap planarPoints retained)
    | otherwise = assemble emptyDimension polygons paths points
  where
    separate = disjointBounds (allPositions a) (allPositions b)
    retained = [shape | (keep, shape) <- [(select True False, a), (select False True, b)], keep]
    singleComponent shape = length (componentPoints shape) <= 1
    firstEmpty = geometryEmpty first
    secondEmpty = geometryEmpty second
    earlyEmpty = (firstEmpty && not (select False True)) || (secondEmpty && not (select True False)) || (firstEmpty && secondEmpty) || (separate && not (select True False) && not (select False True))
    a = planar first
    b = planar second
    edges = nodeSegments (segments a ++ segments b) (vertices a ++ vertices b)
    queryEdges = segmentQuery edges
    (locateA, insideA) = prepareLocations a
    (locateB, insideB) = prepareLocations b
    selected p = select (locateA p /= Exterior) (locateB p /= Exterior)
    selectedFace p = select (insideA p) (insideB p)
    boundaryEdges =
        [ if leftInside then (u, v) else (v, u)
        | edge@(u, v) <- edges
        , let (left, right) = sidePoints queryEdges edge
        , let leftInside = selectedFace left
        , leftInside /= selectedFace right
        ]
    polygons = polygonize boundaryEdges
    surfaces = Planar [] [] polygons
    (locateSurfaces, _) = prepareLocations surfaces
    lineEdges = [edge | edge <- edges, selected (midpoint edge), locateSurfaces (midpoint edge) == Exterior]
    inputLines = planarLines a ++ planarLines b
    inputLineEdges = concatMap lineSegments inputLines
    allDegrees = degrees (nodeSegments inputLineEdges [])
    endpoints = [p | line@(start : _) <- inputLines, p <- [start, last line]]
    queryLines = segmentQuery inputLineEdges
    overlaps = [p | p <- unique (concat inputLines), any (\edge@(u, v) -> p /= u && p /= v && pointOnSegment p edge) (queryLines (p, p))]
    stops = Set.fromList (endpoints ++ overlaps ++ [p | (p, degree) <- Map.toList allDegrees, degree /= 2])
    paths = linePaths stops lineEdges
    curves = Planar [] paths polygons
    (locateCurves, _) = prepareLocations curves
    nodes = unique (vertices a ++ vertices b ++ concatMap (\(u, v) -> [u, v]) edges)
    points = [p | p <- nodes, selected p, locateCurves p == Exterior]

-- | Collect directed cycles with their selected region on the left.
boundaryRings :: [Segment] -> [[Position]]
boundaryRings edges = concatMap splitRing (collect (Set.fromList edges))
  where
    outgoingEdges = Map.fromListWith Set.union [(a, Set.singleton (a, b)) | (a, b) <- edges]
    collect remaining = case Set.minView remaining of
        Nothing -> []
        Just (edge@(start, _), _) ->
            let (ring, rest) = walk start edge [] remaining
             in ring : collect rest
    walk start edge@(a, b) accumulated remaining
        | b == start = (reverse (b : a : accumulated), rest)
        | otherwise = walk start next (a : accumulated) rest
      where
        rest = Set.delete edge remaining
        outgoing = [candidate | candidate <- Set.toList (Map.findWithDefault Set.empty b outgoingEdges), Set.member candidate rest]
        reverseDirection = subtractPosition a b
        ordered = sortBy (\(_, x) (_, y) -> compareDirection (subtractPosition x b) (subtractPosition y b)) outgoing
        preceding = filter (\(_, c) -> compareDirection (subtractPosition c b) reverseDirection == LT) ordered
        next = case if null preceding then ordered else preceding of
            -- A selected face boundary is closed. Failure here means its graph is inconsistent.
            [] -> error "Open boundary in planar overlay"
            candidates -> last candidates

-- | Separate rings that touch at one vertex without joining their interiors.
splitRing :: [Position] -> [[Position]]
splitRing = walk Set.empty []
  where
    walk _ _ [] = []
    walk seen path (point : rest)
        | Set.notMember point seen = walk (Set.insert point seen) (point : path) rest
        | otherwise = case break (== point) path of
            (_, []) -> walk (Set.insert point seen) (point : path) rest
            (before, _ : after) -> (point : reverse before ++ [point]) : walk (seen `Set.difference` Set.fromList before) (point : after) rest

-- | Twice the signed area of a closed ring.
ringArea :: [Position] -> Rational
ringArea = sum . map (uncurry cross) . ringSegments

-- | Group each clockwise hole with its smallest containing shell.
polygonize :: [Segment] -> [[[Position]]]
polygonize edges = [shell : [hole | hole <- holes, containingShell hole == shell] | shell <- shells]
  where
    rings = boundaryRings edges
    shells = filter ((> 0) . ringArea) rings
    holes = filter ((< 0) . ringArea) rings
    containingShell [] = []
    containingShell (p : _) = case filter ((/= Exterior) . ringLocation p) shells of
        -- Every hole bounds a finite selected region inside an exterior ring.
        [] -> error "Uncontained hole in planar overlay"
        candidates -> minimumBy (comparing (abs . ringArea)) candidates

-- | Count undirected edges at each vertex.
degrees :: [Segment] -> Map.Map Position Int
degrees edges = Map.fromListWith (+) [(p, 1) | (a, b) <- edges, p <- [a, b]]

-- | Join degree-two edges, stopping at source endpoints and intersections.
linePaths :: Set.Set Position -> [Segment] -> [[Position]]
linePaths stops edges = collect (Set.fromList (map canonical edges))
  where
    canonical (a, b) = if a < b then (a, b) else (b, a)
    incidentEdges = Map.fromListWith Set.union [(point, Set.singleton (canonical edge)) | edge@(a, b) <- edges, point <- [a, b]]
    collect remaining
        | Set.null remaining = []
        | otherwise =
            let counts = degrees (Set.toList remaining)
                ends = [p | (p, degree) <- Map.toList counts, degree /= 2 || Set.member p stops]
                start = case ends of
                    p : _ -> p
                    [] -> fst (Set.findMin remaining)
                (path, rest) = walk start start [] remaining
             in path : collect rest
    walk start current accumulated remaining = case neighbors of
        [] -> (reverse (current : accumulated), remaining)
        _ | not (null accumulated) && (current == start || Set.member current stops || length neighbors /= 1) -> (reverse (current : accumulated), remaining)
        next : _ -> walk start next (current : accumulated) (Set.delete (canonical (current, next)) remaining)
      where
        neighbors = [if a == current then b else a | edge@(a, b) <- Set.toList (Map.findWithDefault Set.empty current incidentEdges), Set.member edge remaining]

-- | Construct the smallest XY family that holds the selected components.
assemble :: TopologicalDimension -> [[[Position]]] -> [[Position]] -> [Position] -> Geometry
assemble emptyDimension polygons lines' points = case parts of
    [] -> emptyGeometry emptyDimension
    [part] -> part
    _ -> GeometryCollection (V.fromList (concatMap atomic parts))
  where
    parts = pointParts ++ lineParts ++ polygonParts
    pointParts = case map planarPoint points of
        [] -> []
        [point] -> [PointGeometry point]
        values -> [MultiPoint (U.fromList values)]
    lineParts = case map coordinates (filter (not . null) lines') of
        [] -> []
        [line] -> [LineString line]
        values -> [MultiLineString (V.fromList values)]
    polygonParts = case [PolygonRings (coordinates (oriented GT shell)) (V.fromList (map (coordinates . oriented LT) holes)) | shell : holes <- polygons, not (null shell)] of
        [] -> []
        [rings] -> [Polygon rings]
        values -> [MultiPolygon (V.fromList values)]
    coordinates = CoordinatesXY . U.fromList . map (\(x, y) -> XY (fromRational x) (fromRational y))
    oriented direction ring = if compare (ringArea ring) 0 == direction then ring else reverse ring
    atomic geometry = case geometry of
        MultiPoint values -> map PointGeometry (U.toList values)
        MultiLineString values -> map LineString (V.toList values)
        MultiPolygon values -> map Polygon (V.toList values)
        _ -> [geometry]

-- | Construct an empty XY geometry of the requested topological dimension.
emptyGeometry :: TopologicalDimension -> Geometry
emptyGeometry dimension = case dimension of
    PointDimension -> PointGeometry (EmptyPoint DimXY)
    CurveDimension -> LineString (CoordinatesXY U.empty)
    SurfaceDimension -> Polygon (PolygonRings (CoordinatesXY U.empty) V.empty)
    NoDimension -> GeometryCollection V.empty
