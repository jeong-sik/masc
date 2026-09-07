(** Immutable repetition evidence shared by durable operation journals and
    runtime adapters. No context, tool-result, provider, or storage effects. *)
type admission = Fresh of Keeper_execution_scope_id.t | Resume of Keeper_execution_scope_id.t
type observation = private
  { tool_name : string
  ; input_fingerprint : string option
  ; output_fingerprint : string option
  }
type t
type error =
  | Invalid_snapshot of string
  | Invalid_observation of string
  | Unknown_scope of Keeper_execution_scope_id.t
  | Restore_target_conflict
val error_to_string : error -> string
val observation : tool_name:string -> input_fingerprint:string option ->
  output_fingerprint:string option -> (observation, error) result
(** Validate nonblank tool names and canonicalize SHA-256 fingerprints. *)
val empty : t
val active : t -> Keeper_execution_scope_id.t option
val scope_ids : t -> Keeper_execution_scope_id.t list
(** All admitted identities, sorted by the identity comparator. *)
val admit : t -> admission -> (t, error) result
(** Fresh on an existing identity preserves evidence. Resume requires an
    admitted identity. Admitting another scope retains every prior scope. *)
val record : t -> scope:Keeper_execution_scope_id.t -> observation -> (t, error) result
(** Records a new observation, newest first. Not replay-safe ingestion. *)
val observations : t -> scope:Keeper_execution_scope_id.t -> (observation list, error) result
val equal : t -> t -> bool
(** Compares semantic snapshots, independent of map insertion order. *)
val to_json : t -> Yojson.Safe.t
val of_json : Yojson.Safe.t -> (t, error) result
(** Exact v1 codec shared with the session checkpoint projection. Invalid
    present data never becomes an empty or newly admitted scope. *)
