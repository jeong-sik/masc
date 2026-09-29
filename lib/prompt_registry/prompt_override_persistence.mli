(** Versioned persistence for prompt overrides.

    An entry records what the operator wrote and what they wrote it against:
    the digest of the default body at the time ([authored_against]) and the
    template-variable contract the prompt declared then
    ([template_variables]). Neither is a gate. The registry applies a saved
    override whenever it still renders under the prompt's current contract,
    and uses these fields only to compare known history with the current
    default. Missing history is reported as unknown. A release that rewrites
    a default body leaves the operator's prompt in force. *)

type entry = {
  key : string;
  value : string;
  authored_against : string option;
      (** {!default_revision} of the default body the override replaced when
          it was saved. [None] means the historical binding is unavailable; it
          cannot establish whether the default changed. The disk codec keeps
          the existing empty-string spelling at this boundary only. *)
  template_variables : string list;
      (** The prompt's declared template variables when the override was
          saved, sorted. *)
}

type error

val default_revision : body:string -> string
(** SHA256 hex of the default body. Stored as [authored_against] and
    compared against the current body to report that the default moved. *)

val load : path:string -> (entry list, error) result
(** Decode the versioned persistence envelope at [path]. Bare maps, other
    schema versions, malformed field types, duplicate JSON fields, and
    duplicate override keys are rejected as typed errors. *)

val load_preset : path:string -> (entry list, error) result
(** {!load} for a saved preset, which also reads the schema 1 envelope that
    presets written before 2026-09-08 carry. A schema 1 entry keeps its key
    and value; what it was written against is unknown, so [authored_against]
    is [None] and [template_variables] is [[]]. A restored entry therefore
    has unknown provenance, not evidence of a changed default. The file is
    only read, never rewritten.
    The live override table keeps {!load}: only schema 2 is its format. *)

val save : path:string -> entry list -> (unit, error) result
(** Atomically replace [path] with the canonical versioned envelope. *)

val error_to_string : error -> string
