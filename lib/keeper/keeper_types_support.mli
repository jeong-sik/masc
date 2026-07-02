(** Keeper_types_support — model selection, path utilities,
    and JSONL append/rotation helpers.

    Extracted from keeper_types.ml to reduce file size.
    Depends only on Keeper_config (no Keeper_types dependency). *)

include module type of Keeper_config

(** Resolve the keeper base directory ([.masc/keepers]) for [config],
    creating it if missing. *)
val keeper_dir_ : Workspace.config -> string

(** Resolve the trace base directory ([.masc/traces]) for [config],
    creating it if missing. *)
val session_base_dir_ : Workspace.config -> string

(** Check API key availability for the given model labels via
    [Runtime_runtime]. *)
val ensure_api_keys_for_labels : string list -> (unit, string) result

(** Single-file metrics path kept for fallback reads. *)
val keeper_metrics_path : Workspace.config -> string -> string

(** Date-split metrics store: [.masc/keepers/<name>/metrics/YYYY-MM/DD.jsonl].
    Cached per keeper name so all callers share the same Eio.Mutex. *)
val keeper_metrics_store : Workspace.config -> string -> Dated_jsonl.t

val execution_receipts_dirname : string
(** Runtime subdirectory under each keeper directory for date-split execution
    receipt JSONL. *)

val execution_receipt_schema : string
(** JSONL schema tag for execution receipt rows. *)

(** Date-split execution-receipt store:
    [.masc/keepers/<name>/execution-receipts/YYYY-MM/DD.jsonl]. *)
val keeper_execution_receipt_store : Workspace.config -> string -> Dated_jsonl.t

(** Date-split TurnRecord store (RFC-0233 §2.2):
    [.masc/keepers/<name>/turn-records/YYYY-MM/DD.jsonl]. *)
val keeper_turn_record_store : Workspace.config -> string -> Dated_jsonl.t

(** Per-keeper OAS raw-trace sink:
    [.masc/keepers/<name>/raw-trace.jsonl]. Appended across turns —
    [Agent_sdk.Raw_trace.create] resumes its seq counter from the existing
    file, so each turn's run is a seq range inside one file. *)
val keeper_raw_trace_path : Workspace.config -> string -> string

val keeper_memory_bank_path : Workspace.config -> string -> string
val keeper_progress_path : Workspace.config -> string -> string
val keeper_generation_index_path : Workspace.config -> string -> string

(** Per-trace session directory under [.masc/traces/<trace_id>]. *)
val keeper_session_dir : Workspace.config -> string -> string

val keeper_generation_manifest_path : Workspace.config -> string -> string
val keeper_history_path : Workspace.config -> string -> string
val keeper_internal_history_path : Workspace.config -> string -> string

(** Trim + lowercase a history-source label. *)
val normalize_history_source : string -> string

(** Whether [source] denotes the world-state prompt history channel. *)
val is_prompt_history_source : string -> bool

(** Whether [source] denotes a turn-internal (non-user-facing) history
    channel. *)
val is_internal_history_source : string -> bool

val keeper_policy_log_path : Workspace.config -> string -> string
val keeper_decision_log_path : Workspace.config -> string -> string
val keeper_feedback_log_path : Workspace.config -> string -> string
val keeper_dataset_export_path : Workspace.config -> string -> string
val keeper_alerts_path : Workspace.config -> string
val keeper_alert_retry_path : Workspace.config -> string
val keeper_alert_deadletter_path : Workspace.config -> string

(** Rotate [path] if it exceeds the configured size threshold.
    Keeps at most [Env_config.KeeperMetrics.max_rotated_files] numbered
    backups (.1, .2, ...). *)
val maybe_rotate_file : string -> unit

(** Append [json] as a single UTF-8-repaired JSONL line to [path],
    rotating first if needed. *)
val append_jsonl_line : string -> Yojson.Safe.t -> unit
