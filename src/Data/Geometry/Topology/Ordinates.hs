-- | Preserve and interpolate optional ordinates during planar overlay.
module Data.Geometry.Topology.Ordinates (
    Sample,
    sourcePaths,
    interpolatedPoint,
    interpolatedCoordinateSequence,
    elevationModel,
    populateElevation,
) where

import Data.Geometry.Internal
import Data.Geometry.Topology.Planar (Position, pointOnSegment, position, subtractPosition, unique)
import qualified Data.List as List
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe, listToMaybe, mapMaybe)
import qualified Data.Vector as V
import qualified Data.Vector.Unboxed as U

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
interpolatedCoordinateSequence full preferred output = pack (map build entries)
  where
    paths = sourcePaths preferred
    fallback = interpolatedPoint full
    original = originalPoint full
    entries = zip3 (Nothing : map Just output) output (map Just (drop 1 output) ++ [Nothing])
    build (before, point, after) =
        maybe (fallback point) (original point . snd) (preferredSample paths point (mapMaybe id [before, after]))
    layout = geometryDimensions full
    pack points = case layout of
        DimXY -> CoordinatesXY (U.fromList [XY x y | (x, y, _, _) <- rows points])
        DimXYZ -> CoordinatesXYZ (U.fromList [XYZ x y z | (x, y, z, _) <- rows points])
        DimXYM -> CoordinatesXYM (U.fromList [XYM x y m | (x, y, _, m) <- rows points])
        DimXYZM -> CoordinatesXYZM (U.fromList [XYZM x y z m | (x, y, z, m) <- rows points])
    rows = map (fromMaybe (0 / 0, 0 / 0, 0 / 0, 0 / 0) . withPoint coordinateComponents)

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
        , let incident = [(point, fst other) | other <- mapMaybe id [before, after], fst other /= point]
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
    | not (any hasElevation (concat (sourcePaths source))) = id
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
