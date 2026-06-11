(** Command-line argument parser — typed, standalone.

    Supports:
    - {b Positional arguments} — ordered, required, named.
    - {b Flags} — boolean switches ([--verbose]).
    - {b Options} — key-value flags ([--output file.txt]).

    The parser operates on [Sys.argv] style [string array] input
    and produces a typed result via {!parse}.

    @since 3.0.0 *)

(** {1 Specifications} *)

(** A spec describes one command-line parameter. *)
type spec =
  (** A positional argument with a name (for help/errors). *)
  | Positional of string
  (** A boolean flag: [--verbose] sets true. *)
  | Flag of string
  (** An option with a value: [--output file.txt] stores ["file.txt"]. *)
  | Option of string
  (** A named positional with default value. *)
  | Positional_opt of string * string

(** {1 Parsed result} *)

(** Parsed arguments indexed by spec name. *)
type t = {
  positional : string list;       (** unnamed positional args *)
  named : (string, string) Hashtbl.t;  (** spec name -> parsed value *)
}

(** {1 Errors} *)

type error =
  | Unknown_flag of string
  | Missing_value of string
  | Missing_positional of string

val pp_error : error -> string
(** Human-readable error message. *)

(** {1 Parsing} *)

val parse : spec list -> string array -> (t, error) result
(** [parse specs argv] parses [argv] according to [specs].
    - Leading positional args before any [--] are matched left-to-right.
    - Flags ([--name]) are matched by name.
    - Options ([--name value]) consume the next token.
    - [--] ends flag/option parsing; remaining tokens are positional.
    - Unrecognised flags/options return {!Unknown_flag}.
    - Missing option values return {!Missing_value}.
    - Missing required positionals return {!Missing_positional}.
    - Bool flags default to [false]; optional strings default to [""]. *)