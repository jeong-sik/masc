(** Keeper Memory Policy — observation classification, alert scoring,
    [STATE] block parsing, and snapshot serialisation.

    Centralises the heuristics that turn LLM turn output into structured
    keeper memory: extracting the [STATE] block emitted by the persona
    template, scoring "interesting" workspace messages for alerting, capping
    snapshot fields to the prompt budget, and round-tripping snapshots
    through assistant messages so a fresh keeper generation can resume
    from disk. *)

(** {1 STATE block regexes}

    Compiled once and reused by parsers and serialisers; exposed for
    tests. *)

val state_start_re : Re.re
(** Opening fence of the [STATE]…[/STATE] block. *)

val state_end_re : Re.re
(** Closing fence of the [STATE]…[/STATE] block. *)

(** {1 Interesting-message alerting} *)

type alert_channel_result = {
  channel : string;
  attempted : bool;
  success : bool;
  attempts : int;
  detail : string option;
}
(** Per-channel delivery outcome for an interesting-message alert. *)

type interesting_alert_result = {
  enabled : bool;
  triggered : bool;
  score : float;
  threshold : float;
  reasons : string list;
  keywords : string list;
  alert_id : string option;
  channels : alert_channel_result list;
  retry_queued : bool;
  deadlettered : bool;
}
(** Aggregate result of a single alert evaluation: whether the policy
    fired, why, and what each delivery channel did. *)

val empty_interesting_alert_result : interesting_alert_result
(** [enabled=false] zero value used as a default. *)

val alert_channel_result_to_json : alert_channel_result -> Yojson.Safe.t
(** Wire encoding for dashboard / audit log. *)

(** {1 Keeper state snapshot} *)

type keeper_state_snapshot = {
  priority : int option;
  goal : string option;
  progress : string option;
  done_summary : string option;
  next_summary : string option;
  next_items : string list;
  decisions : string list;
  open_questions : string list;
  constraints : string list;
}
(** The structured continuity payload extracted from a turn's [STATE]
    block.  Carried across generations to bootstrap the next keeper. *)

val empty_keeper_state_snapshot : keeper_state_snapshot
(** All-empty snapshot used as a default when no [STATE] block was
    emitted. *)

(** Provenance of a turn's continuity snapshot (RFC-0242 §3.2, replacing the prior
    untyped string discriminant). [Structured_state_tool] is currently unreachable
    (the reporting tool was removed) and is retired by RFC-0242 §3.1. *)
type state_snapshot_source =
  | Structured_state_tool
  | Structured_state_reply
  | State_block
  | Synthesized

val state_snapshot_source_to_string : state_snapshot_source -> string
(** Wire rendering for the turn sidecar [source] field. Stable strings:
    [model_structured_state_tool] / [model_structured_state] / [model_state_block]
    / [synthesized]. *)

val state_snapshot_source_is_synthetic : state_snapshot_source -> bool
(** True only for [Synthesized]. Synthetic snapshots may remain in
    checkpoints/sidecars for resume, but must not be promoted as model-authored
    durable memory or active work. *)

type compaction_source =
  | Pre_dispatch_hygiene
  | MASC_policy
  | Memory_bank
(** Closed-sum variant distinguishing which subsystem initiated a
    compaction. Replaces the previous generic "compacted" string. *)

val compaction_source_to_string : compaction_source -> string
val compaction_source_of_string_opt : string -> compaction_source option

(** {1 Memory bank entry types} *)

type keeper_memory_line = {
  kind : string;
  text : string;
  priority : int;
  ts_unix : float;
}
(** One line in the keeper memory bank. *)

type keeper_memory_summary = {
  total_notes : int;
  last_ts_unix : float;
  top_kind : string option;
  kind_counts : (string * int) list;
  recent_notes : keeper_memory_line list;
}
(** Aggregated view of the memory bank for the dashboard. *)

type compaction_error =
  | Read_error
  | Write_error of string
  | Schema_mismatch
(** Typed compaction failure. [Read_error] covers unreadable files;
    [Write_error msg] propagates the atomic rewrite failure;
    [Schema_mismatch] reports rows with a non-current schema_version. *)

val compaction_error_to_string : compaction_error -> string
(** Human-readable error label for logging/metrics. *)

type memory_bank_compaction = {
  performed : bool;
  source : compaction_source option;
  target_notes : int;
  before_notes : int;
  after_notes : int;
  dropped_notes : int;
  dedup_dropped : int;
  invalid_dropped : int;
  dropped_by_kind : (string * int) list;
  error : compaction_error option;
}
(** Result of a memory-bank compaction pass. [error] is [Some _] when
    the pass detected a schema mismatch or failed to rewrite the bank. *)

val no_memory_bank_compaction : memory_bank_compaction
(** [performed=false] zero value when no compaction was attempted. *)

(** {1 Schema constants} *)

val keeper_memory_schema_version : int
(** Bump on snapshot wire-format changes. *)

val replay_metadata_key : string
(** Assistant-message metadata key carrying the snapshot replay blob. *)

val replay_metadata_kind : string
(** Kind tag distinguishing replay metadata from other metadata
    payloads. *)

val replay_metadata_version : int
(** Replay metadata schema version (independent of the snapshot
    schema). *)

(** {1 Memory horizon classification}

    Each memory kind maps to a horizon (short / mid / long) that
    governs which prompt section it appears in. *)

val short_term_horizon : string
val mid_term_horizon : string
val long_term_horizon : string

val memory_horizon_of_kind_opt : string -> string option
(** Horizon for [kind], or [None] when [kind] is unknown.  Use this in
    silent-default contexts. *)

val memory_horizon_of_json_opt : Yojson.Safe.t -> string option

(** {1 [STATE] block parsing} *)

(** [Some trimmed] when [text] is non-blank, else [None]. *)

val split_state_items : string -> string list
(** Split a comma- or bullet-delimited [STATE] item list. *)

val strip_prefix_ci : prefix:string -> string -> string option
(** Case-insensitive [String.starts_with]: returns the suffix when
    [prefix] matches, else [None]. *)

val find_state_block : string -> string option
(** Extract the body between [STATE]…[/STATE], or [None] when no block
    is present. *)

val state_snapshot_of_lines : string list -> keeper_state_snapshot option
(** Parse the body of a [STATE] block (one line per field). *)

val parse_state_snapshot_from_reply : string -> keeper_state_snapshot option
(** Convenience: locate the [STATE] block in a full assistant reply
    and parse it. *)

val structured_state_snapshot_schema :
  keeper_state_snapshot Agent_sdk.Structured.schema
(** Provider-native structured-output schema for keeper state snapshots. *)

val parse_structured_state_snapshot_from_reply :
  string -> keeper_state_snapshot option
(** Parse a full assistant reply that is itself structured JSON.  Accepts
    raw snapshot JSON, the versioned [state_snapshot] envelope, or replay
    metadata. *)

val state_snapshot_of_summary_text : string -> keeper_state_snapshot option
(** Re-parse the rendered summary text back into a snapshot.  Inverse
    of [keeper_state_snapshot_to_summary_text]. *)

val forward_looking_snapshot : keeper_state_snapshot -> keeper_state_snapshot
(** Drop fields that describe past work, keeping only the goal /
    next-summary / open-questions used in the next prompt. *)

val keeper_state_snapshot_to_summary_text : keeper_state_snapshot -> string
(** Render a snapshot as the canonical summary text. *)

(** {1 Capping}

    Snapshot fields are capped before they reach the prompt to prevent
    a runaway [STATE] block from blowing the context budget. *)

val default_max_string_chars : int
val default_max_list_items : int
val default_max_item_chars : int
val default_continuity_summary_max_chars : int

val cap_string : max_chars:int -> string option -> string option
(** Truncate to [max_chars]; [None] passes through. *)

val cap_list :
  max_items:int -> max_item_chars:int -> string list -> string list
(** Truncate the list to [max_items] and each entry to [max_item_chars]. *)

val cap_snapshot :
  ?max_string_chars:int ->
  ?max_list_items:int ->
  ?max_item_chars:int -> keeper_state_snapshot -> keeper_state_snapshot
(** Apply per-field caps using the [default_max_*] values when none
    are supplied. *)

val cap_continuity_summary_text : ?max_chars:int -> string -> string
(** Trim and truncate rendered [continuity_summary] text. This final
    shared cap is used by production and fallback consumption paths, so
    legacy oversized summaries cannot bypass {!cap_snapshot}. *)

(** {1 Prompt rendering} *)

val filter_forward_looking_summary : string -> string
(** Strip past-tense lines from a rendered summary text. *)

val progress_markdown_of_snapshot :
  ?generation:int -> ?updated_at:string -> keeper_state_snapshot -> string
(** Render the snapshot as the markdown blob persisted to
    [progress.md]. *)

val short_term_prompt_text_of_snapshot : keeper_state_snapshot -> string
(** Snapshot text for the short-term prompt section. *)

val mid_term_prompt_text_of_snapshot : keeper_state_snapshot -> string
(** Snapshot text for the mid-term prompt section. *)

(** {1 Progress snapshot cache} *)

type progress_snapshot_cache = {
  generation : int option;
  snapshot : keeper_state_snapshot;
}
(** Generation-tagged snapshot cached on disk. *)

val progress_generation_of_text : string -> int option
(** Extract the generation tag from a [progress.md] payload. *)

val progress_snapshot_cache_of_text :
  string -> progress_snapshot_cache option
(** Parse a [progress.md] payload into a cache record. *)

val prompt_memory_sections_of_snapshot :
  current_generation:int ->
  ?source_generation:int -> keeper_state_snapshot -> string list
(** Build the per-generation prompt memory sections (short / mid /
    long) from a snapshot, optionally tagging the source generation. *)

val read_progress_snapshot :
  config:Workspace.config -> name:string -> keeper_state_snapshot option
(** Read the persisted snapshot for [name] under [config]. *)

val read_progress_snapshot_cache :
  config:Workspace.config ->
  name:string -> progress_snapshot_cache option
(** Read the persisted snapshot together with its generation tag. *)

val write_progress_snapshot_path :
  path:string ->
  ?generation:int ->
  ?updated_at:string -> keeper_state_snapshot -> (unit, string) result
(** Atomically write a snapshot to [path]. *)

val continuity_fallback_summary_text :
  continuity_summary:string -> last_continuity_update_ts:float -> string
(** Render the fallback summary text used when no [STATE] block is
    available but a continuity summary is. *)

(** {1 Snapshot wire format} *)

val keeper_state_snapshot_to_json : keeper_state_snapshot -> Yojson.Safe.t
val keeper_state_snapshot_of_json :
  Yojson.Safe.t -> keeper_state_snapshot option

val structured_working_context_of_snapshot :
  keeper_state_snapshot -> Yojson.Safe.t
(** JSON shape consumed by the dashboard's working-context panel. *)

val replay_metadata_of_snapshot : keeper_state_snapshot -> Yojson.Safe.t
(** JSON metadata blob attached to assistant messages so a fresh
    keeper can hydrate the snapshot from message history. *)

val snapshot_of_replay_metadata :
  Yojson.Safe.t -> keeper_state_snapshot option
(** Inverse of [replay_metadata_of_snapshot]. *)

val with_snapshot_metadata :
  Agent_sdk.Types.message ->
  keeper_state_snapshot -> Agent_sdk.Types.message
(** Attach replay metadata to an assistant message. *)

val snapshot_of_message_metadata :
  Agent_sdk.Types.message -> keeper_state_snapshot option
(** Hydrate a snapshot from a message's metadata, if present. *)

val snapshot_of_message :
  Agent_sdk.Types.message -> keeper_state_snapshot option
(** [snapshot_of_message_metadata] then fallback to parsing the
    message body's [STATE] block. *)

val snapshot_of_structured_working_context :
  Yojson.Safe.t -> keeper_state_snapshot option

val latest_state_snapshot_from_messages :
  Agent_sdk.Types.message list -> keeper_state_snapshot option
(** Latest snapshot reachable from the message history. *)

(** {1 Priority / scoring} *)

val priority_for_kind : kind:string -> int
(** Static priority floor for [kind]. *)

val contains_any_ci : string -> string list -> bool
(** [true] when [text] contains any of [needles] (case-insensitive). *)

val signal_bonus : text:string -> int
(** Bonus added to a memory line's priority when [text] hits known
    high-signal keywords. *)

val tuned_priority_for_candidate : kind:string -> text:string -> int
(** [priority_for_kind] plus [signal_bonus]. *)

(** {1 Capacity caps} *)

val total_cap : unit -> int
(** Total memory-bank line cap (env-overridable). *)

val kind_caps : unit -> (string * int) list
(** Per-kind cap list. *)

val valid_memory_kind_strings : string list
(** Closed enumeration of accepted memory kind strings. *)

val cap_for_kind : (string * int) list -> string -> int
(** Lookup [kind] in [kind_caps], falling back to a structurally
    impossible value when the kind is unknown so callers can detect
    the mistake. *)

(** {1 Run-result synthesis} *)

val synthesize_state_from_run_result :
  goal:string ->
  tools_used:string list ->
  stop_reason:string -> response_text:string -> keeper_state_snapshot
(** Build a snapshot from a turn's run result when the assistant did
    not emit a [STATE] block. *)

val render_state_block : keeper_state_snapshot -> string
(** Render the canonical [STATE]…[/STATE] block from a snapshot. *)
