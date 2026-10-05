{-# LANGUAGE BangPatterns #-}

-- | Exact planar primitives shared by the topology operations.
module Data.Geometry.Topology.Planar where

import Data.Geometry.Internal
import Data.List (sortBy, sortOn)
import qualified Data.List as List
import Data.Maybe (fromMaybe)
import qualified Data.Set as Set
import qualified Data.Vector as V
import qualified Data.Vector.Unboxed as U

-- | An exact position in the XY plane.
type Position = (Rational, Rational)

-- | A closed straight segment.
type Segment = (Position, Position)

-- | A balanced tree of segments with exact bounding boxes on its branches.
data SegmentIndex
    = -- | One segment, which can have coincident endpoints.
      SegmentLeaf !Segment
    | -- | The enclosing box and two nonempty subtrees.
      SegmentBranch !Segment !SegmentIndex !SegmentIndex

-- | Enclose the indexed segments. Leaf endpoints also specify their bounds.
indexBounds :: SegmentIndex -> Segment
indexBounds (SegmentLeaf edge) = edge
indexBounds (SegmentBranch bounds _ _) = bounds

-- | Divide segments at the median, alternating X and Y at each level.
indexSegments :: [Segment] -> Maybe SegmentIndex
indexSegments = build fst snd
  where
    build _ _ [] = Nothing
    build _ _ [edge] = Just (SegmentLeaf edge)
    build coordinate other edges = do
        let (first, second) = splitAt (length edges `div` 2) (sortOn (coordinate . midpoint) edges)
        left <- build other coordinate first
        right <- build other coordinate second
        let ((ax, ay), (bx, by)) = indexBounds left
            ((cx, cy), (dx, dy)) = indexBounds right
            bounds = ((minimum [ax, bx, cx, dx], minimum [ay, by, cy, dy]), (maximum [ax, bx, cx, dx], maximum [ay, by, cy, dy]))
        pure (SegmentBranch bounds left right)

-- | Build one index and select segments whose closed bounds meet each query box.
segmentQuery :: [Segment] -> Segment -> [Segment]
segmentQuery edges = maybe (const []) query (indexSegments edges)
  where
    query tree bounds
        | not (overlapsBounds bounds (indexBounds tree)) = []
        | otherwise = case tree of
            SegmentLeaf edge -> [edge]
            SegmentBranch _ left right -> query left bounds ++ query right bounds

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

-- | Round an exact planar position to an XY point.
planarPoint :: Position -> Point
planarPoint (x, y) = PointXY (XY (fromRational x) (fromRational y))

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

-- | Enclose a nonempty point set in an exact axis-aligned rectangle.
pointBounds :: [Position] -> Maybe Segment
pointBounds [] = Nothing
pointBounds (first : rest) = Just (List.foldl' extend (first, first) rest)
  where
    extend ((!ax, !ay), (!bx, !by)) (x, y) = ((min ax x, min ay y), (max bx x, max by y))

-- | Test strict separation of the input envelopes. Empty inputs are disjoint.
disjointBounds :: [Position] -> [Position] -> Bool
disjointBounds a b = case (pointBounds a, pointBounds b) of
    (Just first, Just second) -> not (overlapsBounds first second)
    _ -> True

-- | Test whether the first nonempty envelope contains the second one.
enclosesBounds :: [Position] -> [Position] -> Bool
enclosesBounds a b = case (pointBounds a, pointBounds b) of
    (Just ((ax, ay), (bx, by)), Just ((cx, cy), (dx, dy))) -> ax <= cx && ay <= cy && bx >= dx && by >= dy
    _ -> False

-- | Test membership in the point set without classifying its boundary.
coversPosition :: Planar -> Position -> Bool
coversPosition shape point =
    any ((/= Exterior) . polygonLocation point) (planarPolygons shape)
        || any (point `elem`) (planarLines shape)
        || any (any (pointOnSegment point) . lineSegments) (planarLines shape)
        || point `elem` planarPoints shape

-- | Choose one point from each connected component before testing its edges.
componentPoints :: Planar -> [Position]
componentPoints shape =
    planarPoints shape
        ++ [point | point : _ <- planarLines shape]
        ++ [point | (point : _) : _ <- planarPolygons shape]

{- | Test whether two sets of segments meet. Sweep from left to right and
discard segments whose X intervals have ended. Check remaining candidates
with exact segment intersections, and stop at the first contact.
-}
segmentsIntersect :: [Segment] -> [Segment] -> Bool
segmentsIntersect first second = go [] [] events
  where
    events = sortOn (left . snd) (map ((,) True) first ++ map ((,) False) second)
    left ((x, _), (u, _)) = min x u
    right ((x, _), (u, _)) = max x u
    go _ _ [] = False
    go activeFirst activeSecond ((fromFirst, edge) : rest)
        | any (not . null . segmentIntersection edge) candidates = True
        | fromFirst = go (edge : remainingFirst) remainingSecond rest
        | otherwise = go remainingFirst (edge : remainingSecond) rest
      where
        remainingFirst = filter ((>= left edge) . right) activeFirst
        remainingSecond = filter ((>= left edge) . right) activeSecond
        candidates = if fromFirst then remainingSecond else remainingFirst

-- | The displacement from the second position to the first.
subtractPosition :: Position -> Position -> Position
subtractPosition (x, y) (u, v) = (x - u, y - v)

-- | Translate a position by an XY displacement.
addPosition :: Position -> Position -> Position
addPosition (x, y) (u, v) = (x + u, y + v)

-- | Scale both XY components by an exact factor.
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
    query = segmentQuery edges
    -- Segment intersections already account for every endpoint.
    endpoints = Set.fromList (concatMap (\(a, b) -> [a, b]) edges)
    extraPoints = Set.toList (Set.fromList points `Set.difference` endpoints)
    split edge@(a, b) = lineSegments (unique (a : b : [p | p <- extraPoints, pointOnSegment p edge] ++ concatMap (segmentIntersection edge) (query edge)))

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
nearPoint :: (Segment -> [Segment]) -> Position -> Position -> Position
nearPoint query origin direction = addPosition origin (scalePosition step direction)
  where
    -- Only crossings before t=2 can reduce the initial step of one.
    reach = (origin, addPosition origin (scalePosition 2 direction))
    step = minimum (1 : [t / 2 | edge <- query reach, t <- rayParameters edge, t > 0])
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
sidePoints :: (Segment -> [Segment]) -> Segment -> (Position, Position)
sidePoints query segment@(a, b) = (nearPoint query middle normal, nearPoint query middle (scalePosition (-1) normal))
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
sectorPoints edges point = [nearPoint query point (addPosition a b) | (a, b) <- zip directions (drop 1 directions ++ take 1 directions)]
  where
    query = segmentQuery edges
    directions = sortBy compareDirection (unique ([(1, 0), (0, 1), (-1, 0), (0, -1)] ++ incident))
    incident = [normalize direction | edge@(a, b) <- query (point, point), pointOnSegment point edge, q <- [a, b], q /= point, let direction = subtractPosition q point]
    normalize (x, y) = let size = abs x + abs y in (x / size, y / size)

-- | Test the interior of the union of all polygon components.
polygonContains :: Planar -> Position -> Bool
polygonContains shape point
    | Interior `elem` locations = True
    | otherwise = case filter (== Boundary) locations of
        -- A single valid polygon's boundary cannot lie in the union's interior.
        _ : _ : _ -> all inComponent (sectorPoints edges point)
        _ -> False
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
