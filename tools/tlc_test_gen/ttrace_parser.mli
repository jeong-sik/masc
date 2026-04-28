(** Parse TLC error trace files (`*_TTrace_*.tla`) produced by [TLC] when an
    invariant is violated, and extract the violating final state.

    Input contract: a TLA+ trace module where the [_inv] operator carries a
    negated conjunction of [var = value] equalities representing the state
    that satisfied the invariant violation predicate.

    Out of scope (deferred): full [_TETrace] sequence reconstruction (the
    intermediate steps live in the companion [.bin] file produced by TLC and
    are not parseable from the [.tla] alone). *)

type value =
  | V_int of int
  | V_string of string
  | V_bool of bool

type state = {
  spec_module : string;        (** TLA module name from [---- MODULE X ----] *)
  trace_file  : string;        (** absolute path of the input file *)
  bindings    : (string * value) list;
}

val parse_file : string -> (state, string) result
(** [parse_file path] reads [path] and returns the violating state, or an
    [Error msg] if the file does not contain a parseable [_inv] operator.

    The parser is intentionally narrow: it only recognises the structure
    emitted by [tla2tools.jar]'s default trace exporter. Hand-edited traces
    or alternative exporters fall through to [Error]. *)
