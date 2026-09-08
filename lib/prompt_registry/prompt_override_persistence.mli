(** Versioned persistence for prompt overrides.

    An entry records what the operator wrote and what they wrote it against:
    the digest of the default body at the time ([authored_against]) and the
    template-variable contract the prompt declared then
    ([template_variables]). Neither is a gate on its own. The registry applies
    a saved override whenever it still renders under the prompt's current
    contract, and uses these two fields only to say that the default moved
    underneath it since it was written. A release that rewrites a default
    body no longer turns the operator's prompt off. *)

type entry = {
  key : string;
  value : string;
  authored_against : string;
      (** {!default_revision} of the default body the override replaced when
          it was saved. *)
  template_variables : string list;
      (** The prompt's declared template variables when the override was
          saved, sorted. *)
}

type error

val default_revision : body:string -> string
(** SHA256 hex of the default body. Stored as [authored_against] and
    compared against the current body to report that the default moved. *)

val load : path:string -> (entry list, error) result
(** Decode the versioned persistence envelope at [path]. Bare legacy maps,
    other schema versions, malformed field types, duplicate JSON fields, and
    duplicate override keys are rejected as typed errors. *)

val save : path:string -> entry list -> (unit, error) result
(** Atomically replace [path] with the canonical versioned envelope. *)

val error_to_string : error -> string
