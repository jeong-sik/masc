(** Exact Keeper identity binding across live registry and persisted metadata.

    [resolve] compares only the stored [agent_name] field in the live registry
    or persisted metadata. It never parses or canonicalizes a free-form agent
    string. Duplicate bindings and storage failures remain explicit so callers
    cannot silently select a Keeper. *)

type resolution =
  | Not_found
  | Unique of string
  | Ambiguous of string list
  | Lookup_failed of string

val resolve :
  config:Workspace.config -> agent_name:string -> resolution
