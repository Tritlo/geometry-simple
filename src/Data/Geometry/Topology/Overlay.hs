-- | Planar set operations over exact segment arrangements.
module Data.Geometry.Topology.Overlay where

import Data.Geometry.Internal
import Data.Geometry.Topology.Planar
import Data.List (maximumBy, minimumBy)
import qualified Data.List as List
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe)
import Data.Ord (comparing)
import qualified Data.Set as Set
import qualified Data.Vector as V
import qualified Data.Vector.Unboxed as U

{- | The points common to both geometries. Coordinates must have finite XY values.
Line results join consecutive edges through vertices with exactly two neighbors.
Their component count and order can differ from other implementations.
-}
intersection :: Geometry -> Geometry -> Geometry
intersection a b = overlay (&&) (min (topologicalDimension a) (topologicalDimension b)) a b

-- | The points in either geometry. Coordinates must have finite XY values.
union :: Geometry -> Geometry -> Geometry
union a b = overlay (||) (max (topologicalDimension a) (topologicalDimension b)) a b

-- | The closure of the points in the first geometry but not the second.
difference :: Geometry -> Geometry -> Geometry
difference a = overlay (\x y -> x && not y) (topologicalDimension a) a

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
    a = planar first
    b = planar second
    earlyEmpty = (firstEmpty && not (select False True)) || (secondEmpty && not (select True False)) || (firstEmpty && secondEmpty) || (separate && not (select True False) && not (select False True))
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
    paths = linePaths lineEdges
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
        outgoing = Set.toList (Set.intersection (Map.findWithDefault Set.empty b outgoingEdges) rest)
        reverseDirection = subtractPosition a b
        preceding = filter (\(_, c) -> compareDirection (subtractPosition c b) reverseDirection == LT) outgoing
        next = case if null preceding then outgoing else preceding of
            -- A selected face boundary is closed. Failure here means its graph is inconsistent.
            [] -> error "Open boundary in planar overlay"
            candidates -> maximumBy (\(_, x) (_, y) -> compareDirection (subtractPosition x b) (subtractPosition y b)) candidates

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

-- | Find a simple ring's orientation at its lexicographically smallest vertex.
ringOrientation :: [Position] -> Ordering
ringOrientation ring = case ringSegments ring of
    [] -> EQ
    edges ->
        let (before, at) = minimumBy (comparing snd) edges
         in case [after | (start, after) <- edges, start == at] of
                after : _ -> orientation before at after
                [] -> EQ

-- | Group each clockwise hole with its innermost containing shell.
polygonize :: [Segment] -> [[[Position]]]
polygonize edges = [shell : Map.findWithDefault [] shell groupedHoles | (shell, _) <- shells]
  where
    rings = [(ringOrientation ring, ring) | ring <- boundaryRings edges]
    shells = [(ring, prepareRing ring) | (GT, ring) <- rings]
    holes = [ring | (LT, ring) <- rings]
    groupedHoles = Map.fromListWith (++) [(containingShell hole, [hole]) | hole <- holes]
    containingShell hole = case ringSegments hole of
        [] -> []
        edge : _ -> case filter (\(_, locate) -> locate (midpoint edge) == Interior) shells of
            -- Every hole bounds a finite selected region inside an exterior ring.
            [] -> error "Uncontained hole in planar overlay"
            first : rest -> fst (List.foldl' innermost first rest)
    innermost current@(_, locate) candidate@(ring, _) = case ringSegments ring of
        edge : _ | locate (midpoint edge) == Interior -> candidate
        _ -> current

-- | Join edges through degree-two vertices. Stop at endpoints and branches.
linePaths :: [Segment] -> [[Position]]
linePaths edges = collect (neighbors, starts)
  where
    neighbors = Map.fromListWith Set.union [(a, Set.singleton b) | (p, q) <- edges, (a, b) <- [(p, q), (q, p)]]
    starts = Map.keysSet (Map.filter isStart neighbors)
    isStart adjacent = not (Set.null adjacent) && Set.size adjacent /= 2
    collect remaining@(graph, ends) = case Map.lookupMin graph of
        Nothing -> []
        Just (first, _) ->
            let start = fromMaybe first (Set.lookupMin ends)
                (path, rest) = walk start start [] remaining
             in path : collect rest
    walk start current accumulated remaining@(graph, _) = case Set.lookupMin adjacent of
        Nothing -> (reverse (current : accumulated), remaining)
        _ | not (null accumulated) && (current == start || Set.size adjacent /= 1) -> (reverse (current : accumulated), remaining)
        Just next -> walk start next (current : accumulated) (removeNeighbor current next (removeNeighbor next current remaining))
      where
        adjacent = Map.findWithDefault Set.empty current graph
    removeNeighbor neighbor point (graph, ends) =
        let adjacent = Set.delete neighbor (Map.findWithDefault Set.empty point graph)
            nextGraph = if Set.null adjacent then Map.delete point graph else Map.insert point adjacent graph
            nextEnds = if isStart adjacent then Set.insert point ends else Set.delete point ends
         in (nextGraph, nextEnds)

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
    oriented direction ring = if ringOrientation ring == direction then ring else reverse ring

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
