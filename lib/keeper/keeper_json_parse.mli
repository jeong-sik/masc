(** Simple JSON parser with basic types and error handling.

    Parses JSON strings into a typed AST without external dependencies
    beyond the OCaml standard library. Produces detailed error messages
    with approximate line/column position on parse failure. *)

type json =
  | Null
  | Bool of bool
  | Int of int
  | Float of float
  | String of string
  | Array of json list
  | Object of (string * json) list

val parse : string -> (json, string) result
(** Parse a JSON string into a [json] value. Returns [Error msg] with
    approximate line:column position on syntax errors. *)

val to_string : json -> string
(** Compact single-line string representation. *)

val pp : Format.formatter -> json -> unit
(** Pretty-printed output, 2-space indentation. *)