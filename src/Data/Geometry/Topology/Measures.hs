-- | Select points and curve portions by their M coordinate.
module Data.Geometry.Topology.Measures (locateAlong, locateBetween) where

import Data.Geometry.Internal
import qualified Data.List as List
import qualified Data.Vector as V
import qualified Data.Vector.Unboxed as U

{- | Select the points and curve portions whose measure equals the argument.
Constant-measure curve portions remain curves. See 'locateBetween' for the
empty-input, layout, and polygon rules.
-}
locateAlong :: Double -> Geometry -> Maybe Geometry
locateAlong value = locateBetween value value

{- | Select the inclusive interval between two M values. Interpolate X, Y,
and Z linearly within each segment. Retain the source coordinate layouts.
Consecutive selected portions stay connected within each input curve.

Return 'Nothing' for an empty input. Return an empty Point for no match or a
reversed interval. An input without M returns an empty XY Point.
Point-only results are MultiPoints. Curve-only results are MultiLineStrings.
A mixed result contains a MultiLineString and a MultiPoint.

For polygons, apply the operation to each boundary ring. This is the
implementation-defined surface rule permitted by OGC SFA 1.2.1, 6.1.2.6.5.
Do not interpolate measures across a polygon interior or between members.
Segments with nonfinite M values do not interpolate. Their matching endpoints
can still contribute points. A NaN interval bound matches nothing.
-}
locateBetween :: Double -> Double -> Geometry -> Maybe Geometry
locateBetween lower upper geometry
    | geometryEmpty geometry = Nothing
    | not (measured layout) = Just (PointGeometry (EmptyPoint DimXY))
    | not (lower <= upper) = Just empty
    | otherwise = Just result
  where
    layout = geometryDimensions geometry
    empty = PointGeometry (EmptyPoint layout)
    (points, curves) = select lower upper geometry
    result = case (points, curves) of
        ([], []) -> empty
        (_, []) -> MultiPoint (U.fromList points)
        ([], _) -> MultiLineString (V.fromList curves)
        _ -> GeometryCollection (V.fromList [MultiLineString (V.fromList curves), MultiPoint (U.fromList points)])

-- | Whether a coordinate layout includes M.
measured :: Dimensions -> Bool
measured layout = layout == DimXYM || layout == DimXYZM

-- | Select each atomic member without joining distinct curves.
select :: Double -> Double -> Geometry -> ([Point], [Coordinates])
select lower upper geometry = case geometry of
    PointGeometry point -> ([point | selectedPoint point], [])
    LineString coordinates -> selectCoordinates lower upper coordinates
    Polygon (PolygonRings shell holes) -> combine (map (selectCoordinates lower upper) (shell : V.toList holes))
    MultiPoint points -> (filter selectedPoint (U.toList points), [])
    MultiLineString curves -> combine (map (selectCoordinates lower upper) (V.toList curves))
    MultiPolygon polygons -> combine (map (select lower upper . Polygon) (V.toList polygons))
    GeometryCollection children -> combine (map (select lower upper) (V.toList children))
  where
    selectedPoint point = measured (pointDimensions point) && maybe False (inRange lower upper . measure) (withPoint coordinateComponents point)
    combine parts = (concatMap fst parts, concatMap snd parts)

-- | Read the M ordinate from the common coordinate representation.
measure :: (Double, Double, Double, Double) -> Double
measure (_, _, _, value) = value

-- | Test the closed measure interval. NaN values do not match.
inRange :: Double -> Double -> Double -> Bool
inRange lower upper value = lower <= value && value <= upper

-- | Clip a measured sequence and retain its concrete coordinate layout.
selectCoordinates :: Double -> Double -> Coordinates -> ([Point], [Coordinates])
selectCoordinates lower upper coordinates = case coordinates of
    CoordinatesXYM values -> build PointXYM CoordinatesXYM values
    CoordinatesXYZM values -> build PointXYZM CoordinatesXYZM values
    _ -> ([], [])
  where
    build wrapPoint wrapCurve values =
        let runs = selectedRuns lower upper (U.toList values)
         in ( [wrapPoint value | [value] <- runs]
            , [wrapCurve (U.fromList run) | run@(_ : _ : _) <- runs]
            )

-- | Join consecutive selected pieces. An excluded segment separates runs.
selectedRuns :: (Coordinate c) => Double -> Double -> [c] -> [[c]]
selectedRuns _ _ [] = []
selectedRuns lower upper [value] = [[value] | inRange lower upper (measure (coordinateComponents value))]
selectedRuns lower upper values = reverse (finish (List.foldl' append ([], []) pieces))
  where
    pieces = concat [clipSegment lower upper a b | (a, b) <- zip values (drop 1 values)]
    finish ([], completed) = completed
    finish (current, completed) = reverse current : completed
    append state [] = ([], finish state)
    append ([], completed) piece = (reverse piece, completed)
    append state@(current@(lastValue : _), completed) piece@(firstValue : rest)
        | sameCoordinate lastValue firstValue = (reverse rest ++ current, completed)
        | otherwise = (reverse piece, finish state)

-- | Clip one segment in measure space and retain its original direction.
clipSegment :: (Coordinate c) => Double -> Double -> c -> c -> [[c]]
clipSegment lower upper a b
    | not (finite start && finite end) = [[a] | inRange lower upper start] ++ [[]] ++ [[b] | inRange lower upper end]
    | start == end && not (inRange lower upper start) = [[]]
    | start == end = [if sameCoordinate a b then [a] else [a, b]]
    | selectedStart > selectedEnd = [[]]
    | selectedStart == selectedEnd = [[at selectedStart]]
    | start < end = [[at selectedStart, at selectedEnd]]
    | otherwise = [[at selectedEnd, at selectedStart]]
  where
    start = measure (coordinateComponents a)
    end = measure (coordinateComponents b)
    selectedStart = max lower (min start end)
    selectedEnd = min upper (max start end)
    at value
        | value == start = a
        | value == end = b
        | otherwise = interpolate ((toRational value - toRational start) / (toRational end - toRational start)) value a b

-- | Interpolate coordinates exactly before their final conversion to Double.
interpolate :: (Coordinate c) => Rational -> Double -> c -> c -> c
interpolate fraction value a b = coordinateFromComponents (along x u, along y v, along z w, value)
  where
    (x, y, z, _) = coordinateComponents a
    (u, v, w, _) = coordinateComponents b
    along first second
        | first == second = first
        | finite first && finite second = fromRational ((1 - fraction) * toRational first + fraction * toRational second)
        | otherwise = (1 - fromRational fraction) * first + fromRational fraction * second

-- | Compare shared endpoints while retaining unknown Z values.
sameCoordinate :: (Coordinate c) => c -> c -> Bool
sameCoordinate a b = equal x u && equal y v && equal z w && equal m n
  where
    (x, y, z, m) = coordinateComponents a
    (u, v, w, n) = coordinateComponents b
    equal first second = first == second || (isNaN first && isNaN second)
