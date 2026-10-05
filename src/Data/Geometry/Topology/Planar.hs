-- | Exact planar primitives shared by the topology operations.
module Data.Geometry.Topology.Planar where

import Data.Geometry.Internal
import Data.List (sortBy)
import Data.Maybe (fromMaybe)
import qualified Data.Set as Set
import qualified Data.Vector as V
import qualified Data.Vector.Unboxed as U

-- | An exact position in the XY plane.
type Position = (Rational, Rational)

-- | A closed straight segment.
type Segment = (Position, Position)

-- | A point's location relative to a geometry.
data Location = Exterior | Boundary | Interior deriving (Eq, Ord, Show, Read)

-- | The atomic components of a geometry, projected into the XY plane.
data Planar = Planar
    { planarPoints :: [Position]
    , planarLines :: [[Position]]
    , planarPolygons :: [[[Position]]]
    }
    deriving (Eq, Show, Read)

-- | Convert finite coordinates without rounding their binary values.
positions :: Coordinates -> [Position]
positions = withCoordinates (map position . U.toList)

-- | Project one finite coordinate into the plane.
position :: (Coordinate c) => c -> Position
position coordinate = let (x, y, _, _) = coordinateComponents coordinate in (toRational x, toRational y)

-- | Flatten collections while retaining polygon and line boundaries.
planar :: Geometry -> Planar
planar geometry = case geometry of
    PointGeometry point -> Planar (fromMaybe [] (withPoint ((: []) . position) point)) [] []
    LineString line -> Planar [] [positions line] []
    Polygon (PolygonRings shell holes) -> Planar [] [] [map positions (shell : V.toList holes)]
    MultiPoint points -> combine (map (planar . PointGeometry) (U.toList points))
    MultiLineString lines' -> combine (map (planar . LineString) (V.toList lines'))
    MultiPolygon polygons -> combine (map (planar . Polygon) (V.toList polygons))
    GeometryCollection children -> combine (map planar (V.toList children))
  where
    combine parts = Planar (concatMap planarPoints parts) (concatMap planarLines parts) (concatMap planarPolygons parts)

-- | Remove duplicates and return values in ascending order.
unique :: (Ord a) => [a] -> [a]
unique = Set.toAscList . Set.fromList

-- | List adjacent pairs, excluding segments with zero length.
lineSegments :: [Position] -> [Segment]
lineSegments points = [(a, b) | (a, b) <- zip points (drop 1 points), a /= b]

-- | List the segments of a closed ring.
ringSegments :: [Position] -> [Segment]
ringSegments [] = []
ringSegments points = lineSegments (points ++ take 1 points)

-- | List every line segment and polygon boundary segment.
segments :: Planar -> [Segment]
segments shape = concatMap lineSegments (planarLines shape) ++ concatMap ringSegments (concat (planarPolygons shape))

-- | List distinct input coordinates, including collapsed lines.
vertices :: Planar -> [Position]
vertices shape = unique (planarPoints shape ++ concat (planarLines shape) ++ concat (concat (planarPolygons shape)))

-- | Subtract two vectors.
subtractPosition :: Position -> Position -> Position
subtractPosition (x, y) (u, v) = (x - u, y - v)

-- | Add two vectors.
addPosition :: Position -> Position -> Position
addPosition (x, y) (u, v) = (x + u, y + v)

-- | Multiply a vector by a scalar.
scalePosition :: Rational -> Position -> Position
scalePosition t (x, y) = (t * x, t * y)

-- | The signed area of the parallelogram spanned by two vectors.
cross :: Position -> Position -> Rational
cross (x, y) (u, v) = x * v - y * u

-- | The turn from the first segment to the second: GT is counterclockwise.
orientation :: Position -> Position -> Position -> Ordering
orientation a b c = compare (cross (subtractPosition b a) (subtractPosition c a)) 0

-- | Test membership of a closed segment with exact arithmetic.
pointOnSegment :: Position -> Segment -> Bool
pointOnSegment point@(x, y) (a@(ax, ay), b@(bx, by)) =
    x >= min ax bx && x <= max ax bx && y >= min ay by && y <= max ay by && orientation a b point == EQ

-- | Return no point, one intersection, or the two ends of an overlap.
segmentIntersection :: Segment -> Segment -> [Position]
segmentIntersection first@(a, b) second@(c, d)
    | not (overlapsBounds first second) = []
    | denominator == 0 = case unique [p | p <- [a, b, c, d], pointOnSegment p first, pointOnSegment p second] of
        [] -> []
        [p] -> [p]
        firstPoint : rest -> [firstPoint, last rest]
    | t >= 0 && t <= 1 && u >= 0 && u <= 1 = [addPosition a (scalePosition t ab)]
    | otherwise = []
  where
    ab = subtractPosition b a
    cd = subtractPosition d c
    ac = subtractPosition c a
    denominator = cross ab cd
    t = cross ac cd / denominator
    u = cross ac ab / denominator

-- | Test whether two segment bounding boxes meet.
overlapsBounds :: Segment -> Segment -> Bool
overlapsBounds ((ax, ay), (bx, by)) ((cx, cy), (dx, dy)) =
    max ax bx >= min cx dx && max cx dx >= min ax bx && max ay by >= min cy dy && max cy dy >= min ay by

-- | Split segments at every intersection and supplied point. Return unique edges.
nodeSegments :: [Segment] -> [Position] -> [Segment]
nodeSegments input points = unique (concatMap split edges)
  where
    edges = unique [if a < b then (a, b) else (b, a) | (a, b) <- input, a /= b]
    split edge@(a, b) = lineSegments (unique (a : b : [p | p <- points, pointOnSegment p edge] ++ concatMap (segmentIntersection edge) edges))

-- | The exact midpoint of a segment.
midpoint :: Segment -> Position
midpoint (a, b) = scalePosition (1 / 2) (addPosition a b)

-- | Locate a point in a ring with an exact horizontal ray crossing test.
ringLocation :: Position -> [Position] -> Location
ringLocation point@(x, y) ring
    | any (pointOnSegment point) edges = Boundary
    | odd (length (filter crossesRay edges)) = Interior
    | otherwise = Exterior
  where
    edges = ringSegments ring
    crossesRay ((ax, ay), (bx, by)) = (ay > y) /= (by > y) && x < ax + (y - ay) * (bx - ax) / (by - ay)

-- | Locate a point in a polygon whose first ring is the shell.
polygonLocation :: Position -> [[Position]] -> Location
polygonLocation _ [] = Exterior
polygonLocation point (shell : holes) = case ringLocation point shell of
    Exterior -> Exterior
    shellLocation
        | Interior `elem` holeLocations -> Exterior
        | Boundary `elem` holeLocations -> Boundary
        | otherwise -> shellLocation
  where
    holeLocations = map (ringLocation point) holes

-- | Select a nearby point without crossing any segment after the start point.
nearPoint :: [Segment] -> Position -> Position -> Position
nearPoint edges origin direction = addPosition origin (scalePosition step direction)
  where
    step = minimum (1 : [t / 2 | edge <- edges, t <- rayParameters edge, t > 0])
    rayParameters (a, b)
        | determinant /= 0 = [t | u >= 0 && u <= 1]
        | cross offset direction /= 0 = []
        | otherwise = map parameter [a, b]
      where
        edge = subtractPosition b a
        offset = subtractPosition a origin
        determinant = cross direction edge
        t = cross offset edge / determinant
        u = cross offset direction / determinant
    parameter point =
        let (dx, dy) = direction
            (x, y) = subtractPosition point origin
         in if dx /= 0 then x / dx else y / dy

-- | Sample the faces immediately to the left and right of a noded edge.
sidePoints :: [Segment] -> Segment -> (Position, Position)
sidePoints edges segment@(a, b) = (nearPoint edges middle normal, nearPoint edges middle (scalePosition (-1) normal))
  where
    middle = midpoint segment
    (dx, dy) = subtractPosition b a
    normal = (-dy, dx)

-- | Sort nonzero directions counterclockwise from the positive X axis.
compareDirection :: Position -> Position -> Ordering
compareDirection a@(x, y) b@(u, v) = case compare (half x y) (half u v) of
    EQ -> compare 0 (cross a b)
    result -> result
  where
    half p q = not (q > 0 || (q == 0 && p >= 0))

-- | Sample each angular sector around a boundary point.
sectorPoints :: [Segment] -> Position -> [Position]
sectorPoints edges point = [nearPoint edges point (addPosition a b) | (a, b) <- zip directions (drop 1 directions ++ take 1 directions)]
  where
    directions = sortBy compareDirection (unique ([(1, 0), (0, 1), (-1, 0), (0, -1)] ++ incident))
    incident = [normalize direction | edge@(a, b) <- edges, pointOnSegment point edge, q <- [a, b], q /= point, let direction = subtractPosition q point]
    normalize (x, y) = let size = abs x + abs y in (x / size, y / size)

-- | Test the interior of the union of all polygon components.
polygonContains :: Planar -> Position -> Bool
polygonContains shape point
    | Interior `elem` locations = True
    | Boundary `notElem` locations = False
    | otherwise = all inComponent (sectorPoints edges point)
  where
    locations = map (polygonLocation point) (planarPolygons shape)
    edges = concatMap ringSegments (concat (planarPolygons shape))
    inComponent p = any ((== Interior) . polygonLocation p) (planarPolygons shape)

-- | Locate a point in the union. Line endpoints follow the mod-2 boundary rule.
locate :: Planar -> Position -> Location
locate shape point
    | polygonContains shape point = Interior
    | any ((== Boundary) . polygonLocation point) (planarPolygons shape) = Boundary
    | onLine = if odd endpoints then Boundary else Interior
    | point `elem` planarPoints shape = Interior
    | otherwise = Exterior
  where
    lines' = planarLines shape
    onLine = any (point `elem`) lines' || any (any (pointOnSegment point) . lineSegments) lines'
    endpoints = length [end | line@(first : _) <- lines', end <- [first, last line], end == point]
