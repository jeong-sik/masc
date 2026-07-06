(** Keeper context snapshot helpers for operator control snapshots. *)

val compute_context_ratio : Keeper_meta_contract.keeper_meta -> float option

type keeper_context_snapshot =
  { context_ratio : float option
  ; context_tokens : int option
  ; context_max : int option
  ; context_source : string option
  }

val keeper_context_snapshot_is_empty : keeper_context_snapshot -> bool

val keeper_context_snapshot_from_metrics_json :
  Yojson.Safe.t -> keeper_context_snapshot option

val latest_keeper_context_snapshot_from_files :
  Workspace.config -> string -> keeper_context_snapshot option
val latest_keeper_context_snapshot_from_files_with_read_errors :
  Workspace.config -> string -> keeper_context_snapshot option * Yojson.Safe.t list

val fallback_keeper_context_snapshot :
  Keeper_meta_contract.keeper_meta -> keeper_context_snapshot

val keeper_context_snapshot_of_meta :
  Workspace.config -> Keeper_meta_contract.keeper_meta -> keeper_context_snapshot
val keeper_context_snapshot_of_meta_with_read_errors :
  Workspace.config ->
  Keeper_meta_contract.keeper_meta ->
  keeper_context_snapshot * Yojson.Safe.t list

val keeper_context_snapshot_fields :
  keeper_context_snapshot -> (string * Yojson.Safe.t) list
