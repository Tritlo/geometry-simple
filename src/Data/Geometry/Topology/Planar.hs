{-# LANGUAGE BangPatterns #-}

-- | Exact planar primitives shared by the topology operations.
module Data.Geometry.Topology.Planar where

import Data.Geometry.Internal
import Data.List (sortBy, sortOn)
import qualified Data.List as List
import qualified Data.Map.Strict as Map
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
        let (first, second) = splitAt (length edges `div` 2) (sortOn (\(a, b) -> coordinate a + coordinate b) edges)
        left <- build other coordinate first
        right <- build other coordinate second
        let ((ax, ay), (bx, by)) = indexBounds left
            ((cx, cy), (dx, dy)) = indexBounds right
            bounds = ((minimum [ax, bx, cx, dx], minimum [ay, by, cy, dy]), (maximum [ax, bx, cx, dx], maximum [ay, by, cy, dy]))
        pure (SegmentBranch bounds left right)

-- | Build one index and select segments whose closed bounds meet each query box.
segmentQuery :: [Segment] -> Segment -> [Segment]
segmentQuery edges = maybe (const []) querySegments (indexSegments edges)

-- | Select leaves whose closed bounds intersect the supplied box.
querySegments :: SegmentIndex -> Segment -> [Segment]
querySegments tree bounds
    | not (overlapsBounds bounds (indexBounds tree)) = []
    | otherwise = case tree of
        SegmentLeaf edge -> [edge]
        SegmentBranch _ left right -> querySegments left bounds ++ querySegments right bounds

-- | Attach values to indexed bounds, retaining values with equal boxes.
boundsQuery :: [(Segment, a)] -> Segment -> [a]
boundsQuery entries = concatMap (table Map.!) . query
  where
    table = Map.fromListWith (++) [(bounds, [value]) | (bounds, value) <- entries]
    query = segmentQuery (Map.keys table)

-- | Enumerate unordered pairs with intersecting bounds, including equal boxes.
overlappingPairs :: [(Segment, a)] -> [(a, a)]
overlappingPairs entries = [(a, b) | (bounds, (i, a)) <- indexed, (j, b) <- query bounds, i < j]
  where
    indexed = zipWith (\i (bounds, value) -> (bounds, (i, value))) [0 :: Int ..] entries
    query = boundsQuery indexed

-- | Prepare exact winding queries over directed edges, retaining duplicate edges.
prepareWinding :: [Segment] -> Position -> Int
prepareWinding edges = maybe (const 0) windingIndex (indexSegments edges)

{- | Count crossings without visiting branches wholly to the right of the point.
Each branch stores cumulative changes at endpoint Y values. An upward edge
adds one between its endpoints; a downward edge subtracts one. Shared vertices
cancel when branches combine. Branches that contain the query X still use exact
orientation tests at their leaves.
-}
windingIndex :: SegmentIndex -> Position -> Int
windingIndex = snd . build
  where
    build (SegmentLeaf (a@(_, ay), b@(_, by))) =
        ( Map.filter (/= 0) (Map.fromListWith (+) [(ay, 1), (by, -1)])
        , \point@(_, y) ->
            if ay <= y && by > y && orientation a b point == GT
                then 1
                else if by <= y && ay > y && orientation a b point == LT then -1 else 0
        )
    build (SegmentBranch ((ax, ay), (bx, by)) left right) = (changes, classify)
      where
        (leftChanges, leftWinding) = build left
        (rightChanges, rightWinding) = build right
        changes = Map.filter (/= 0) (Map.unionWith (+) leftChanges rightChanges)
        cumulative = snd (Map.mapAccum (\total delta -> let next = total + delta in (next, next)) 0 changes)
        classify point@(x, y)
            | x >= bx || y < ay || y >= by = 0
            | x < ax = maybe 0 snd (Map.lookupLE y cumulative)
            | otherwise = leftWinding point + rightWinding point

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

{- | Find the dimension of a valid point set, ignoring empty components.
Collapsed lines and collinear rings contribute only their stored point set.
-}
planarDimension :: Planar -> TopologicalDimension
planarDimension shape
    | any (any spansArea) (planarPolygons shape) = SurfaceDimension
    | not (null (segments shape)) = CurveDimension
    | not (null (allPositions shape)) = PointDimension
    | otherwise = NoDimension
  where
    spansArea (first : rest) = case dropWhile (== first) rest of
        second : remaining -> any ((/= EQ) . orientation first second) remaining
        [] -> False
    spansArea [] = False

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
vertices = unique . allPositions

-- | Traverse coordinates without sorting or removing duplicates.
allPositions :: Planar -> [Position]
allPositions shape = planarPoints shape ++ concat (planarLines shape) ++ concat (concat (planarPolygons shape))

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

-- | Choose one point from each connected component before testing its edges.
componentPoints :: Planar -> [Position]
componentPoints shape =
    planarPoints shape
        ++ [point | point : _ <- planarLines shape]
        ++ [point | (point : _) : _ <- planarPolygons shape]

-- | Test segment contacts using both coordinate bounds and stop at the first hit.
segmentsIntersect :: [Segment] -> [Segment] -> Bool
segmentsIntersect first second = any (\edge -> not (all (null . segmentIntersection edge) (query edge))) first
  where
    query = segmentQuery second

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
    queryPoints = segmentQuery [(p, p) | p <- extraPoints]
    split edge@(a, b) = lineSegments (unique (a : b : [p | (p, _) <- queryPoints edge, pointOnSegment p edge] ++ concatMap (segmentIntersection edge) (query edge)))

-- | The exact midpoint of a segment.
midpoint :: Segment -> Position
midpoint (a, b) = scalePosition (1 / 2) (addPosition a b)

-- | Build one edge index for repeated exact location queries in a ring.
prepareRing :: [Position] -> Position -> Location
prepareRing ring = case indexSegments (ringSegments ring) of
    Nothing -> const Exterior
    Just tree ->
        let winding = windingIndex tree
         in \point ->
                if any (pointOnSegment point) (querySegments tree (point, point))
                    then Boundary
                    else if odd (winding point) then Interior else Exterior

-- | Index the shell and holes once. Skip holes whose bounds exclude the point.
preparePolygon :: [[Position]] -> Position -> Location
preparePolygon [] = const Exterior
preparePolygon [shell] = prepareRing shell
preparePolygon (shell : holes) = classify
  where
    locateShell = prepareRing shell
    queryHoles = boundsQuery [(bounds, prepareRing hole) | hole <- holes, Just bounds <- [pointBounds hole]]
    classify point = case locateShell point of
        Exterior -> Exterior
        shellLocation
            | Interior `elem` holesHere -> Exterior
            | Boundary `elem` holesHere -> Boundary
            | otherwise -> shellLocation
          where
            holesHere = map ($ point) (queryHoles (point, point))

-- | Index polygon components and retain the boundary rules for their union.
prepareSurface :: [[[Position]]] -> Position -> Location
prepareSurface [] = const Exterior
prepareSurface [polygon] = preparePolygon polygon
prepareSurface polygons = classify
  where
    queryPolygons = boundsQuery [(bounds, preparePolygon polygon) | polygon <- polygons, Just bounds <- [pointBounds (concat polygon)]]
    queryEdges = segmentQuery (concatMap ringSegments (concat polygons))
    locations point = map ($ point) (queryPolygons (point, point))
    classify point
        | Interior `elem` here = Interior
        | otherwise = case filter (== Boundary) here of
            _ : _ : _ | all (elem Interior . locations) (sectorSamples queryEdges point) -> Interior
            _ : _ -> Boundary
            [] -> Exterior
      where
        here = locations point

-- | Prepare point locations and surface membership for repeated arrangement queries.
prepareLocations :: Planar -> (Position -> Location, Position -> Bool)
prepareLocations shape = (classify, (== Interior) . locateSurface)
  where
    locateSurface = prepareSurface (planarPolygons shape)
    queryLines = segmentQuery (concatMap lineSegments lines')
    lines' = planarLines shape
    linePoints = Set.fromList (concat lines')
    points = Set.fromList (planarPoints shape)
    endpoints = Map.fromListWith (+) [(p, 1 :: Int) | line@(first : _) <- lines', p <- [first, last line]]
    classify point = case locateSurface point of
        Exterior
            | Set.member point linePoints || any (pointOnSegment point) (queryLines (point, point)) ->
                if odd (Map.findWithDefault 0 point endpoints) then Boundary else Interior
            | Set.member point points -> Interior
            | otherwise -> Exterior
        result -> result

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

-- | Sample boundary sectors using an existing edge index.
sectorSamples :: (Segment -> [Segment]) -> Position -> [Position]
sectorSamples query point = [nearPoint query point (addPosition a b) | (a, b) <- zip directions (drop 1 directions ++ take 1 directions)]
  where
    directions = sortBy compareDirection (unique ([(1, 0), (0, 1), (-1, 0), (0, -1)] ++ incident))
    incident = [normalize direction | edge@(a, b) <- query (point, point), pointOnSegment point edge, q <- [a, b], q /= point, let direction = subtractPosition q point]
    normalize (x, y) = let size = abs x + abs y in (x / size, y / size)

-- | Return the vector from the closest point on a segment to a point.
segmentOffset :: Position -> Segment -> Position
segmentOffset point (a, b)
    | a == b = offset
    | otherwise = subtractPosition offset (scalePosition fraction direction)
  where
    offset = subtractPosition point a
    direction = subtractPosition b a
    fraction = max 0 (min 1 (dot offset direction / squaredLength direction))

-- | The exact scalar product of two vectors.
dot :: Position -> Position -> Rational
dot (x, y) (u, v) = x * u + y * v

-- | The exact squared length of a vector.
squaredLength :: Position -> Rational
squaredLength vector = dot vector vector
