{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

{- | Checked WKT decoding and encoding for the seven simple geometry families.

Untagged coordinates infer XY, XYZ, or XYZM from their arity. Use M for
measured coordinates. Explicit collection tags also constrain their children.
Keywords are case-insensitive. The decoder accepts
@MULTIPOINT (1 2, 3 4)@ and @MULTIPOINT ((1 2), (3 4))@.

Decoding requires complete input and whitespace between ordinates. It checks
line lengths and ring closure. NaN and infinity are accepted. It does not
check polygon topology.
EWKT SRID prefixes are not supported. Keep CRS metadata beside the geometry.
-}
module Data.Geometry.WKT (
    decodeWKT,
    decodeAnyWKT,
    encodeWKT,
) where

import Control.Monad (unless, when)
import Control.Monad.ST (runST)
import Control.Monad.Trans.Class (lift)
import Control.Monad.Trans.State.Strict (StateT (..), get, modify', put)
import Data.Bits ((.|.))
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
import qualified Data.Vector.Generic as V
import qualified Data.Vector.Generic.Mutable as M
import qualified Data.Vector.Unboxed as U

-- | The remaining text and a controlled parse error.
type Parser = StateT Text (Either String)

{- | Decode WKT into the requested coordinate type.
Untagged coordinates infer dimensions from their arity. An untagged EMPTY
body is XY. Collections infer dimensions from their members. The inferred
root dimensions must match the type.
-}
decodeWKT :: forall c. (Coordinate c) => Text -> Either String (Geometry c)
{-# SPECIALIZE decodeWKT :: Text -> Either String (Geometry XY) #-}
{-# SPECIALIZE decodeWKT :: Text -> Either String (Geometry XYZ) #-}
{-# SPECIALIZE decodeWKT :: Text -> Either String (Geometry XYM) #-}
{-# SPECIALIZE decodeWKT :: Text -> Either String (Geometry XYZM) #-}
decodeWKT input = do
    ((geometry, dimensions, _), remaining) <- runStateT (geometryParser <* spaces) input
    unless (dimensions == coordinateDimensions (Proxy :: Proxy c)) $
        Left "Geometry WKT has the wrong coordinate dimensions"
    if Text.null remaining
        then Right geometry
        else Left "Geometry WKT has trailing input"

-- | Decode WKT and retain explicit or inferred coordinate dimensions.
decodeAnyWKT :: Text -> Either String AnyGeometry
decodeAnyWKT input = do
    ((_, dimensions), _) <- runStateT header input
    case dimensions of
        Just DimXY -> GeometryXY <$> decodeWKT input
        Just DimXYZ -> GeometryXYZ <$> decodeWKT input
        Just DimXYM -> GeometryXYM <$> decodeWKT input
        Just DimXYZM -> GeometryXYZM <$> decodeWKT input
        Nothing ->
            firstSuccess
                [ GeometryXY <$> decodeWKT input
                , GeometryXYZ <$> decodeWKT input
                , GeometryXYM <$> decodeWKT input
                , GeometryXYZM <$> decodeWKT input
                ]
  where
    firstSuccess [] = Left "Geometry WKT has inconsistent coordinate dimensions or invalid syntax"
    firstSuccess (Right shape : _) = Right shape
    firstSuccess (Left _ : rest) = firstSuccess rest

{- | Encode WKT with a dimension suffix for XYZ, XYM, and XYZM geometries.
Empty geometries retain their dimensions. Each ordinate uses scientific
notation with the shortest digits that decode to the same Double, such as
@1.0e0@.
-}
encodeWKT :: (Coordinate c) => Geometry c -> Either String Text
{-# SPECIALIZE encodeWKT :: Geometry XY -> Either String Text #-}
{-# SPECIALIZE encodeWKT :: Geometry XYZ -> Either String Text #-}
{-# SPECIALIZE encodeWKT :: Geometry XYM -> Either String Text #-}
{-# SPECIALIZE encodeWKT :: Geometry XYZM -> Either String Text #-}
encodeWKT geometry = do
    validateGeometry (const (Right ())) geometry
    pure (TextEncoding.decodeUtf8 (BL.toStrict (Builder.toLazyByteString (geometryWKT geometry))))

-- | Stop parsing with a geometry-specific error.
failure :: String -> Parser a
failure message = lift (Left ("Geometry WKT " ++ message))

-- | Consume whitespace before a structural token.
spaces :: Parser ()
spaces = modify' (Text.dropWhile whitespace)

-- | Accept the ASCII whitespace that WKT readers use: space, tab, LF, and CR.
whitespace :: Char -> Bool
whitespace c = c == ' ' || c == '\t' || c == '\n' || c == '\r'

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
    let (name, rest) = Text.span (\c -> isAsciiLower c || isAsciiUpper c) input
    when (Text.null name) (failure "expected a keyword")
    put rest
    pure (Text.toUpper name)

-- | Consume EMPTY when it is the next complete keyword.
emptyKeyword :: Parser Bool
emptyKeyword = do
    spaces
    input <- get
    let (name, rest) = Text.span (\c -> isAsciiLower c || isAsciiUpper c) input
    if Text.toUpper name == "EMPTY"
        then put rest >> pure True
        else pure False

-- | Read the geometry family and an attached or separate dimension suffix.
header :: Parser (Int, Maybe Dimensions)
header = do
    name <- word
    let families = [("POINT", 1), ("LINESTRING", 2), ("POLYGON", 3), ("MULTIPOINT", 4), ("MULTILINESTRING", 5), ("MULTIPOLYGON", 6), ("GEOMETRYCOLLECTION", 7)]
        suffixes = [("ZM", DimXYZM), ("Z", DimXYZ), ("M", DimXYM)]
        attached = [(family, dimensions) | (suffix, dimensions) <- suffixes, Just base <- [Text.stripSuffix suffix name], Just family <- [lookup base families]]
    case lookup name families of
        Just family -> do
            spaces
            input <- get
            let (tag, rest) = Text.span (\c -> isAsciiLower c || isAsciiUpper c) input
            case lookup (Text.toUpper tag) suffixes of
                Just dimensions -> put rest >> pure (family, Just dimensions)
                Nothing -> pure (family, Nothing)
        Nothing -> case attached of
            [(family, dimensions)] -> pure (family, Just dimensions)
            _ -> failure "has an unsupported geometry type"

-- | Keep the parsed tag separate from the dimensions retained by GEOS geometry values.
geometryParser :: forall c. (Coordinate c) => Parser (Geometry c, Dimensions, Dimensions)
geometryParser = do
    (family, declared) <- header
    let wanted = coordinateDimensions (Proxy :: Proxy c)
        position = do
            unless (maybe (wanted /= DimXYM) (== wanted) declared) $
                failure "has the wrong coordinate dimensions"
            coordinate
        line = do
            points <- vector position
            lift (validateLine points)
            pure points
        polygon = do
            rings <- vector (vector position)
            lift (validatePolygon rings)
            pure rings
    if family == 7
        then do
            members <- vector geometryParser
            let observed = V.foldl' (\acc (_, _, dim) -> toEnum (fromEnum acc .|. fromEnum dim)) DimXY members
                dimensions = fromMaybe observed declared
            case declared of
                Just dim -> unless (V.all (\(_, child, _) -> child == dim) members) (failure "has mixed coordinate dimensions")
                Nothing -> pure ()
            pure (GeometryCollection (V.map (\(shape, _, _) -> shape) members), dimensions, observed)
        else do
            shape <- case family of
                1 -> PointGeometry <$> point position
                2 -> LineString <$> line
                3 -> Polygon <$> polygon
                4 -> MultiPoint <$> multiPoint position
                5 -> MultiLineString <$> vector line
                _ -> MultiPolygon <$> vector polygon
            let dimensions = fromMaybe (if geometryEmpty shape then DimXY else wanted) declared
                observed = case shape of
                    MultiPoint points | U.null points -> DimXY
                    MultiLineString lineStrings | V.null lineStrings -> DimXY
                    MultiPolygon polygons | V.null polygons -> DimXY
                    _ -> dimensions
            pure (shape, dimensions, observed)

-- | Parse a parenthesized coordinate or an empty point.
point :: Parser c -> Parser (Point c)
point position = do
    empty <- emptyKeyword
    if empty
        then pure EmptyPoint
        else symbol '(' *> (Point <$> position) <* symbol ')'

-- | MULTIPOINT uses one spelling throughout: bare coordinates or point bodies.
multiPoint :: (Coordinate c) => Parser c -> Parser (U.Vector (Point c))
multiPoint position = do
    spaces
    input <- get
    let first = Text.dropWhile whitespace (Text.drop 1 input)
        parenthesized = Text.isPrefixOf "(" first || Text.isPrefixOf "EMPTY" (Text.toUpper first)
    vector (if parenthesized then point position else Point <$> position)

-- | Build each sequence directly in a growable vector, then copy its used slice.
vector :: (V.Vector v a) => Parser a -> Parser (v a)
vector element = do
    empty <- emptyKeyword
    if empty
        then pure V.empty
        else do
            symbol '('
            StateT $ \input -> runST $ do
                initial <- M.new 16
                let go !count buffer remaining = case runStateT element remaining of
                        Left message -> pure (Left message)
                        Right (value, afterElement) -> case runStateT delimiter afterElement of
                            Left message -> pure (Left message)
                            Right (finished, rest) -> do
                                target <- if count == M.length buffer then M.grow buffer (M.length buffer) else pure buffer
                                M.write target count value
                                if finished
                                    then do
                                        result <- V.freeze (M.slice 0 (count + 1) target)
                                        pure (Right (result, rest))
                                    else go (count + 1) target rest
                go 0 initial input

-- | Consume a comma or the closing parenthesis of a nonempty sequence.
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
        (keyword, afterKeyword) = Text.span (\c -> isAsciiLower c || isAsciiUpper c) unsigned
        special = lookup (Text.toUpper keyword) [("NAN", 0 / 0), ("INF", 1 / 0), ("INFINITY", 1 / 0)]
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
                magnitude =
                    if power > exponentLimit
                        then 1 / 0
                        else
                            if adjustedPower >= 0
                                then fromInteger (coefficient * 10 ^ adjustedPower)
                                else fromRational (coefficient % (10 ^ negate adjustedPower))
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

-- | Render a validated geometry with its family and dimension suffix.
geometryWKT :: forall c. (Coordinate c) => Geometry c -> Builder
geometryWKT geometry = name <> suffix <> " " <> body
  where
    suffix = case coordinateDimensions (Proxy :: Proxy c) of
        DimXY -> ""
        DimXYZ -> " Z"
        DimXYM -> " M"
        DimXYZM -> " ZM"
    (name, body) = case geometry of
        PointGeometry value -> ("POINT", pointWKT value)
        LineString points -> ("LINESTRING", sequenceWKT coordinateWKT points)
        Polygon rings -> ("POLYGON", sequenceWKT (sequenceWKT coordinateWKT) (normalizePolygon rings))
        MultiPoint points -> ("MULTIPOINT", sequenceWKT pointWKT points)
        MultiLineString lineStrings -> ("MULTILINESTRING", sequenceWKT (sequenceWKT coordinateWKT) lineStrings)
        MultiPolygon polygons -> ("MULTIPOLYGON", sequenceWKT (sequenceWKT (sequenceWKT coordinateWKT) . normalizePolygon) polygons)
        GeometryCollection children -> ("GEOMETRYCOLLECTION", sequenceWKT geometryWKT children)

-- | Render an empty point or a parenthesized coordinate.
pointWKT :: (Coordinate c) => Point c -> Builder
pointWKT EmptyPoint = "EMPTY"
pointWKT (Point position) = "(" <> coordinateWKT position <> ")"

-- | Render the ordinates in their declared order without intermediate lists.
coordinateWKT :: forall c. (Coordinate c) => c -> Builder
coordinateWKT position =
    let (x, y, z, m) = coordinateComponents position
        ordinate = RealFloat.formatDouble RealFloat.scientific
        extra = case coordinateDimensions (Proxy :: Proxy c) of
            DimXY -> mempty
            DimXYZ -> " " <> ordinate z
            DimXYM -> " " <> ordinate m
            DimXYZM -> " " <> ordinate z <> " " <> ordinate m
     in ordinate x <> " " <> ordinate y <> extra

-- | Render a vector as EMPTY or a parenthesized sequence, without a list.
sequenceWKT :: (V.Vector v a) => (a -> Builder) -> v a -> Builder
sequenceWKT render values
    | V.null values = "EMPTY"
    | otherwise = "(" <> V.ifoldr (\i value rest -> separator i <> render value <> rest) mempty values <> ")"

-- | Separate elements after the first element.
separator :: Int -> Builder
separator 0 = mempty
separator _ = ", "
