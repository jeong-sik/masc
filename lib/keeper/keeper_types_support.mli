(** Keeper_types_support — model selection, path utilities,
    and JSONL append/rotation helpers.

    Extracted from keeper_types.ml to reduce file size.
    Depends only on Keeper_config (no Keeper_types dependency). *)

include module type of Keeper_config

(** Resolve the trace base directory ([.masc/traces]) for [config],
    creating it if missing. *)
val session_base_dir_ : Workspace.config -> string

(** Date-split metrics store: [.masc/keepers/<name>/metrics/YYYY-MM/DD.jsonl].
    Cached per keeper name so all callers share the same Eio.Mutex. *)
val keeper_metrics_store : Workspace.config -> string -> Dated_jsonl.t

(** Canonical base directory of {!keeper_metrics_store}. *)
val keeper_metrics_dir : Workspace.config -> string -> string

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

(** Date-split exact provider-input snapshot store:
    [.masc/keepers/<name>/provider-inputs/YYYY-MM/DD.jsonl]. Each row joins to
    one TurnRecord through [turn_ref] and owns content-addressed references to
    the system prompt, transmitted messages, and tool schemas. *)
val keeper_provider_input_store : Workspace.config -> string -> Dated_jsonl.t

(** Per-keeper AGENT_CORE raw-trace store directory:
    [.masc/keepers/<name>/raw-traces/]. One JSONL file per keeper turn —
    a fresh file per turn keeps [Agent_core.Raw_trace.create] from scanning
    previous turns' data, so a corrupt or oversized historical trace can
    never block keeper dispatch. Path derivation only; no filesystem
    effects. *)
val keeper_raw_trace_dir : Workspace.config -> string -> string

(** File extension of a per-turn raw-trace file, including the dot. The
    retention scan and {!Keeper_autonomous_turn_source}'s read
    both select directory entries by this suffix. *)
val raw_trace_file_extension : string

(** Fresh per-turn raw-trace file path under {!keeper_raw_trace_dir}.
    Ensures the directory exists (keeper dir included) and returns a path
    that does not collide with any previous turn's file, so the AGENT_CORE sink
    starts from an empty file. Raises when the directory cannot be
    created — callers on the dispatch path must degrade, not fail the
    turn (see [Keeper_agent_run.raw_trace_sink_outcome]). *)
val keeper_raw_trace_turn_path : Workspace.config -> string -> string

(** Per-trace session directory under [.masc/traces/<trace_id>]. *)
val keeper_session_dir : Workspace.config -> string -> string

val keeper_history_path : Workspace.config -> string -> string
val keeper_internal_history_path : Workspace.config -> string -> string

(** Trim + lowercase a history-source label. *)
val normalize_history_source : string -> string

(** Whether [source] denotes the world-state prompt history channel. *)
val is_prompt_history_source : string -> bool

(** Whether [source] denotes a turn-internal (non-user-facing) history
    channel. *)
val is_internal_history_source : string -> bool

val keeper_decision_log_path : Workspace.config -> string -> string
val keeper_feedback_log_path : Workspace.config -> string -> string

(** Rotate [path] if it exceeds the configured size threshold.
    Keeps at most [Env_config.KeeperMetrics.max_rotated_files] numbered
    backups (.1, .2, ...). *)
val maybe_rotate_file : string -> unit

(** Append [json] as a single UTF-8-repaired JSONL line to [path],
    rotating first if needed. *)
val append_jsonl_line : string -> Yojson.Safe.t -> unit
