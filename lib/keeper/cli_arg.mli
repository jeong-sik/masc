(** CLI argument parser for ocaml-masc.

    Parses [argv]-style arrays against a [spec] list. Supports
    long flags (--verbose), long options with space or [=] separator
    (--output file.txt / --output=file.txt), positional arguments,
    optional positionals with defaults, and [--] separator.

    A successful parse returns [t] with query helpers; on failure
    an [error] variant makes diagnostics straightforward. *)

(** {1 Specification} *)

type spec =
  | Positional of string
      (** Required positional argument, e.g. [Positional "filename"]. *)
  | Flag of string
      (** Boolean flag, e.g. [Flag "verbose"]. Present → ["true"]. *)
  | Option of string
      (** Flag that takes a value, e.g. [Option "output"]. *)
  | Positional_opt of string * string
      (** Optional positional with default value,
          e.g. [Positional_opt ("format", "json")]. *)

(** {1 Result} *)

type t = {
  positional : string list;
      (** Trailing positional arguments beyond the spec. *)
  named : (string, string) Hashtbl.t;
      (** All named values — flags, options, positional assignments. *)
}

type error =
  | Unknown_flag of string  (** e.g. [--undefined] *)
  | Missing_value of string (** e.g. [--output] without argument *)
  | Missing_positional of string  (** required positional absent *)

val pp_error : error -> string
(** Human-readable error message. *)

(** {1 Parse} *)

val parse : spec list -> string array -> (t, error) result
(** [parse specs argv] consumes [argv] (skipping [argv.(0)] as the
    program name) according to [specs]. Returns [Ok t] on success,
    [Error err] on first parse error. *)

(** {1 Query helpers} *)

val get_flag : t -> string -> bool
(** [get_flag t name] returns [true] if the flag [--name] was set,
    [false] otherwise. *)

val has_flag : t -> string -> bool
(** Alias for {!get_flag}. *)

val positional_args : t -> string list
(** [positional_args t] returns leftover positional arguments that
    did not match any [Positional] or [Positional_opt] spec. *)

val get_option : t -> string -> string option
(** [get_option t name] returns [Some value] if option [--name] was
    provided, [None] if absent or if [name] is a plain flag. *)