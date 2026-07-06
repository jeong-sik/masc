(** Keeper Memory Bank — durable note storage and compaction over the
    [STATE]-derived snapshots produced by [Keeper_memory_policy].

    Re-exports the policy types so callers can stay against this module
    alone, then adds bank-specific selection (per-kind cap + total cap),
    semantic dedup (Jaccard over normalised text), parse/write of the
    [memory_bank.jsonl] row schema, and the compaction pass that runs
    when the file crosses the size trigger. *)

(** {1 Re-exports from [Keeper_memory_policy]}

    Type equalities are preserved so policy and bank can share values
    without conversion.  See [Keeper_memory_policy] for full
    documentation; brief intent only here. *)

val state_start_re : Re.re
val state_end_re : Re.re

type keeper_state_snapshot =
  Keeper_memory_policy.keeper_state_snapshot = {
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
(** @see [Keeper_memory_policy.keeper_state_snapshot] *)

val empty_keeper_state_snapshot : keeper_state_snapshot

type keeper_memory_line =
  Keeper_memory_policy.keeper_memory_line = {
  kind : string;
  text : string;
  priority : int;
  ts_unix : float;
}
(** @see [Keeper_memory_policy.keeper_memory_line] *)

type keeper_memory_summary =
  Keeper_memory_policy.keeper_memory_summary = {
  total_notes : int;
  last_ts_unix : float;
  top_kind : string option;
  kind_counts : (string * int) list;
  recent_notes : keeper_memory_line list;
}
(** @see [Keeper_memory_policy.keeper_memory_summary] *)

type compaction_error = Keeper_memory_policy.compaction_error =
  | Read_error
  | Write_error of string
  | Schema_mismatch
(** @see [Keeper_memory_policy.compaction_error] *)

type memory_bank_compaction =
  Keeper_memory_policy.memory_bank_compaction = {
  performed : bool;
  source : Keeper_memory_policy.compaction_source option;
  target_notes : int;
  before_notes : int;
  after_notes : int;
  dropped_notes : int;
  dedup_dropped : int;
  invalid_dropped : int;
  dropped_by_kind : (string * int) list;
  error : compaction_error option;
}
(** @see [Keeper_memory_policy.memory_bank_compaction] *)

val no_memory_bank_compaction : memory_bank_compaction
val keeper_memory_schema_version : int
val replay_metadata_key : string
val replay_metadata_kind : string
val replay_metadata_version : int
val short_term_horizon : string
val mid_term_horizon : string
val long_term_horizon : string
val memory_horizon_of_kind_opt : string -> string option
val memory_horizon_of_json_opt : Yojson.Safe.t -> string option
val split_state_items : string -> string list
val strip_prefix_ci : prefix:string -> string -> string option
val find_state_block : string -> string option
val state_snapshot_of_lines : string list -> keeper_state_snapshot option
val parse_state_snapshot_from_reply : string -> keeper_state_snapshot option
val state_snapshot_of_summary_text : string -> keeper_state_snapshot option
val forward_looking_snapshot : keeper_state_snapshot -> keeper_state_snapshot
val keeper_state_snapshot_to_summary_text : keeper_state_snapshot -> string
val default_max_string_chars : int
val default_max_list_items : int
val default_max_item_chars : int
val cap_string : max_chars:int -> string option -> string option
val cap_list :
  max_items:int -> max_item_chars:int -> string list -> string list
val cap_snapshot :
  ?max_string_chars:int ->
  ?max_list_items:int ->
  ?max_item_chars:int -> keeper_state_snapshot -> keeper_state_snapshot
val filter_forward_looking_summary : string -> string
val progress_markdown_of_snapshot :
  ?generation:int -> ?updated_at:string -> keeper_state_snapshot -> string
val short_term_prompt_text_of_snapshot : keeper_state_snapshot -> string
val mid_term_prompt_text_of_snapshot : keeper_state_snapshot -> string

type progress_snapshot_cache =
  Keeper_memory_policy.progress_snapshot_cache = {
  generation : int option;
  snapshot : keeper_state_snapshot;
}
(** @see [Keeper_memory_policy.progress_snapshot_cache] *)

val progress_generation_of_text : string -> int option
val progress_snapshot_cache_of_text :
  string -> progress_snapshot_cache option
val prompt_memory_sections_of_snapshot :
  current_generation:int ->
  ?source_generation:int -> keeper_state_snapshot -> string list
val read_progress_snapshot :
  config:Workspace.config -> name:string -> keeper_state_snapshot option
val read_progress_snapshot_cache :
  config:Workspace.config ->
  name:string -> progress_snapshot_cache option
val write_progress_snapshot_path :
  path:string ->
  ?generation:int ->
  ?updated_at:string -> keeper_state_snapshot -> (unit, string) result
val continuity_fallback_summary_text :
  continuity_summary:string -> last_continuity_update_ts:float -> string
val keeper_state_snapshot_to_json : keeper_state_snapshot -> Yojson.Safe.t
val keeper_state_snapshot_of_json :
  Yojson.Safe.t -> keeper_state_snapshot option
val structured_working_context_of_snapshot :
  keeper_state_snapshot -> Yojson.Safe.t
val replay_metadata_of_snapshot : keeper_state_snapshot -> Yojson.Safe.t
val snapshot_of_replay_metadata :
  Yojson.Safe.t -> keeper_state_snapshot option
val with_snapshot_metadata :
  Agent_sdk.Types.message ->
  keeper_state_snapshot -> Agent_sdk.Types.message
val snapshot_of_message_metadata :
  Agent_sdk.Types.message -> keeper_state_snapshot option
val snapshot_of_message :
  Agent_sdk.Types.message -> keeper_state_snapshot option
val snapshot_of_structured_working_context :
  Yojson.Safe.t -> keeper_state_snapshot option
val latest_state_snapshot_from_messages :
  Agent_sdk.Types.message list -> keeper_state_snapshot option
val priority_for_kind : kind:string -> int
val tuned_priority_for_candidate : kind:string -> text:string -> int
val total_cap : unit -> int
val kind_caps : unit -> (string * int) list
val valid_memory_kind_strings : string list
val cap_for_kind : (string * int) list -> string -> int
val synthesize_state_from_run_result :
  goal:string ->
  tools_used:string list ->
  stop_reason:string -> response_text:string -> keeper_state_snapshot

(** {1 Bank-specific: candidate selection} *)

type candidate_selection_result = {
  selected : (string * string * int) list;
      (** [(kind, text, priority)] entries kept after caps. *)
  dropped_by_kind : (string * int) list;
      (** Drops attributed to per-kind caps, by kind. *)
  dropped_by_total_cap : int;
      (** Drops attributed to the global [total_cap]. *)
  suppressed_synthetic_candidates : int;
      (** Otherwise valid candidates intentionally suppressed because the
          snapshot was synthetic rather than model-authored. *)
}
(** Outcome of [select_memory_candidates]. *)

val select_memory_candidates :
  (string * string * int) list -> candidate_selection_result
(** Apply per-kind caps and the total cap to a candidate list,
    preferring higher priority within each kind. *)

(** {1 Bank-specific: dedup} *)

val dedup_by_key : ('a -> string) -> 'a list -> 'a list
(** Keep the first occurrence per key. *)

val jaccard_similarity : string -> string -> float
(** Token-set Jaccard similarity over normalised words; used as the
    semantic-dedup distance metric. *)

val semantic_dedup_similarity_threshold : unit -> float
(** Threshold above which two notes are considered duplicates
    (env-overridable). *)

val dedup_memory_candidates :
  (string * string * int) list -> (string * string * int) list
(** Apply [jaccard_similarity] dedup on top of exact-key dedup. *)

(** {1 Bank-specific: text normalisation} *)

val normalize_punct_re : Re.re
(** Match-all-punctuation regex used by [normalize_memory_text_key]. *)

val normalize_memory_text_key : string -> string
(** Normalise text for the memory dedup key (lowercase + collapse
    punctuation/whitespace). *)

(** {1 Inflated-consensus filter}

    Filter out memory rows that are obvious chain-of-thought / "I have
    decided that…" boilerplate so the bank captures actual decisions. *)

val consensus_default_re : Re.re
val consensus_re_mu : Stdlib.Mutex.t
val consensus_re_cached : (string * Re.re) option ref
val consensus_pattern_key : unit -> string
val compile_consensus_re : string -> Re.re
val consensus_re : unit -> Re.re
val has_inflated_consensus_marker : string -> bool

val memory_placeholders : unit -> string list
(** Strings used as placeholders by the persona templates that should
    never be persisted. *)

val max_memory_text_length : unit -> int
(** Upper bound on memory note text length. *)

val is_meaningful_memory_text : string -> bool
(** Reject empty / placeholder / over-long candidates before they
    enter the bank. *)

val memory_candidates_from_snapshot :
  keeper_state_snapshot -> candidate_selection_result
(** Lift snapshot fields into candidate triples and run the cap +
    selection pipeline. *)

val memory_candidates_from_snapshot_gated :
  is_synthetic:bool ->
  keeper_state_snapshot ->
  candidate_selection_result
  (** Gated variant used by post-turn persistence. When [is_synthetic] (the
      snapshot was fabricated from run metadata, not model-authored), no durable
      memory candidates are produced — synthetic snapshots are resume aids only.
      [suppressed_synthetic_candidates] records how many otherwise valid
      candidates were intentionally suppressed by this gate. *)

(** {1 Bank wire format} *)

type memory_row_source =
  | Progress_consolidation
  | Cross_trace_recurrence
  | Tool_result
  | Voice_output
  | Other of string
      (** Provenance of a memory-bank row. Parsed from the JSONL [source]
          string on read; [Other] carries an out-of-band producer's literal so
          the wire value round-trips (parse-don't-validate). *)

val memory_row_source_of_string : string -> memory_row_source
(** Total parse of a persisted [source] string. Unknown values become
    [Other s]; never raises. *)

val memory_row_source_to_string : memory_row_source -> string
(** Inverse of {!memory_row_source_of_string} for the wire format.
    [to_string (of_string s) = s] for every [s]. *)

type keeper_memory_row_raw = {
  json : Yojson.Safe.t;
  kind : string;
  horizon : string;
  source : memory_row_source;
  generation : int;
  text : string;
  priority : int;
  ts_unix : float;
}
(** Raw row from [memory_bank.jsonl] with both the original JSON and
    parsed columns kept side by side. *)

type memory_bank_row_parse_error =
  | Malformed_json of string
  | Non_object_json of string
  | Schema_version_mismatch of { expected : int; actual : int option }
  | Unknown_kind of string
  | Missing_horizon
  | Horizon_mismatch of { kind : string; expected : string; actual : string }
  | Missing_source
  | Missing_trace_id
  | Empty_text
  | Non_meaningful_text
(** Typed reason why a persisted [memory_bank.jsonl] row could not be used. *)

type memory_consolidation_summarizer =
  trace_id:string -> texts:string list -> string option
(** Optional semantic summarizer for progress-cluster consolidation.
    Returning [None], an empty string, or a non-meaningful memory string
    falls back to the deterministic summary. *)

val memory_bank_row_parse_error_to_json :
  source:string ->
  ?keeper:string ->
  ?path:string ->
  line_index:int ->
  memory_bank_row_parse_error ->
  Yojson.Safe.t
(** Render a row parse error for dashboard/operator read-error surfaces. *)

val parse_memory_bank_row_result :
  string -> (keeper_memory_row_raw, memory_bank_row_parse_error) result
(** Parse a single JSONL line and preserve the typed rejection reason. *)

val parse_memory_bank_row : string -> keeper_memory_row_raw option
(** Parse a single JSONL line; [None] when the row is malformed,
    non-current schema, or missing canonical horizon/provenance fields. *)

val row_trace_id : keeper_memory_row_raw -> string
(** Stable identifier used by trace / dedup paths. *)

val memory_llm_summary_enabled : unit -> bool
(** Whether opt-in LLM-backed memory consolidation is enabled by
    [MASC_KEEPER_MEMORY_LLM_SUMMARY]. Defaults to [false]. *)

val consolidate_memory_notes :
  ?summarizer:memory_consolidation_summarizer ->
  keeper_memory_row_raw list ->
  keeper_memory_row_raw list * int
(** Merge near-duplicate rows and return [(consolidated, dropped_count)]. *)

(** {1 Compaction} *)

val memory_compaction_target_notes : unit -> int
(** Target row count after compaction. *)

val memory_compaction_trigger_bytes : target_notes:int -> int
(** File size that triggers a compaction pass for the given target. *)

val memory_kind_caps_for_compaction :
  target_notes:int -> (string, int) Hashtbl.t
(** Per-kind caps used inside the compaction pass; tighter than
    [kind_caps] because compaction is a recovery action. *)

val memory_row_key : keeper_memory_row_raw -> string
(** Dedup key for compaction passes. *)

val compaction_priority :
  current_generation:int -> keeper_memory_row_raw -> int
(** Per-row priority during compaction; older / lower-priority /
    out-of-generation rows are evicted first. *)

val write_memory_bank_rows :
  string -> keeper_memory_row_raw list -> (unit, string) result
(** Atomically replace the bank file with [rows]. *)

val compact_memory_bank_if_needed :
  ?summarizer:memory_consolidation_summarizer ->
  Workspace.config ->
  Keeper_meta_contract.keeper_meta -> memory_bank_compaction
(** Run a compaction pass for the keeper if the file has crossed the
    byte trigger or note-count target; returns
    [no_memory_bank_compaction] when nothing happened. *)

(** {1 Append-from-reply} *)

val append_memory_notes_from_reply :
  Workspace.config ->
  Keeper_meta_contract.keeper_meta ->
  ?snapshot:keeper_state_snapshot ->
  ?state_snapshot_source:Keeper_memory_policy.state_snapshot_source ->
  turn:int -> reply:string -> unit -> int * string list
(** Persist new memory rows derived from a turn's [reply] (and
    optional [snapshot]); returns [(rows_written, drop_reasons)]. *)

val append_memory_notes_from_reply_result :
  Workspace.config ->
  Keeper_meta_contract.keeper_meta ->
  ?snapshot:keeper_state_snapshot ->
  ?state_snapshot_source:Keeper_memory_policy.state_snapshot_source ->
  turn:int ->
  reply:string ->
  unit ->
  (int * string list, string) result
(** Result-returning variant of {!append_memory_notes_from_reply}. Persistence
    failures are returned as [Error]; cancellation and non-IO invariant failures
    are not converted. *)

(** Promote explicitly tagged tool results into durable [long_term]
    memory-bank rows. Only results carrying the existing
    [Multimodal.Tool_emission] reserved kind/id tags are eligible. *)
val append_memory_notes_from_tool_results :
  Workspace.config ->
  Keeper_meta_contract.keeper_meta ->
  turn:int ->
  results:Yojson.Safe.t list ->
  int

val append_memory_notes_from_tool_results_result :
  Workspace.config ->
  Keeper_meta_contract.keeper_meta ->
  turn:int ->
  results:Yojson.Safe.t list ->
  (int, string) result
(** Result-returning variant of {!append_memory_notes_from_tool_results}. *)

val append_voice_output :
  Workspace.config ->
  Keeper_meta_contract.keeper_meta ->
  ?provider:string ->
  execution:string ->
  voice_priority:int ->
  turn:int ->
  message:string ->
  unit ->
  (int, string) result
(** Persist a keeper voice output event as a short-term progress memory row.
    Returns [Ok 1] when a row is written, [Ok 0] when the message is empty or
    filtered as non-meaningful, and [Error _] on persistence failure. *)

(** {1 Summary} *)

val summarize_memory_bank_lines :
  string list -> recent_limit:int -> keeper_memory_summary
(** Build a [keeper_memory_summary] from raw JSONL lines. *)

val memory_summary_to_json : keeper_memory_summary -> Yojson.Safe.t
(** Wire encoding for the dashboard memory panel. *)
