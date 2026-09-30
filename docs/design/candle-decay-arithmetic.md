# Candle decay arithmetic contract

This contract fixes the precision and rounding required by RFC-goal-candle-ledger §3.1.1 before implementing `Candle_decay`. It describes a pure interval calculation. Config parsing, HalfLifeSet recording, ordered wallet replay and runtime effects are separate consumers.

## Inputs and arithmetic

- Policy is `Off` or `Hours h`, where `h` is a positive public integer. There is no default half-life. The typed operation rejects invalid constructed Hours, negative money and backwards time, including under Off.
- Amount is an OCaml nonnegative `int`; the MASC 63-bit integer range gives amount < 2^62. Output is between zero and that amount.
- Both instants are `Candle_time.t`, UTC whole seconds. Form elapsed seconds with exact Zarith `days * 86400 + picoseconds / 10^12`; no raw fractional-picosecond policy is exposed. Form the half-life period as exact `h * 3600` seconds.
- Let `S = 2^128`, and write elapsed/period as whole `q` and fraction `r` in [0,1). Round `r` UP to `r' = ceil(r*S)/S`. Zero fraction remains exactly zero.
- Starting at exact Q128 one-half, compute binary factors `2^(-1/2^i)` for i=1..128 by `floor(sqrt(previous*S))`. Multiply factors selected by the binary digits of `r'`, rounding each Q128 product DOWN. A rounded fraction of one uses exact one-half.
- Return `floor(amount * coefficient / (S * 2^q))` with one final downward bit shift. For zero fraction use exact `floor(amount / 2^q)`. If whole periods reach the amount's bit length, the exact result is already below one milli and returns zero without converting a large exponent to int.

128 bits are an explicit monetary precision contract, not a Keeper runtime budget, retry bound or arbitrary control-flow gate. All roots/products/divisions use the existing Zarith dependency. Factors are immutable derived constants; no mutable cache, floating-point exp or platform-dependent rounding is used.

## Error bounds and equality

Every binary factor is rounded below its ideal value. With `S=2^128`, each factor's absolute coefficient error is strictly below `4/S`: if the previous error is below `4/S`, the difference of its square roots is the previous error divided by the sum of the two roots. Their sum exceeds `4/3` because the previous ideal factor is at least one-half and `S>72`. Adding the next root's less-than-`1/S` downward rounding keeps the error below `4/S`. The initial half is exact.

Selecting at most 128 factors contributes less than `512/S` coefficient loss. At most 128 coefficient multiplications contribute less than `128/S` more. Rounding the fractional exponent up adds less than `1/S`, since the derivative magnitude of `2^-r` is below one. The total coefficient error is below `641/S`. Multiplying by amount and by the exact whole-period factor does not increase this bound: loss before final monetary flooring is less than `641 * amount / S`, at most `641 * 2^-66` milli for the public range.

The coefficient and final monetary rounding never overpay relative to the ideal exponential. Quantization before final flooring is below one milli, but flooring can cross an integer boundary: the final integer is the ideal real floor or one below it. The fixed-point rule is the economic contract; exact equality with `floor(amount * 2^(-elapsed/period))` for every fractional input is not claimed.

Whole periods have zero fractional error and use exact integer halving. Keeping the original amount until the final shift matters: amount 3 after 1.5 periods has real floor 1, while incorrectly shifting 3 to 1 first and then applying the fractional coefficient produces zero.

## Supported time monotonicity

The largest period is `3600 * max_int < 2^74` seconds. A positive fractional step in these whole-second inputs is at least `1/period`; it is never an arbitrary 128-bit exponent step. Across [0,1], the ideal coefficient decreases by more than `1/(4*period)` per second because `ln(2)/2 > 1/4`. This exceeds the conservative coefficient error `641/S`: `S > 2564*period` for the supported period range. Hence two successive supported second ticks cannot reverse coefficient ordering. The same bound applies across a whole-period boundary, where the new exact half coefficient is used. The final downward shift preserves nonincreasing results.

This proof is restricted to typed whole-second time and positive integer-hour periods. It does not claim monotonicity for arbitrary subsecond exponents or general Q128 numbers.

## Evidence scope

The accompanying source fixtures cover explicit Off, exact half-lives, fractional intervals including 3 milli after 1.5 periods, zero amount, maximum public money, very large hour periods and invalid inputs. They are prepared source, not an executed runtime or native result. CI remains paused; no build, typecheck, native, model, runtime or CI run is part of this work unit.
