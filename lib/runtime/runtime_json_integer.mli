(** Integers crossing JSON consumers implemented with ECMAScript Number. *)
val of_json : Yojson.Safe.t -> (int, string) result
(** Accept JSON numeric values that are integral and exactly representable by
    both OCaml [int] and ECMAScript's safe-integer range [-(2^53-1), 2^53-1].
    Thus [1], [1.0] and [1e0] decode to the same integer. This is the JSON
    consumer's IEEE-754 precision boundary, not a runtime budget or counter cap.
    Strings, fractions, nonfinite floats and out-of-range values are errors.
    Domain constraints such as nonnegative indices belong to the caller. *)
