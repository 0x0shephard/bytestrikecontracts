//SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/**
 * @title Calculations Library
 * @author Sheep
 * @notice A library for fixed-point arithmetic with 18 decimals of precision.
 * It helps prevent overflow/underflow and maintains precision for financial calculations.
 * All numbers are expected to be scaled by 10**18 (WAD).
 */
library Calculations {
    // The scaling factor for 18 decimal places (10^18).
    uint256 private constant WAD = 1e18;
    // The maximum value for a uint256.
    uint256 private constant MAX_UINT256 = type(uint256).max;

    /**
     * @notice Multiplies two WAD-precision numbers.
     * @dev Calculates (a * b) / 1e18.
     * @param a The first number, scaled by 1e18.
     * @param b The second number, scaled by 1e18.
     * @return The result, scaled by 1e18.
     */
    function mul(uint256 a, uint256 b) internal pure returns (uint256) {
        if (a == 0 || b == 0) {
            return 0;
        }
        // Check for overflow before multiplication.
        require(a <= MAX_UINT256 / b, "Calculations: mul overflow");
        return (a * b) / WAD;
    }

    /**
     * @notice Divides two WAD-precision numbers.
     * @dev Calculates (a * 1e18) / b.
     * @param a The numerator, scaled by 1e18.
     * @param b The denominator, scaled by 1e18.
     * @return The result, scaled by 1e18.
     */
    function div(uint256 a, uint256 b) internal pure returns (uint256) {
        require(b > 0, "Calculations: division by zero");
        // Check for overflow before scaling the numerator.
        require(a <= MAX_UINT256 / WAD, "Calculations: div overflow");
        return (a * WAD) / b;
    }

    /**
     * @notice Converts a standard integer to its WAD-precision representation.
     * @param a The integer to convert.
     * @return The WAD-precision number.
     */
    function toWad(uint256 a) internal pure returns (uint256) {
        require(a <= MAX_UINT256 / WAD, "Calculations: toWad overflow");
        return a * WAD;
    }

    /**
     * @notice Converts a WAD-precision number back to a standard integer.
     * @dev This will truncate any fractional part.
     * @param a The WAD-precision number to convert.
     * @return The standard integer.
     */
    function fromWad(uint256 a) internal pure returns (uint256) {
        return a / WAD;
    }

    /**
     * @notice Full precision multiply and divide: floor(a * b / denominator).
     * @dev Uses 512-bit intermediate representation to avoid overflow.
     */
    function mulDiv(
        uint256 a,
        uint256 b,
        uint256 denominator
    ) internal pure returns (uint256 result) {
        unchecked {
            uint256 prod0; // Least significant 256 bits of the product
            uint256 prod1; // Most significant 256 bits of the product
            assembly {
                let mm := mulmod(a, b, not(0))
                prod0 := mul(a, b)
                prod1 := sub(sub(mm, prod0), lt(mm, prod0))
            }
            if (prod1 == 0) {
                require(denominator > 0, "Calculations: div0");
                return prod0 / denominator;
            }
            require(denominator > prod1, "Calculations: overflow");
            // Make division exact by subtracting the remainder from [prod1 prod0]
            uint256 remainder;
            assembly {
                remainder := mulmod(a, b, denominator)
                prod1 := sub(prod1, gt(remainder, prod0))
                prod0 := sub(prod0, remainder)
            }
            // Factor powers of two out of denominator
            uint256 twos = denominator & (~denominator + 1);
            assembly {
                denominator := div(denominator, twos)
                prod0 := div(prod0, twos)
                twos := add(div(sub(0, twos), twos), 1)
            }
            prod0 |= prod1 * twos;
            // Inverse of denominator mod 2^256
            uint256 inv = (3 * denominator) ^ 2;
            inv *= 2 - denominator * inv; // inverse mod 2^8
            inv *= 2 - denominator * inv; // inverse mod 2^16
            inv *= 2 - denominator * inv; // inverse mod 2^32
            inv *= 2 - denominator * inv; // inverse mod 2^64
            inv *= 2 - denominator * inv; // inverse mod 2^128
            inv *= 2 - denominator * inv; // inverse mod 2^256
            result = prod0 * inv;
            return result;
        }
    }

    /**
     * @notice Full precision mulDiv with rounding up when there is a remainder.
     */
    function mulDivRoundingUp(
        uint256 a,
        uint256 b,
        uint256 denominator
    ) internal pure returns (uint256 result) {
        result = mulDiv(a, b, denominator);
        unchecked {
            if (mulmod(a, b, denominator) != 0) {
                require(result < type(uint256).max, "Calculations: overflow");
                result++;
            }
        }
    }

    /**
     * @notice Integer square root via Newton-Raphson, rounds down.
     */
    function sqrt(uint256 x) internal pure returns (uint256 r) {
        if (x == 0) return 0;
        uint256 xx = x;
        uint256 x0 = 1;
        if (xx >= 0x100000000000000000000000000000000) { xx >>= 128; x0 <<= 64; }
        if (xx >= 0x10000000000000000) { xx >>= 64; x0 <<= 32; }
        if (xx >= 0x100000000) { xx >>= 32; x0 <<= 16; }
        if (xx >= 0x10000) { xx >>= 16; x0 <<= 8; }
        if (xx >= 0x100) { xx >>= 8; x0 <<= 4; }
        if (xx >= 0x10) { xx >>= 4; x0 <<= 2; }
        if (xx >= 0x8) { x0 <<= 1; }
        r = (x0 + x / x0) >> 1;
        r = (r + x / r) >> 1;
        r = (r + x / r) >> 1;
        r = (r + x / r) >> 1;
        r = (r + x / r) >> 1;
        r = (r + x / r) >> 1;
        r = (r + x / r) >> 1;
        uint256 r1 = x / r;
        return (r < r1) ? r : r1;
    }
}


