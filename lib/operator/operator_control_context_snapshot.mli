(** Keeper context snapshot helpers for operator control snapshots. *)

val compute_context_ratio : Keeper_meta_contract.keeper_meta -> float option

type context_metrics_read_error =
  | Storage_read_failed of Dated_jsonl.read_error
  | Malformed_metrics_row of
      { path : string
      ; line_number : int option
      ; detail : string
      }

type keeper_context_snapshot =
  { context_ratio : float option
  ; context_tokens : int option
  ; context_max : int option
  ; context_source : string option
  ; context_metrics_unavailable : context_metrics_read_error option
  }

val keeper_context_snapshot_is_empty : keeper_context_snapshot -> bool

val keeper_context_snapshot_from_metrics_json :
  Yojson.Safe.t -> keeper_context_snapshot option

val latest_keeper_context_snapshot_from_files :
  Workspace.config -> string ->
  (keeper_context_snapshot option, context_metrics_read_error) result

val fallback_keeper_context_snapshot :
  Keeper_meta_contract.keeper_meta -> keeper_context_snapshot

val keeper_context_snapshot_of_meta :
  Workspace.config -> Keeper_meta_contract.keeper_meta -> keeper_context_snapshot

val keeper_context_snapshot_fields :
  keeper_context_snapshot -> (string * Yojson.Safe.t) list
