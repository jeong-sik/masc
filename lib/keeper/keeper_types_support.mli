(** Keeper_types_support — model selection, path utilities,
    and JSONL append/rotation helpers.

    Extracted from keeper_types.ml to reduce file size.
    Depends only on Keeper_config (no Keeper_types dependency). *)

include module type of Keeper_config

(** Backward-compatible mkdir_p: delegates to [Keeper_fs.ensure_dir]. *)
val mkdir_p : string -> unit

(** Resolve the keeper base directory ([.masc/keepers]) for [config],
    creating it if missing. *)
val keeper_dir_ : Coord.config -> string

(** Resolve the trace base directory ([.masc/traces]) for [config],
    creating it if missing. *)
val session_base_dir_ : Coord.config -> string

(** Check API key availability for the given model labels via
    [Cascade_runtime]. *)
val ensure_api_keys_for_labels : string list -> (unit, string) result

(** Single-file metrics path kept for fallback reads. *)
val keeper_metrics_path : Coord.config -> string -> string

(** Date-split metrics store: [.masc/keepers/<name>/metrics/YYYY-MM/DD.jsonl].
    Cached per keeper name so all callers share the same Eio.Mutex. *)
val keeper_metrics_store : Coord.config -> string -> Dated_jsonl.t

(** Date-split sparse PR action metrics store:
    [.masc/keepers/<name>/pr-action-metrics/YYYY-MM/DD.jsonl].  These rows
    are intentionally kept out of the primary metrics stream so bursts of
    tool-event action counters cannot evict full context snapshots from
    fixed-tail dashboard/status readers. *)
val keeper_pr_action_metrics_store : Coord.config -> string -> Dated_jsonl.t

(** Date-split execution-receipt store:
    [.masc/keepers/<name>/execution-receipts/YYYY-MM/DD.jsonl]. *)
val keeper_execution_receipt_store : Coord.config -> string -> Dated_jsonl.t

val keeper_memory_bank_path : Coord.config -> string -> string
val keeper_progress_path : Coord.config -> string -> string
val keeper_generation_index_path : Coord.config -> string -> string

(** Per-trace session directory under [.masc/traces/<trace_id>]. *)
val keeper_session_dir : Coord.config -> string -> string

val keeper_generation_manifest_path : Coord.config -> string -> string
val keeper_history_path : Coord.config -> string -> string
val keeper_internal_history_path : Coord.config -> string -> string

(** Trim + lowercase a history-source label. *)
val normalize_history_source : string -> string

(** Whether [source] denotes the world-state prompt history channel. *)
val is_prompt_history_source : string -> bool

(** Whether [source] denotes a turn-internal (non-user-facing) history
    channel. *)
val is_internal_history_source : string -> bool

val keeper_policy_log_path : Coord.config -> string -> string
val keeper_decision_log_path : Coord.config -> string -> string
val keeper_feedback_log_path : Coord.config -> string -> string
val keeper_dataset_export_path : Coord.config -> string -> string
val keeper_alerts_path : Coord.config -> string
val keeper_alert_retry_path : Coord.config -> string
val keeper_alert_deadletter_path : Coord.config -> string

(** Rotate [path] if it exceeds the configured size threshold.
    Keeps at most [Env_config.KeeperMetrics.max_rotated_files] numbered
    backups (.1, .2, ...). *)
val maybe_rotate_file : string -> unit

(** Append [json] as a single UTF-8-repaired JSONL line to [path],
    rotating first if needed. *)
val append_jsonl_line : string -> Yojson.Safe.t -> unit
