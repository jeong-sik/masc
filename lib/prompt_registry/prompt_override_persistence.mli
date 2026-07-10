(** Versioned, contract-bound persistence for prompt overrides.

    Persisted entries are accepted only when their [contract_revision]
    matches the current prompt contract.  The revision intentionally does not
    reuse [Prompt_registry_types.prompt_entry.version]: that field versions the
    older registry entry model, while this digest binds an override to the
    exact markdown/default body and declared template variables it was
    authored against. *)

type entry = {
  key : string;
  value : string;
  contract_revision : string;
}

type error

val schema_version : int

val contract_revision :
  body:string -> template_variables:string list -> string
(** SHA256 of the canonical JSON object containing [body] and the sorted
    [template_variables] list. *)

val load : path:string -> (entry list, error) result
(** Decode the versioned persistence envelope at [path].  Bare legacy maps,
    wrong schema versions, malformed field types, duplicate JSON fields, and
    duplicate override keys are rejected as typed errors. *)

val save : path:string -> entry list -> (unit, error) result
(** Atomically replace [path] with the canonical versioned envelope. *)

val error_to_string : error -> string
