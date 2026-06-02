(** Parse TLC error trace files (`*_TTrace_*.tla`) produced by [TLC] when an
    invariant is violated.

    Two artefacts are extracted from the same file:
    - the violating final state recorded by the [_inv] operator (negated
      conjunction of [var = value] equalities), and
    - the full step sequence recorded by the inner [<Spec>_TETrace] module
      (the [trace == << [s1], [s2], ... >>] literal).

    The step sequence is optional: when the [<Spec>_TETrace] module is absent
    or unparseable, [steps] is the empty list and the [bindings] field still
    captures the terminal violating state. *)

type value =
  | V_int of int
  | V_string of string
  | V_bool of bool
  | V_raw of string
      (** TLA+ values the parser does not narrow further (tuples
          [<<...>>], sets [{...}], records [\[a |-> b\]]). The raw textual
          form is preserved verbatim so callers may decode it for their
          specific spec; emission is handled by [Ocaml_emit]. *)

type step = (string * value) list
(** A single state in a TLC counterexample, represented as the
    [field |-> value] map flattened to an association list. Field order
    follows the order reported by TLC; do not rely on stable field
    ordering across spec versions. *)

type state = {
  spec_module : string;        (** TLA module name from [---- MODULE X ----] *)
  trace_file  : string;        (** absolute path of the input file *)
  bindings    : (string * value) list;
      (** Terminal violating state from the [_inv] operator. *)
  steps       : step list;
      (** Full step sequence from the [<Spec>_TETrace] inner module. Empty
          when the inner module is missing or unparseable. *)
}

val parse_file : string -> (state, string) result
(** [parse_file path] reads [path] and returns the violating state, or an
    [Error msg] if the file does not contain a parseable [_inv] operator.

    The parser is intentionally narrow: it only recognises the structure
    emitted by [tla2tools.jar]'s default trace exporter. Hand-edited traces
    or alternative exporters fall through to [Error]. *)
