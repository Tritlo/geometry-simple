{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

{- | Checked WKT decoding and encoding for the seven simple geometry families.

Untagged geometries use XY coordinates. Use Z, M, or ZM for other layouts.
Every geometry in a collection must declare the same layout, including empty
members. Keywords are case-insensitive. Both MULTIPOINT spellings are accepted.

Decoding requires complete input, finite coordinates, and whitespace between
ordinates. It does not check topology.
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
import Control.Monad.Trans.State.Strict (StateT (..), get, gets, modify', put)
import Data.Char (isAsciiLower, isAsciiUpper, isSpace)
import Data.Geometry.Internal
import Data.Geometry.WKB (encodeWKT)
import Data.Proxy (Proxy (..))
import Data.Ratio ((%))
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Read as TextRead
import qualified Data.Vector.Generic as V
import qualified Data.Vector.Generic.Mutable as M

-- | The remaining text and a controlled parse error.
type Parser = StateT Text (Either String)

{- | Decode WKT with the requested coordinate layout.
Empty geometries also require matching dimensions. Untagged input is XY.
-}
decodeWKT :: (Coordinate c) => Text -> Either String (Geometry c)
decodeWKT input = do
    (geometry, remaining) <- runStateT (geometryParser <* spaces) input
    if Text.null remaining
        then Right geometry
        else Left "Geometry WKT has trailing input"

-- | Decode WKT and retain the coordinate layout declared in its header.
decodeAnyWKT :: Text -> Either String AnyGeometry
decodeAnyWKT input = do
    ((_, dimensions), _) <- runStateT header input
    case dimensions of
        DimXY -> GeometryXY <$> decodeWKT input
        DimXYZ -> GeometryXYZ <$> decodeWKT input
        DimXYM -> GeometryXYM <$> decodeWKT input
        DimXYZM -> GeometryXYZM <$> decodeWKT input

-- | Stop parsing with a geometry-specific error.
failure :: String -> Parser a
failure message = lift (Left ("Geometry WKT " ++ message))

-- | Consume whitespace before a structural token.
spaces :: Parser ()
spaces = modify' (Text.dropWhile isSpace)

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
header :: Parser (Int, Dimensions)
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
                Just dimensions -> put rest >> pure (family, dimensions)
                Nothing -> pure (family, DimXY)
        Nothing -> case attached of
            [result] -> pure result
            _ -> failure "has an unsupported geometry type"

-- | Parse one geometry and check dimensions before allocating its children.
geometryParser :: forall c. (Coordinate c) => Parser (Geometry c)
geometryParser = do
    (family, dimensions) <- header
    unless (dimensions == coordinateDimensions (Proxy :: Proxy c)) $
        failure "has the wrong coordinate dimensions"
    let line = vector coordinate
        polygon = vector line
    case family of
        1 -> PointGeometry <$> point True
        2 -> LineString <$> line
        3 -> Polygon <$> polygon
        4 -> MultiPoint <$> vector (point False)
        5 -> MultiLineString <$> vector line
        6 -> MultiPolygon <$> vector polygon
        _ -> GeometryCollection <$> vector geometryParser

-- | Parse an empty point or coordinates, with optional MULTIPOINT parentheses.
point :: (Coordinate c) => Bool -> Parser (Point c)
point requireParens = do
    empty <- emptyKeyword
    if empty
        then pure EmptyPoint
        else do
            parenthesized <- gets ((== Just '(') . fmap fst . Text.uncons)
            if requireParens || parenthesized
                then symbol '(' *> (Point <$> coordinate) <* symbol ')'
                else Point <$> coordinate

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
    unless (maybe False (isSpace . fst) (Text.uncons input)) $
        failure "requires whitespace between coordinates"
    spaces
    number

{- | Parse the decimal coefficient exactly, then round once to Double.
Bound extreme exponents so integer powers stay proportional to input length.
Use 'fromRational' for rounding. 'TextRead.double' and 'TextRead.rational'
can underflow intermediate powers, including the power in @5e-324@.
WKT also permits @.5@ and @1.@, which those readers do not consume fully.
-}
number :: Parser Double
number = do
    input <- get
    let (negative, unsigned) = case Text.uncons input of
            Just ('-', rest) -> (True, rest)
            Just ('+', rest) -> (False, rest)
            _ -> (False, input)
        digit c = c >= '0' && c <= '9'
        (whole, afterWhole) = Text.span digit unsigned
        (fraction, afterFraction) = case Text.uncons afterWhole of
            Just ('.', rest) -> Text.span digit rest
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
                (digits, afterDigits) = Text.span digit afterSign
            when (Text.null digits) (failure "expected exponent digits")
            let magnitude = Text.foldl' (\n c -> min (exponentLimit + 1) (10 * n + toInteger (fromEnum c - fromEnum '0'))) 0 digits
            pure (if negativeExponent then negate magnitude else magnitude, afterDigits)
        _ -> pure (0, afterFraction)
    if (Text.all (== '0') whole && Text.all (== '0') fraction) || power < negate exponentLimit
        then put rest >> pure (if negative then -0.0 else 0.0)
        else do
            when (power > exponentLimit) (failure "has a non-finite coordinate")
            case TextRead.decimal (whole <> fraction) :: Either String (Integer, Text) of
                Right (coefficient, _) -> do
                    let adjustedPower = power - toInteger (Text.length fraction)
                        magnitude =
                            if adjustedPower >= 0
                                then fromInteger (coefficient * 10 ^ adjustedPower)
                                else fromRational (coefficient % (10 ^ negate adjustedPower))
                        value = if negative then negate magnitude else magnitude
                    if isInfinite value
                        then failure "has a non-finite coordinate"
                        else put rest >> pure value
                _ -> failure "has a non-finite or invalid coordinate"
