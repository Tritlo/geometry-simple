-- | Preserve and interpolate optional ordinates during planar overlay.
module Data.Geometry.Topology.Ordinates (
    Sample,
    sourcePaths,
    overlaySources,
    nodeSourcePaths,
    overlayPoint,
    overlayCoordinates,
    interpolatedPoint,
    interpolatedCoordinateSequence,
    elevationModel,
    populateElevation,
) where

import Data.Geometry.Internal
import Data.Geometry.Topology.Planar (Position, orientation, overlapsBounds, pointOnSegment, position, positions, segmentIntersection, subtractPosition, unique)
import qualified Data.List as List
import qualified Data.Map.Strict as Map
import Data.Maybe (catMaybes, fromMaybe, listToMaybe, mapMaybe)
import Data.Ord (comparing)
import qualified Data.Vector as V
import qualified Data.Vector.Unboxed as U

{- | Prepare ordinates for the native overlay clipping stage.
GEOS 3.13's RingClipper copies XYZ coordinates, so clipped rings lose M.
Its robust envelope contains every segment that can contribute to the result.
We retain the original XY segments and apply only this ordinate conversion.
See <https://github.com/libgeos/geos/blob/3.13.1/src/operation/overlayng/OverlayUtil.cpp>.
-}
overlaySources :: (Bool -> Bool -> Bool) -> Geometry -> Geometry -> Geometry
overlaySources select first second
    | select False True || null firstPoints || null secondPoints = combined
    | otherwise = visit combined
  where
    combined = GeometryCollection (V.fromList [first, second])
    firstPoints = map fst (concat (sourcePaths first))
    secondPoints = map fst (concat (sourcePaths second))
    extent points = ((minimum (map fst points), minimum (map snd points)), (maximum (map fst points), maximum (map snd points)))
    expand ((x, y), (u, v)) = ((x - margin, y - margin), (u + margin, v + margin))
      where
        width = u - x
        height = v - y
        margin = (if min width height > 0 then min width height else max width height) / 10
    ((ax, ay), (au, av)) = expand (extent firstPoints)
    ((bx, by), (bu, bv)) = expand (extent secondPoints)
    target = if select True False then ((ax, ay), (au, av)) else ((max ax bx, max ay by), (min au bu, min av bv))
    rings geometry = case geometry of
        Polygon (PolygonRings shell holes) -> map positions (shell : V.toList holes)
        MultiPolygon values -> concatMap (rings . Polygon) (V.toList values)
        GeometryCollection values -> concatMap rings (V.toList values)
        _ -> []
    segments = [(a, b) | ring <- rings combined, (a, b) <- zip ring (drop 1 ring)]
    ((lx, ly), (ux, uy)) = expand (extent (fst target : snd target : [p | (a, b) <- segments, overlapsBounds target (extent [a, b]), p <- [a, b]]))
    inside (x, y) = lx <= x && x <= ux && ly <= y && y <= uy
    sequenceM coordinates
        | all inside (positions coordinates) = coordinates
        | otherwise = case coordinates of
            CoordinatesXYM values -> CoordinatesXYM (U.map (\(XYM x y _) -> XYM x y (0 / 0)) values)
            CoordinatesXYZM values -> CoordinatesXYZM (U.map (\(XYZM x y z _) -> XYZM x y z (0 / 0)) values)
            _ -> coordinates
    polygon (PolygonRings shell holes) = PolygonRings (sequenceM shell) (V.map sequenceM holes)
    visit geometry = case geometry of
        Polygon value -> Polygon (polygon value)
        MultiPolygon values -> MultiPolygon (V.map polygon values)
        GeometryCollection values -> GeometryCollection (V.map visit values)
        _ -> geometry

-- | A source XY position and its optional Z and M values.
type Sample = (Position, (Maybe Double, Maybe Double))

-- | Collect source paths. Each nonempty point contributes a one-point path.
sourcePaths :: Geometry -> [[Sample]]
sourcePaths geometry = case geometry of
    PointGeometry point -> maybe [] (\sample -> [[sample]]) (withPoint (sampleWith (pointDimensions point)) point)
    LineString line -> [path line]
    Polygon (PolygonRings shell holes) -> map path (shell : V.toList holes)
    MultiPoint points -> concatMap (sourcePaths . PointGeometry) (U.toList points)
    MultiLineString lines' -> concatMap (sourcePaths . LineString) (V.toList lines')
    MultiPolygon polygons -> concatMap (sourcePaths . Polygon) (V.toList polygons)
    GeometryCollection children -> concatMap sourcePaths (V.toList children)
  where
    path coordinates = withCoordinates (map (sampleWith (dimensionsOf coordinates)) . U.toList) coordinates
    sampleWith layout coordinate =
        let (_, _, z, m) = coordinateComponents coordinate
            present value = if isNaN value then Nothing else Just value
         in ( position coordinate
            ,
                ( if layout `elem` [DimXYZ, DimXYZM] then present z else Nothing
                , if layout `elem` [DimXYM, DimXYZM] then present m else Nothing
                )
            )

{- | Split source paths at intersections and retain the ordinate provenance.
A split edge starts with its intersection value. If its last point is an
original vertex, it retains that vertex's original values. This distinction
matters when adjacent edges carry different or missing Z/M values.
Monotone chains use the native STR tree's ten-item groups to order intersections.
See <https://github.com/libgeos/geos/blob/3.13.1/src/noding/SegmentNodeList.cpp>.
-}
nodeSourcePaths :: Geometry -> [[Sample]]
nodeSourcePaths geometry = concatMap split indexed
  where
    indexed = zip [0 :: Int ..] (sourcePaths geometry)
    sourceEdges (pathId, path) = [(pathId, index, a, b) | (index, (a, b)) <- zip [0 :: Int ..] (zip path (drop 1 path)), fst a /= fst b]
    quadrant (_, _, (a, _), (b, _)) = let (x, y) = subtractPosition b a in (x >= 0, y >= 0)
    chains = concatMap (List.groupBy (\a b -> quadrant a == quadrant b) . sourceEdges) indexed
    center axis chain = let values = [axis point | (_, _, (a, _), (b, _)) <- chain, point <- [a, b]] in minimum values + maximum values
    slices = max 1 (ceiling (sqrt (fromIntegral ((length chains + 9) `div` 10) :: Double)))
    capacity = max 1 ((length chains + slices - 1) `div` slices)
    chunks [] = []
    chunks values = let (chunk, rest) = splitAt capacity values in chunk : chunks rest
    ordered = concatMap (List.sortOn (center snd)) (chunks (List.sortOn (center fst) chains))
    pairs = [(a, b) | chain : rest <- List.tails ordered, other <- rest, a <- chain, b <- other]
    intersections =
        [ (key, (p, extras))
        | (first@(pathA, indexA, a, b), second@(pathB, indexB, c, d)) <- pairs
        , let points = segmentIntersection (fst a, fst b) (fst c, fst d)
        , not (pathA == pathB && abs (indexA - indexB) == 1 && length points == 1)
        , p <- points
        , let extras = intersectionExtras p (a, b) (c, d)
        , key <- [nodeKey first p, nodeKey second p]
        ]
    nodeKey (pathId, index, _, b) p = (pathId, if p == fst b then index + 1 else index, p)
    endpoints = [((pathId, index, fst sample), sample) | (pathId, path) <- indexed, (index, sample) <- take 1 (zip [0 ..] path) ++ take 1 (reverse (zip [0 ..] path))]
    nodes = Map.fromListWith (\_ old -> old) (intersections ++ endpoints)
    split (pathId, path) =
        let pathNodes = List.sortBy (comparing order) [(index, sample) | ((pid, index, _), sample) <- Map.toList nodes, pid == pathId]
            order (index, (p, _)) = (index, distanceSquared p (fst (path !! index)))
            distanceSquared (x, y) (u, v) = (x - u) ^ (2 :: Int) + (y - v) ^ (2 :: Int)
            piece (start, first) (end, final)
                | start == end = [first, final]
                | otherwise = first : take (end - start) (drop (start + 1) path) ++ [final | fst final /= fst (path !! end)]
         in [piece a b | (a, b) <- zip pathNodes (drop 1 pathNodes)]

-- | Select endpoint values or interpolate both crossing segments.
intersectionExtras :: Position -> (Sample, Sample) -> (Sample, Sample) -> (Maybe Double, Maybe Double)
intersectionExtras p first@(a, b) second@(c, d) = (value fst, value snd)
  where
    onFirst sample = pointOnSegment (fst sample) (fst a, fst b)
    onSecond sample = pointOnSegment (fst sample) (fst c, fst d)
    collinear = all ((== EQ) . orientation (fst a) (fst b) . fst) [c, d]
    candidates
        | not collinear = [a, b, c, d]
        | onFirst c && onFirst d = [c, d, a, b]
        | onSecond a && onSecond b = [a, b, c, d]
        | otherwise = filter onFirst [c, d] ++ filter onSecond [a, b]
    value select = case [sample | sample <- candidates, fst sample == p] of
        sample : rest -> case select (snd sample) of
            Just ordinate -> Just ordinate
            Nothing -> case mapMaybe (select . snd) rest of
                ordinate : _ -> Just ordinate
                [] -> segmentOrdinate select p (if fst a == p || fst b == p then second else first)
        [] -> case mapMaybe (segmentOrdinate select p) [first, second] of
            [] -> Nothing
            ordinates -> Just (average ordinates)

-- | Build a graph node from the first source edge that contains it.
overlayPoint :: Geometry -> [[Sample]] -> Position -> Point
overlayPoint full paths p = case [sample | path <- paths, sample <- path, fst sample == p] of
    sample : _ -> samplePoint full sample
    [] -> interpolatedPoint full p

-- | Copy output ordinates from directed source edges after noding.
overlayCoordinates :: Geometry -> [[Sample]] -> [Position] -> Coordinates
overlayCoordinates full paths output = packPoints (geometryDimensions full) (map build entries)
  where
    closed = length output > 1 && take 1 output == take 1 (reverse output)
    previous = (if closed then take 1 (drop 1 (reverse output)) else take 1 output) ++ output
    entries = zip3 (map Just previous) output (map Just (drop 1 output) ++ [Nothing])
    sourceEdges = [(a, b) | path <- paths, (a, b) <- zip path (drop 1 path)]
    choose p neighbor = listToMaybe [(a, b) | (a, b) <- sourceEdges, pointOnSegment p (fst a, fst b), pointOnSegment neighbor (fst a, fst b), p /= neighbor]
    build (before, p, after) =
        let edge = case before >>= choose p of
                Just value -> Just value
                Nothing -> after >>= choose p
            sample = case edge of
                Just (a, _) | p == fst a -> Just a
                Just (_, b) | p == fst b -> Just b
                Just pair -> Just (p, (segmentOrdinate fst p pair, segmentOrdinate snd p pair))
                Nothing -> Nothing
         in maybe (overlayPoint full paths p) (samplePoint full) sample

-- | Fill an absent elevation without replacing a source edge's missing M.
samplePoint :: Geometry -> Sample -> Point
samplePoint full ((x, y), (z, m)) = pointFromComponents (geometryDimensions full) (fromRational x, fromRational y, fromMaybe (elevationModel full (x, y)) z, fromMaybe (0 / 0) m)

-- | Pack a sequence with its aggregate source layout.
packPoints :: Dimensions -> [Point] -> Coordinates
packPoints layout points = case layout of
    DimXY -> CoordinatesXY (U.fromList [XY x y | (x, y, _, _) <- rows])
    DimXYZ -> CoordinatesXYZ (U.fromList [XYZ x y z | (x, y, z, _) <- rows])
    DimXYM -> CoordinatesXYM (U.fromList [XYM x y m | (x, y, _, m) <- rows])
    DimXYZM -> CoordinatesXYZM (U.fromList [XYZM x y z m | (x, y, z, m) <- rows])
  where
    rows = map (fromMaybe (0 / 0, 0 / 0, 0 / 0, 0 / 0) . withPoint coordinateComponents) points

{- | Preserve source vertices and interpolate segment intersections.
Use the mean of incident segment values at a new intersection. Fill missing
Z values from the source elevation model. Missing M values remain NaN.
-}
interpolatedPoint :: Geometry -> Position -> Point
interpolatedPoint geometry = pointInterpolator (elevationModel geometry) geometry

{- | Interpolate an output path with its source vertices. The second geometry
contains the candidate source paths. Adjacent output segments select between
source paths that share a vertex. New intersections use the full first
geometry. Output layouts include the ordinates present in the full source.
-}
interpolatedCoordinateSequence :: Geometry -> Geometry -> [Position] -> Coordinates
interpolatedCoordinateSequence full preferred output = packPoints (geometryDimensions full) (map build entries)
  where
    paths = sourcePaths preferred
    fallback = interpolatedPoint full
    original = originalPoint full
    entries = zip3 (Nothing : map Just output) output (map Just (drop 1 output) ++ [Nothing])
    build (before, point, after) =
        maybe (fallback point) (original point . snd) (preferredSample paths point (catMaybes [before, after]))

-- | Build a preferred original vertex, retaining its known ordinates.
originalPoint :: Geometry -> Position -> (Maybe Double, Maybe Double) -> Point
originalPoint full = build
  where
    fallback = interpolatedPoint full
    layout = geometryDimensions full
    build point@(x, y) (z, m) =
        let (_, _, incidentZ, incidentM) = fromMaybe (0 / 0, 0 / 0, 0 / 0, 0 / 0) (withPoint coordinateComponents (fallback point))
         in pointFromComponents layout (fromRational x, fromRational y, fromMaybe incidentZ z, fromMaybe incidentM m)

-- | Select an original sample by the adjacent segments that it supplies.
preferredSample :: [[Sample]] -> Position -> [Position] -> Maybe Sample
preferredSample paths point neighbors
    | null neighbors = listToMaybe [sample | path <- paths, sample@(position', _) <- path, position' == point]
    | otherwise = case candidates of
        [] -> Nothing
        _ -> listToMaybe [sample | (score, sample) <- candidates, score == maximum (map fst candidates)]
  where
    candidates =
        [ (score, sample)
        | path <- paths
        , (before, sample@(position', _), after) <- zip3 (Nothing : map Just path) path (map Just (drop 1 path) ++ [Nothing])
        , position' == point
        , let incident = [(point, fst other) | other <- catMaybes [before, after], fst other /= point]
              score = length [neighbor | neighbor <- neighbors, any (pointOnSegment neighbor) incident]
        , score > 0
        ]

-- | Construct points with a chosen fallback for missing elevation.
pointInterpolator :: (Position -> Double) -> Geometry -> Position -> Point
pointInterpolator fallback geometry = build
  where
    paths = sourcePaths geometry
    rows = concat paths
    edges = unique [if fst a <= fst b then (a, b) else (b, a) | path <- paths, (a, b) <- zip path (drop 1 path)]
    layout = geometryDimensions geometry
    build point@(x, y) =
        let z = ordinate fst point
            m = ordinate snd point
         in pointFromComponents layout (fromRational x, fromRational y, if isNaN z then fallback point else z, m)
    ordinate select point = case [value | (p, extras) <- rows, p == point, Just value <- [select extras]] of
        value : _ -> value
        [] -> average (filter (not . isNaN) (mapMaybe (segmentOrdinate select point) edges))

-- | Interpolate one optional ordinate along a source segment.
segmentOrdinate :: ((Maybe Double, Maybe Double) -> Maybe Double) -> Position -> (Sample, Sample) -> Maybe Double
segmentOrdinate select point ((a, first), (b, second))
    | point == a || point == b || not (pointOnSegment point (a, b)) = Nothing
    | otherwise = case (select first, select second) of
        (Just x, Just y)
            | x == y -> Just x
            | otherwise -> Just (x + (y - x) * fraction)
        (Just x, Nothing) -> Just x
        (Nothing, Just y) -> Just y
        _ -> Nothing
  where
    (dx, dy) = subtractPosition b a
    (px, py) = subtractPosition point a
    squared x y = let u = fromRational x; v = fromRational y in u * u + v * v
    ratio = squared px py / squared dx dy
    fraction
        | finite ratio = sqrt ratio
        | otherwise = fromRational (if abs dx >= abs dy then px / dx else py / dy)

{- | Average known elevations in a three-by-three grid over the source extent.
An empty cell uses the mean of populated cell means. A constant coordinate
axis has one cell. This follows the GEOS overlay elevation model.
-}
elevationModel :: Geometry -> Position -> Double
elevationModel geometry
    | null rows = const (0 / 0)
    | otherwise = \point -> Map.findWithDefault fallback (cell point) means
  where
    rows = concat (sourcePaths geometry)
    xs = map (fst . fst) rows
    ys = map (snd . fst) rows
    minX = minimum xs
    maxX = maximum xs
    minY = minimum ys
    maxY = maximum ys
    cell (x, y) = (axisCell minY maxY y, axisCell minX maxX x)
    cells = List.foldl' add Map.empty [(point, z) | (point, (Just z, _)) <- rows]
    add table (point, z) = Map.alter (Just . accumulate) (cell point) table
      where
        accumulate Nothing = (z, 1 :: Int)
        accumulate (Just (total, count)) = (total + z, count + 1)
    means = Map.map (\(total, count) -> total / fromIntegral count) cells
    fallback = average (Map.elems means)

-- | Select a grid cell and clamp exterior positions to the extent.
axisCell :: Rational -> Rational -> Rational -> Int
axisCell lower upper coordinate
    | lower == upper = 0
    | otherwise = max 0 (min 2 (floor (3 * (coordinate - lower) / (upper - lower))))

-- | Average known ordinates, or return NaN when none exist.
average :: [Double] -> Double
average [] = 0 / 0
average values = sum values / fromIntegral (length values)

-- | Fill absent result elevations from the full source model, preserving M.
populateElevation :: Geometry -> Geometry -> Geometry
populateElevation source
    | not (any (any hasElevation) (sourcePaths source)) = id
    | otherwise = visit
  where
    hasElevation (_, (Just _, _)) = True
    hasElevation _ = False
    model = elevationModel source
    visit geometry = case geometry of
        PointGeometry point -> PointGeometry (pointElevation point)
        LineString coordinates -> LineString (sequenceElevation coordinates)
        Polygon rings -> Polygon (polygonElevation rings)
        MultiPoint points -> MultiPoint (U.map pointElevation points)
        MultiLineString lines' -> MultiLineString (V.map sequenceElevation lines')
        MultiPolygon polygons -> MultiPolygon (V.map polygonElevation polygons)
        GeometryCollection children -> GeometryCollection (V.map visit children)
    pointElevation (EmptyPoint layout) = EmptyPoint (promoted layout)
    pointElevation point = fromMaybe point (withPoint (\coordinate -> pointFromComponents (promoted (pointDimensions point)) (row (pointDimensions point) coordinate)) point)
    polygonElevation (PolygonRings shell holes) = PolygonRings (sequenceElevation shell) (V.map sequenceElevation holes)
    sequenceElevation coordinates = withCoordinates convert coordinates
      where
        convert values = case promoted (dimensionsOf coordinates) of
            DimXYZ -> CoordinatesXYZ (U.map (\coordinate -> let (x, y, z, _) = row (dimensionsOf coordinates) coordinate in XYZ x y z) values)
            _ -> CoordinatesXYZM (U.map (\coordinate -> let (x, y, z, m) = row (dimensionsOf coordinates) coordinate in XYZM x y z m) values)
    row layout coordinate =
        let (x, y, z, m) = coordinateComponents coordinate
            elevation = if layout `elem` [DimXYZ, DimXYZM] && not (isNaN z) then z else model (toRational x, toRational y)
         in (x, y, elevation, m)
    promoted DimXY = DimXYZ
    promoted DimXYM = DimXYZM
    promoted layout = layout
