{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

{- | WKT codecs for the seven Simple Features families.

The decoder retains each collection member's layout. For untagged input,
it infers XY, XYZ, or XYZM from the number of ordinates. XYM requires an M tag.
Within a multi-geometry, the first coordinate sets the layout for the remaining
coordinates. Empty members before that coordinate retain XY.
MULTIPOINT accepts EMPTY beside bare coordinates, as emitted by DuckDB.
Nonempty members must consistently use or omit parentheses.
The codecs check line lengths and ring closure, but not polygon topology.
NaN and infinity are accepted. EWKT and SRIDs are not supported.
-}
module Data.Geometry.WKT (decodeWKT, encodeWKT) where

import Control.Monad (unless, when)
import Control.Monad.ST (runST)
import Control.Monad.Trans.Class (lift)
import Control.Monad.Trans.State.Strict (StateT (..), get, modify', put)
import Data.ByteString.Builder (Builder)
import qualified Data.ByteString.Builder as Builder
import qualified Data.ByteString.Builder.RealFloat as RealFloat
import qualified Data.ByteString.Lazy as BL
import Data.Char (isAsciiLower, isAsciiUpper, isDigit)
import Data.Geometry.Internal
import Data.Maybe (fromMaybe)
import Data.Proxy (Proxy (..))
import Data.Ratio ((%))
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEncoding
import qualified Data.Vector as V
import qualified Data.Vector.Generic as G
import qualified Data.Vector.Unboxed as U
import qualified Data.Vector.Unboxed.Mutable as UM
import GHC.Float (castWord64ToDouble)

-- | The remaining text and a controlled parse error.
type Parser = StateT Text (Either String)

-- | The geometry family selected by a WKT keyword.
data Family
    = -- | A point or an empty point.
      PointFamily
    | -- | One coordinate sequence.
      LineFamily
    | -- | An exterior ring and holes.
      PolygonFamily
    | -- | A collection of points.
      MultiPointFamily
    | -- | A collection of line strings.
      MultiLineFamily
    | -- | A collection of polygons.
      MultiPolygonFamily
    | -- | A collection of arbitrary geometries.
      CollectionFamily

{- | Decode one complete geometry and preserve each member's coordinate layout.
Return 'Left' for malformed WKT or trailing input. See the module documentation
for layout inference and the construction checks.
-}
decodeWKT :: Text -> Either String Geometry
decodeWKT input = do
    ((geometry, _), remaining) <- runStateT (geometryParser <* spaces) input
    if Text.null remaining then Right geometry else Left "Geometry WKT has trailing input"

{- | Write dimension tags and shortest scientific decimal ordinates.
Multi-geometries and polygon rings pad absent Z or M ordinates with NaN.
Geometry collections use a parent tag when all children share one output layout.
Mixed collections omit that tag and retain each child's layout and ordinates.
Mixed-layout collections extend the standard WKT grammar.
Return 'Left' for invalid line lengths, ring closure, or polygon emptiness.
-}
encodeWKT :: Geometry -> Either String Text
encodeWKT geometry = do
    validateGeometry (const (Right ())) geometry
    pure (TextEncoding.decodeUtf8 (BL.toStrict (Builder.toLazyByteString (snd (geometryWKT geometry) DimXY))))

-- | Stop parsing with a geometry-specific error.
failure :: String -> Parser a
failure message = lift (Left ("Geometry WKT " ++ message))

-- | Consume whitespace before a structural token.
spaces :: Parser ()
spaces = modify' (Text.dropWhile whitespace)

-- | Accept the ASCII whitespace that WKT readers use: space, tab, LF, and CR.
whitespace :: Char -> Bool
whitespace c = c == ' ' || c == '\t' || c == '\n' || c == '\r'

-- | Keywords and named numbers use ASCII letters only.
letter :: Char -> Bool
letter c = isAsciiLower c || isAsciiUpper c

-- | Require a punctuation character, with optional leading whitespace.
symbol :: Char -> Parser ()
symbol expected = do
    spaces
    input <- get
    case Text.uncons input of
        Just (actual, rest) | actual == expected -> put rest
        _ -> failure ("expected " ++ show expected)

-- | Read an ASCII keyword without consuming following whitespace.
word :: Parser Text
word = do
    spaces
    input <- get
    let (name, rest) = Text.span letter input
    when (Text.null name) (failure "expected a keyword")
    put rest
    pure (Text.toUpper name)

-- | Consume EMPTY when it is the next complete keyword.
emptyKeyword :: Parser Bool
emptyKeyword = do
    spaces
    input <- get
    let (name, rest) = Text.span letter input
    if Text.toUpper name == "EMPTY"
        then put rest >> pure True
        else pure False

-- | Read the geometry family and an attached or separate dimension suffix.
header :: Parser (Family, Maybe Dimensions)
header = do
    name <- word
    let families = [("POINT", PointFamily), ("LINESTRING", LineFamily), ("POLYGON", PolygonFamily), ("MULTIPOINT", MultiPointFamily), ("MULTILINESTRING", MultiLineFamily), ("MULTIPOLYGON", MultiPolygonFamily), ("GEOMETRYCOLLECTION", CollectionFamily)]
        suffixes = [("ZM", DimXYZM), ("Z", DimXYZ), ("M", DimXYM)]
        attached = [(family, dimensions) | (suffix, dimensions) <- suffixes, Just base <- [Text.stripSuffix suffix name], Just family <- [lookup base families]]
    case lookup name families of
        Just family -> do
            spaces
            input <- get
            let (tag, rest) = Text.span letter input
            case lookup (Text.toUpper tag) suffixes of
                Just dimensions -> put rest >> pure (family, Just dimensions)
                Nothing -> pure (family, Nothing)
        Nothing -> case attached of
            [(family, dimensions)] -> pure (family, Just dimensions)
            _ -> failure "has an unsupported geometry type"

-- | Read a geometry and retain the parsed layout for an explicit parent tag.
geometryParser :: Parser (Geometry, LayoutSummary)
geometryParser = do
    (family, declared) <- header
    case family of
        CollectionFamily -> do
            (members, ()) <- boxedSequence () (stateless geometryParser)
            case declared of
                Just dimensions -> unless (V.all ((== Uniform dimensions) . snd) members) (failure "has mixed coordinate dimensions")
                Nothing -> pure ()
            let layout = if V.null members then Uniform (fromMaybe DimXY declared) else V.foldl' (\acc (_, child) -> combineLayout acc child) Inherited members
            pure (GeometryCollection (V.map fst members), layout)
        PointFamily -> known PointGeometry (point True declared)
        LineFamily -> known LineString (line declared)
        PolygonFamily -> known Polygon (polygon declared)
        MultiPointFamily -> known MultiPoint (multiPoint declared)
        MultiLineFamily -> known MultiLineString (boxedSequence declared line)
        MultiPolygonFamily -> known MultiPolygon (boxedSequence declared polygon)
  where
    known wrap parser = do
        (value, dimensions) <- parser
        pure (wrap value, Uniform (fromMaybe DimXY dimensions))
    line current = do
        (values, dimensions) <- coordinates current
        lift (validateLine values)
        pure (values, dimensions)

-- | Inspect one coordinate without consuming its text.
lookAheadParser :: Parser a -> Parser a
lookAheadParser parser = StateT $ \input -> do
    (value, _) <- runStateT parser input
    pure (value, input)

-- | Infer an untagged coordinate's two, three, or four ordinates.
inferDimensions :: Parser Dimensions
inferDimensions = do
    _ <- number
    _ <- nextNumber
    third <- more
    if not third
        then pure DimXY
        else do
            _ <- nextNumber
            fourth <- more
            if fourth then nextNumber >> pure DimXYZM else pure DimXYZ
  where
    more = do
        remaining <- get
        pure $ case Text.uncons (Text.dropWhile whitespace remaining) of
            Nothing -> False
            Just (c, _) -> c /= ',' && c /= ')'

-- | Read a point body. MULTIPOINT coordinates can omit parentheses.
point :: Bool -> Maybe Dimensions -> Parser (Point, Maybe Dimensions)
point parenthesized current = do
    empty <- emptyKeyword
    if empty
        then pure (EmptyPoint (fromMaybe DimXY current), current)
        else do
            when parenthesized (symbol '(')
            spaces
            dimensions <- maybe (lookAheadParser inferDimensions) pure current
            x <- number
            y <- nextNumber
            (z, m) <- case dimensions of
                DimXY -> pure (0, 0)
                DimXYZ -> do z <- nextNumber; pure (z, 0)
                DimXYM -> do m <- nextNumber; pure (0, m)
                DimXYZM -> (,) <$> nextNumber <*> nextNumber
            when parenthesized (symbol ')')
            pure (pointFromComponents dimensions (x, y, z, m), Just dimensions)

-- | Read one sequence into the unboxed buffer for its inferred layout.
coordinates :: Maybe Dimensions -> Parser (Coordinates, Maybe Dimensions)
coordinates current = do
    empty <- emptyKeyword
    if empty
        then pure (emptyCoordinates (fromMaybe DimXY current), current)
        else do
            dimensions <- maybe (lookAheadParser (symbol '(' *> spaces *> inferDimensions)) pure current
            values <- case dimensions of
                DimXY -> CoordinatesXY . fst <$> unboxedSequence () (stateless coordinate)
                DimXYZ -> CoordinatesXYZ . fst <$> unboxedSequence () (stateless coordinate)
                DimXYM -> CoordinatesXYM . fst <$> unboxedSequence () (stateless coordinate)
                DimXYZM -> CoordinatesXYZM . fst <$> unboxedSequence () (stateless coordinate)
            pure (values, Just dimensions)

-- | Preserve empty rings and their layouts when reading a polygon.
polygon :: Maybe Dimensions -> Parser (PolygonRings, Maybe Dimensions)
polygon current = do
    (rings, dimensions) <- boxedSequence current coordinates
    let values =
            if V.null rings
                then PolygonRings (emptyCoordinates (fromMaybe DimXY current)) V.empty
                else PolygonRings (V.head rings) (V.tail rings)
    lift (validatePolygon values)
    pure (values, dimensions)

-- | Use the first nonempty point's spelling throughout a MULTIPOINT body.
multiPoint :: Maybe Dimensions -> Parser (U.Vector Point, Maybe Dimensions)
multiPoint current = do
    parenthesized <- lookAheadParser $ do
        empty <- emptyKeyword
        if empty then pure False else symbol '(' >> firstNonempty
    unboxedSequence current (point parenthesized)
  where
    -- Scan leading empty members once. Their layouts are assigned during parsing.
    firstNonempty = do
        empty <- emptyKeyword
        if empty
            then do
                finished <- delimiter
                if finished then pure False else firstNonempty
            else Text.isPrefixOf "(" <$> get

{- | Read EMPTY or a parenthesized sequence into a boxed vector. Carry the
inferred layout from each element to the next. A list keeps deep nesting
linear: boxed mutable buffers for every open level would be rescanned by
each garbage collection.
-}
boxedSequence :: s -> (s -> Parser (a, s)) -> Parser (V.Vector a, s)
boxedSequence initialState element = do
    empty <- emptyKeyword
    if empty
        then pure (V.empty, initialState)
        else symbol '(' >> go 1 [] initialState
  where
    go !count values current = do
        (value, next) <- element current
        finished <- delimiter
        let values' = value `seq` value : values
        if finished then pure (V.fromListN count (reverse values'), next) else go (count + 1) values' next

{- | Read EMPTY or a parenthesized sequence into an unboxed vector. Write the
elements into a growable buffer, which avoids an intermediate list for long
coordinate sequences.
-}
unboxedSequence :: (U.Unbox a) => s -> (s -> Parser (a, s)) -> Parser (U.Vector a, s)
unboxedSequence initialState element = do
    empty <- emptyKeyword
    if empty
        then pure (U.empty, initialState)
        else do
            symbol '('
            StateT $ \input -> runST $ do
                initial <- UM.new 16
                let go !count buffer current remaining = case runStateT (element current) remaining of
                        Left message -> pure (Left message)
                        Right ((value, next), afterElement) -> case runStateT delimiter afterElement of
                            Left message -> pure (Left message)
                            Right (finished, rest) -> do
                                target <- if count == UM.length buffer then UM.grow buffer (UM.length buffer) else pure buffer
                                UM.write target count value
                                if finished
                                    then do
                                        result <- U.freeze (UM.slice 0 (count + 1) target)
                                        pure (Right ((result, next), rest))
                                    else go (count + 1) target next rest
                go 0 initial initialState input

-- | Read elements that do not share layout state.
stateless :: Parser a -> () -> Parser (a, ())
stateless element () = do
    value <- element
    pure (value, ())

-- | Consume a comma or a closing parenthesis.
delimiter :: Parser Bool
delimiter = do
    spaces
    input <- get
    case Text.uncons input of
        Just (',', rest) -> put rest >> pure False
        Just (')', rest) -> put rest >> pure True
        _ -> failure "expected ',' or ')'"

-- | Parse exactly the ordinates required by the coordinate type.
coordinate :: forall c. (Coordinate c) => Parser c
coordinate = do
    spaces
    x <- number
    y <- nextNumber
    (z, m) <- case coordinateDimensions (Proxy :: Proxy c) of
        DimXY -> pure (0, 0)
        DimXYZ -> do z <- nextNumber; pure (z, 0)
        DimXYM -> do m <- nextNumber; pure (0, m)
        DimXYZM -> (,) <$> nextNumber <*> nextNumber
    pure (coordinateFromComponents (x, y, z, m))

-- | Require whitespace between ordinates so adjacent numbers cannot be split.
nextNumber :: Parser Double
nextNumber = do
    input <- get
    unless (maybe False (whitespace . fst) (Text.uncons input)) $
        failure "requires whitespace between coordinates"
    spaces
    number

{- | Read named IEEE values or an exactly rounded decimal ordinate.
Bound extreme exponents so integer powers stay proportional to input length.
Use 'fromRational' for rounding. @Data.Text.Read.double@ and
@Data.Text.Read.rational@ can underflow intermediate powers, including the
power in @5e-324@.
WKT also permits @.5@ and @1.@, which those readers do not consume fully.
-}
number :: Parser Double
number = do
    input <- get
    let (negative, unsigned) = case Text.uncons input of
            Just ('-', rest) -> (True, rest)
            Just ('+', rest) -> (False, rest)
            _ -> (False, input)
        (keyword, afterKeyword) = Text.span letter unsigned
        special = lookup (Text.toUpper keyword) [("NAN", castWord64ToDouble 0x7ff8000000000000), ("INF", 1 / 0), ("INFINITY", 1 / 0)]
    case special of
        Just value -> put afterKeyword >> pure (if negative then negate value else value)
        Nothing -> decimalNumber negative unsigned

-- | Round a decimal once. Clamp only exponents whose values must be zero or infinity.
decimalNumber :: Bool -> Text -> Parser Double
decimalNumber negative unsigned = do
    let (whole, afterWhole) = Text.span isDigit unsigned
        (fraction, afterFraction) = case Text.uncons afterWhole of
            Just ('.', rest) -> Text.span isDigit rest
            _ -> (Text.empty, afterWhole)
        -- Allow all mantissa digits to compensate for the exponent.
        -- The extra 400 exceeds Double's decimal range (-324 to 308).
        exponentLimit = toInteger (Text.length whole) + toInteger (Text.length fraction) + 400
    when (Text.null whole && Text.null fraction) (failure "expected a decimal number")
    (power, rest) <- case Text.uncons afterFraction of
        Just (marker, afterMarker) | marker == 'e' || marker == 'E' -> do
            let (negativeExponent, afterSign) = case Text.uncons afterMarker of
                    Just ('-', tailText) -> (True, tailText)
                    Just ('+', tailText) -> (False, tailText)
                    _ -> (False, afterMarker)
                (digits, afterDigits) = Text.span isDigit afterSign
            when (Text.null digits) (failure "expected exponent digits")
            let magnitude = Text.foldl' (\n c -> min (exponentLimit + 1) (10 * n + toInteger (fromEnum c - fromEnum '0'))) 0 digits
            pure (if negativeExponent then negate magnitude else magnitude, afterDigits)
        _ -> pure (0, afterFraction)
    if (Text.all (== '0') whole && Text.all (== '0') fraction) || power < negate exponentLimit
        then put rest >> pure (if negative then -0.0 else 0.0)
        else do
            let coefficient = digitsValue (whole <> fraction)
                adjustedPower = power - toInteger (Text.length fraction)
                magnitude
                    | power > exponentLimit = 1 / 0
                    | adjustedPower >= 0 = fromInteger (coefficient * 10 ^ adjustedPower)
                    | otherwise = fromRational (coefficient % (10 ^ negate adjustedPower))
                value = if negative then negate magnitude else magnitude
            put rest >> pure value

{- | Read decimal digits. Split long input in halves, because a digit-by-digit
loop over a large Integer takes quadratic time.
-}
digitsValue :: Text -> Integer
digitsValue digits
    | size <= 64 = Text.foldl' (\value c -> 10 * value + toInteger (fromEnum c - fromEnum '0')) 0 digits
    | otherwise = digitsValue high * 10 ^ (size - half) + digitsValue low
  where
    size = Text.length digits
    half = size `div` 2
    (high, low) = Text.splitAt half digits

-- | Whether a WKT container has one layout, no stored layout, or mixed layouts.
data LayoutSummary = Uniform Dimensions | Inherited | Mixed
    deriving (Eq)

-- | Combine child layouts. Containers without a stored layout are neutral.
combineLayout :: LayoutSummary -> LayoutSummary -> LayoutSummary
combineLayout Inherited second = second
combineLayout first Inherited = first
combineLayout (Uniform first) (Uniform second) | first == second = Uniform first
combineLayout _ _ = Mixed

-- | Compute layouts once and give empty containers their parent's output tag.
geometryWKT :: Geometry -> (LayoutSummary, Dimensions -> Builder)
geometryWKT geometry =
    ( layout
    , \inherited ->
        let dimensions = case layout of Uniform value -> value; Inherited -> inherited; Mixed -> DimXY
            suffix = case layout of
                Mixed -> ""
                _ -> case dimensions of DimXYZ -> " Z"; DimXYM -> " M"; DimXYZM -> " ZM"; DimXY -> ""
         in name <> suffix <> " " <> body dimensions
    )
  where
    sourceDimensions = geometryDimensions geometry
    (name, layout, body) = case geometry of
        PointGeometry value -> ("POINT", Uniform sourceDimensions, (`pointWKT` value))
        LineString points -> ("LINESTRING", Uniform sourceDimensions, (`coordinatesWKT` points))
        Polygon rings -> ("POLYGON", Uniform sourceDimensions, (`polygonWKT` rings))
        MultiPoint points -> ("MULTIPOINT", if U.null points then Inherited else Uniform sourceDimensions, \d -> sequenceWKT (pointWKT d) points)
        MultiLineString lineStrings -> ("MULTILINESTRING", if V.null lineStrings then Inherited else Uniform sourceDimensions, \d -> sequenceWKT (coordinatesWKT d) lineStrings)
        MultiPolygon polygons -> ("MULTIPOLYGON", if V.null polygons then Inherited else Uniform sourceDimensions, \d -> sequenceWKT (polygonWKT d) polygons)
        GeometryCollection members ->
            let children = V.map geometryWKT members
                common = V.foldl' (\acc (childLayout, _) -> combineLayout acc childLayout) Inherited children
             in ("GEOMETRYCOLLECTION", common, \d -> sequenceWKT (\(_, render) -> render d) children)

-- | Empty points have no ordinates in WKT. Nonempty points use the writer's layout.
pointWKT :: Dimensions -> Point -> Builder
pointWKT dimensions = fromMaybe "EMPTY" . withPoint (\value -> "(" <> coordinateWKT dimensions value <> ")")

-- | Empty polygons discard their empty holes only during writing.
polygonWKT :: Dimensions -> PolygonRings -> Builder
polygonWKT dimensions (PolygonRings shell holes)
    | coordinatesEmpty shell = "EMPTY"
    | otherwise = "(" <> coordinatesWKT dimensions shell <> V.foldMap (\ring -> ", " <> coordinatesWKT dimensions ring) holes <> ")"

-- | Render a sequence in the dimensions selected by its containing geometry.
coordinatesWKT :: Dimensions -> Coordinates -> Builder
coordinatesWKT dimensions = withCoordinates (sequenceWKT (coordinateWKT dimensions))

-- | Preserve finite bits with scientific notation and pad absent extra ordinates.
coordinateWKT :: forall c. (Coordinate c) => Dimensions -> c -> Builder
coordinateWKT target coordinateValue =
    let (x, y, z, m) = coordinateComponents coordinateValue
        source = coordinateDimensions (Proxy :: Proxy c)
        ordinate = RealFloat.formatDouble RealFloat.scientific
        zValue = if source == DimXYZ || source == DimXYZM then z else 0 / 0
        mValue = if source == DimXYM || source == DimXYZM then m else 0 / 0
        extra = case target of
            DimXY -> mempty
            DimXYZ -> " " <> ordinate zValue
            DimXYM -> " " <> ordinate mValue
            DimXYZM -> " " <> ordinate zValue <> " " <> ordinate mValue
     in ordinate x <> " " <> ordinate y <> extra

-- | Render a vector as EMPTY or a parenthesized sequence.
sequenceWKT :: (G.Vector v a) => (a -> Builder) -> v a -> Builder
sequenceWKT render values
    | G.null values = "EMPTY"
    | otherwise = "(" <> G.ifoldr (\i value rest -> separator i <> render value <> rest) mempty values <> ")"

-- | Separate elements after the first element.
separator :: Int -> Builder
separator 0 = mempty
separator _ = ", "
