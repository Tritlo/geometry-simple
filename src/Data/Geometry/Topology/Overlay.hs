-- | Planar set operations over exact segment arrangements.
module Data.Geometry.Topology.Overlay where

import Data.Geometry.Internal
import qualified Data.Geometry.Topology.Ordinates as Ordinates
import Data.Geometry.Topology.Planar
import Data.List (minimumBy, sortBy)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe, mapMaybe)
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
overlay :: (Bool -> Bool -> Bool) -> Int -> Geometry -> Geometry -> Geometry
overlay select emptyDimension first second
    | unfilled = assembleComponents (geometryDimensions fullSource) emptyDimension copiedPoints copiedLines copiedPolygons
    | earlyEmpty = emptyGeometry DimXY emptyDimension
    | geometryEmpty result && any isCollection [first, second] = result
    | otherwise = Ordinates.populateElevation fullSource result
  where
    fullSource = GeometryCollection (V.fromList [first, second])
    copied = filter (not . geometryEmpty) (atomicGeometries fullSource)
    copiedPoints = [point | PointGeometry point <- copied]
    copiedLines = [line | LineString line <- copied]
    copiedPolygons = [polygon | Polygon polygon <- copied]
    firstEmpty = geometryEmpty first
    secondEmpty = geometryEmpty second
    earlyEmpty = (firstEmpty && not (select False True)) || (secondEmpty && not (select True False)) || (firstEmpty && secondEmpty) || (disjointBounds (vertices a) (vertices b) && not (select True False) && not (select False True))
    assembled = restorePoints (assembleComponents layout emptyDimension (map pointFor points) (map lineCoordinates paths) polygonValues)
    result = if geometryEmpty assembled then emptyGeometry DimXY emptyDimension else assembled
    isCollection (GeometryCollection _) = True
    isCollection _ = False
    a = planar first
    b = planar second
    source = Ordinates.overlaySources select (nonpointSource first) (nonpointSource second)
    nonpointSource shape = if topologicalDimension shape == 0 then GeometryCollection V.empty else withoutCoveredPoints shape
    layout = geometryDimensions source
    edges = nodeSegments (segments a ++ segments b) (vertices a ++ vertices b)
    selected p = select (locate a p /= Exterior) (locate b p /= Exterior)
    selectedFace p = select (polygonContains a p) (polygonContains b p)
    boundaryEdges =
        [ if leftInside then (u, v) else (v, u)
        | edge@(u, v) <- edges
        , let (left, right) = sidePoints edges edge
        , let leftInside = selectedFace left
        , leftInside /= selectedFace right
        ]
    polygons = polygonize boundaryEdges
    surfaces = Planar [] [] polygons
    lineEdges = [edge | edge <- edges, selected (midpoint edge), locate surfaces (midpoint edge) == Exterior]
    inputLines = planarLines a ++ planarLines b
    inputLineEdges = concatMap lineSegments inputLines
    allDegrees = degrees (nodeSegments inputLineEdges [])
    endpoints = [p | line@(start : _) <- inputLines, p <- [start, last line]]
    overlaps = [p | p <- unique (concat inputLines), any (\edge@(u, v) -> p /= u && p /= v && pointOnSegment p edge) inputLineEdges]
    stops = Set.fromList (endpoints ++ overlaps ++ [p | (p, degree) <- Map.toList allDegrees, degree /= 2])
    paths = linePaths stops lineEdges
    curves = Planar [] paths polygons
    nodes = unique (vertices a ++ vertices b ++ concatMap (\(u, v) -> [u, v]) edges)
    points = [p | p <- nodes, selected p, locate curves p == Exterior]
    unfilled = select True False && select False True && disjointBounds (vertices a) (vertices b) && all singleNonempty [first, second]
    singleNonempty (GeometryCollection children) = length (filter singleNonempty (V.toList children)) == 1
    singleNonempty geometry = not (geometryEmpty geometry)
    nodedPaths = Ordinates.nodeSourcePaths source
    pointFor p = case Ordinates.overlayPoint source nodedPaths p of
        PointXYM (XYM x y m) | isNaN m -> PointXY (XY x y)
        PointXYZM (XYZM x y z m) | isNaN m -> PointXYZ (XYZ x y z)
        point -> point
    lineCoordinates = Ordinates.overlayCoordinates source nodedPaths
    ringCoordinates = Ordinates.overlayCoordinates source nodedPaths . reverse
    polygonValues = [PolygonRings (ringCoordinates shell) (V.fromList (map ringCoordinates holes)) | shell : holes <- polygons]
    inputPoints = concatMap storedPoints [shape | shape <- [first, second], topologicalDimension shape == 0]
    original point = case withPoint position point of
        Nothing -> point
        Just p -> fromMaybe point (lookup p [(q, candidate) | candidate <- inputPoints, Just q <- [withPoint position candidate]])
    restorePoints geometry = case geometry of
        PointGeometry point -> PointGeometry (original point)
        MultiPoint values -> MultiPoint (U.map original values)
        GeometryCollection children -> GeometryCollection (V.map restorePoints children)
        _ -> geometry

-- | Collect point atoms, including empty points, from a zero-dimensional input.
storedPoints :: Geometry -> [Point]
storedPoints geometry = case geometry of
    PointGeometry point -> [point]
    MultiPoint values -> U.toList values
    GeometryCollection children -> concatMap storedPoints (V.toList children)
    _ -> []

-- | Expand collection wrappers while retaining their atomic members.
atomicGeometries :: Geometry -> [Geometry]
atomicGeometries geometry = case geometry of
    MultiPoint points -> map PointGeometry (U.toList points)
    MultiLineString lines' -> map LineString (V.toList lines')
    MultiPolygon polygons -> map Polygon (V.toList polygons)
    GeometryCollection children -> concatMap atomicGeometries (V.toList children)
    _ -> [geometry]

-- | Exclude point components already represented by a line or a polygon.
withoutCoveredPoints :: Geometry -> Geometry
withoutCoveredPoints geometry = GeometryCollection (V.fromList (filter retained atoms))
  where
    atoms = atomicGeometries geometry
    nonpoints = planar (GeometryCollection (V.fromList [shape | shape <- atoms, topologicalDimension shape > 0]))
    retained (PointGeometry point) = maybe True ((== Exterior) . locate nonpoints) (withPoint position point)
    retained _ = True

-- | Collect directed cycles with their selected region on the left.
boundaryRings :: [Segment] -> [[Position]]
boundaryRings edges = concatMap splitRing (collect (Set.fromList edges))
  where
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
        outgoing = [(b, c) | (from, c) <- Set.toList rest, from == b]
        reverseDirection = subtractPosition a b
        ordered = sortBy (\(_, x) (_, y) -> compareDirection (subtractPosition x b) (subtractPosition y b)) outgoing
        preceding = filter (\(_, c) -> compareDirection (subtractPosition c b) reverseDirection == LT) ordered
        next = case if null preceding then ordered else preceding of
            [] -> error "Open boundary in planar overlay"
            candidates -> last candidates

-- | Separate rings that touch at one vertex without joining their interiors.
splitRing :: [Position] -> [[Position]]
splitRing = walk []
  where
    walk _ [] = []
    walk path (point : rest) = case break (== point) path of
        (_, []) -> walk (point : path) rest
        (before, _ : after) -> (point : reverse before ++ [point]) : walk (point : after) rest

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
        neighbors = [if a == current then b else a | (a, b) <- Set.toList remaining, a == current || b == current]

-- | Construct the smallest family that holds the selected components.
assemble :: Dimensions -> Int -> (Position -> Point) -> [[[Position]]] -> [[Position]] -> [Position] -> Geometry
assemble layout emptyDimension pointFor polygons lines' points = assembleComponents layout emptyDimension (map pointFor points) (map coordinates lines') (mapMaybe polygon polygons)
  where
    polygon [] = Nothing
    polygon (shell : holes) = Just (PolygonRings (coordinates (reverse shell)) (V.fromList (map (coordinates . reverse) holes)))
    coordinates = pointsCoordinates layout . map pointFor

-- | Assemble already constructed atomic values into a flat result.
assembleComponents :: Dimensions -> Int -> [Point] -> [Coordinates] -> [PolygonRings] -> Geometry
assembleComponents layout emptyDimension points lines' polygons = case parts of
    [] -> emptyGeometry (if layout `elem` [DimXYZ, DimXYZM] then DimXYZ else DimXY) emptyDimension
    [part] -> part
    _ -> GeometryCollection (V.fromList (concatMap atomic parts))
  where
    parts = pointParts ++ lineParts ++ polygonParts
    pointParts = case points of
        [] -> []
        [p] -> [PointGeometry p]
        values -> [MultiPoint (U.fromList values)]
    lineParts = case lines' of
        [] -> []
        [line] -> [LineString line]
        values -> [MultiLineString (V.fromList values)]
    polygonParts = case polygons of
        [] -> []
        [rings] -> [Polygon rings]
        values -> [MultiPolygon (V.fromList values)]
    atomic geometry = case geometry of
        MultiPoint values -> map PointGeometry (U.toList values)
        MultiLineString values -> map LineString (V.toList values)
        MultiPolygon values -> map Polygon (V.toList values)
        _ -> [geometry]

-- | Construct an empty atomic geometry of a requested dimension.
emptyGeometry :: Dimensions -> Int -> Geometry
emptyGeometry layout dimension = case dimension of
    0 -> PointGeometry (EmptyPoint layout)
    1 -> LineString (emptyCoordinates layout)
    2 -> Polygon (PolygonRings (emptyCoordinates layout) V.empty)
    _ -> GeometryCollection V.empty

-- | Pack points into a coordinate sequence, padding absent ordinates with NaN.
pointsCoordinates :: Dimensions -> [Point] -> Coordinates
pointsCoordinates layout points = case layout of
    DimXY -> CoordinatesXY (U.fromList [XY x y | (x, y, _, _) <- rows])
    DimXYZ -> CoordinatesXYZ (U.fromList [XYZ x y z | (x, y, z, _) <- rows])
    DimXYM -> CoordinatesXYM (U.fromList [XYM x y m | (x, y, _, m) <- rows])
    DimXYZM -> CoordinatesXYZM (U.fromList [XYZM x y z m | (x, y, z, m) <- rows])
  where
    rows = map row points
    row point = case withPoint coordinateComponents point of
        Nothing -> (nan, nan, nan, nan)
        Just (x, y, z, m) ->
            let source = pointDimensions point
             in (x, y, if source `elem` [DimXYZ, DimXYZM] then z else nan, if source `elem` [DimXYM, DimXYZM] then m else nan)
    nan = 0 / 0
