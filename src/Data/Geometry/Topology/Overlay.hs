{- | Planar set operations over exact segment arrangements.

Precision retries use five snapping tolerances. The first is the largest
absolute ordinate in a group divided by 10^12. Use at least the smallest
positive Double. Each later attempt multiplies this tolerance by ten. All attempts
start from the original inputs. The schedule follows
<https://github.com/libgeos/geos/blob/3.13.1/include/geos/operation/overlayng/OverlayNGRobust.h GEOS OverlayNGRobust>.
-}
module Data.Geometry.Topology.Overlay where

import Control.Exception (Exception, throw)
import Data.Geometry.Internal
import Data.Geometry.Topology.Planar
import Data.Geometry.Topology.Snapping (snapPlanars)
import Data.Geometry.Topology.Unary (isValid)
import qualified Data.Graph as Graph
import Data.List (find, maximumBy, minimumBy)
import qualified Data.List as List
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe)
import Data.Ord (comparing)
import qualified Data.Set as Set
import Data.Tree (flatten)
import qualified Data.Vector as V
import qualified Data.Vector.Unboxed as U

{- | A rounded overlay remains invalid after the bounded snapping attempts.
Catch this exception when evaluating an overlay result. No invalid geometry is
returned when the available Double precision cannot represent the topology.
-}
data TopologyException
    = -- | Exact overlay and all five snapping attempts produced invalid output.
      OverlayPrecisionFailure
    deriving (Eq, Show, Read)

-- | Report a precision failure through the standard exception interface.
instance Exception TopologyException

{- | The points common to both geometries. Coordinates must have finite XY values.
Line results join consecutive edges through vertices with exactly two neighbors.
Their component count and order can differ from other implementations.
If Double rounding changes topology, retry with bounded snapping. Thin regions
can collapse. Throw 'OverlayPrecisionFailure' if every attempt remains invalid.
See the module documentation for the tolerance schedule.
-}
intersection :: Geometry -> Geometry -> Geometry
intersection a b = overlay (&&) (min (topologicalDimension a) (topologicalDimension b)) a b

-- | The points in either geometry. The precision and failure rules match 'intersection'.
union :: Geometry -> Geometry -> Geometry
union a b = overlay (||) (max (topologicalDimension a) (topologicalDimension b)) a b

{- | The closure of the points in the first geometry but not the second.
The precision and failure rules match 'intersection'.
-}
difference :: Geometry -> Geometry -> Geometry
difference a = overlay (\x y -> x && not y) (topologicalDimension a) a

{- | The closure of the points in exactly one geometry.
The precision and failure rules match 'intersection'.
-}
symmetricDifference :: Geometry -> Geometry -> Geometry
symmetricDifference a b = overlay (/=) (max (topologicalDimension a) (topologicalDimension b)) a b

{- | Try exact overlay first. If output rounding breaks topology, retry each
connected group with five snapping tolerances from magnitude / 10^12 to
magnitude / 10^8. Each attempt starts from the original inputs. These bounds
follow GEOS OverlayNGRobust; separate groups keep their own precision scale.
-}
overlay :: (Bool -> Bool -> Bool) -> TopologicalDimension -> Geometry -> Geometry -> Geometry
overlay select emptyDimension first second
    | Just unchanged <- trivialOverlay select emptyDimension a b = unchanged
    | isValid exact = exact
    | otherwise = assemble emptyDimension (planarPolygons result) (planarLines result) (planarPoints result)
  where
    a = planar first
    b = planar second
    exact = overlayPlanar select emptyDimension a b
    result = combinePlanar [planar (robust x y) | (x, y) <- overlayGroups a b]
    robust x y = fromMaybe (throw OverlayPrecisionFailure) (find isValid attempts)
      where
        magnitude = maximum (0 : [max (abs u) (abs v) | (u, v) <- allPositions x ++ allPositions y])
        minimumSpacing = toRational (encodeFloat 1 (fst (floatRange (0 :: Double)) - floatDigits (0 :: Double)) :: Double)
        tolerance = max minimumSpacing (magnitude / 10 ^ (12 :: Int))
        attempts =
            overlayPlanar select emptyDimension x y
                : [ let (snappedA, snappedB) = snapPlanars (tolerance * 10 ^ attemptIndex) x y
                     in overlayPlanar select emptyDimension snappedA snappedB
                  | attemptIndex <- [0 :: Int .. 4]
                  ]

-- | Group atomic inputs with overlapping bounds before a precision retry.
overlayGroups :: Planar -> Planar -> [(Planar, Planar)]
overlayGroups first second = map group (Graph.components graph)
  where
    parts shape = [Planar [p] [] [] | p <- planarPoints shape] ++ [Planar [] [line] [] | line <- planarLines shape] ++ [Planar [] [] [polygon] | polygon <- planarPolygons shape]
    inputs = [(side, part) | (side, shape) <- [(False, first), (True, second)], part <- parts shape, not (null (allPositions part))]
    pairs = overlappingPairs [(bounds, i) | (i, (_, part)) <- zip [0 :: Int ..] inputs, Just bounds <- [pointBounds (allPositions part)]]
    adjacent = Map.fromListWith (++) [(a, [b]) | (i, j) <- pairs, (a, b) <- [(i, j), (j, i)]]
    (graph, entry, _) = Graph.graphFromEdges [(part, i, Map.findWithDefault [] i adjacent) | (i, part) <- zip [0 :: Int ..] inputs]
    group tree =
        let members = [part | vertex <- flatten tree, let (part, _, _) = entry vertex]
         in (combinePlanar [part | (False, part) <- members], combinePlanar [part | (True, part) <- members])

-- | Handle empty or disjoint single components without new intersection coordinates.
trivialOverlay :: (Bool -> Bool -> Bool) -> TopologicalDimension -> Planar -> Planar -> Maybe Geometry
trivialOverlay select emptyDimension a b
    | earlyEmpty = Just (emptyGeometry emptyDimension)
    | separate && singleComponent a && singleComponent b =
        Just (assemble emptyDimension (concatMap planarPolygons retained) (concatMap planarLines retained) (concatMap planarPoints retained))
    | otherwise = Nothing
  where
    separate = disjointBounds (allPositions a) (allPositions b)
    retained = [shape | (keep, shape) <- [(select True False, a), (select False True, b)], keep]
    singleComponent shape = length (componentPoints shape) <= 1
    firstEmpty = null (allPositions a)
    secondEmpty = null (allPositions b)
    earlyEmpty = (firstEmpty && not (select False True)) || (secondEmpty && not (select True False)) || (firstEmpty && secondEmpty) || (separate && not (select True False) && not (select False True))

-- | Evaluate a Boolean set operation on exact faces, edges, and vertices.
overlayPlanar :: (Bool -> Bool -> Bool) -> TopologicalDimension -> Planar -> Planar -> Geometry
overlayPlanar select emptyDimension a b = assemble emptyDimension polygons paths points
  where
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
