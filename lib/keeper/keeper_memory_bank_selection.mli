val state_start_re : Re.re
val state_end_re : Re.re
type alert_channel_result =
  Keeper_memory_policy.alert_channel_result = {
  channel : string;
  attempted : bool;
  success : bool;
  attempts : int;
  detail : string option;
}
type interesting_alert_result =
  Keeper_memory_policy.interesting_alert_result = {
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
val empty_interesting_alert_result : interesting_alert_result
val alert_channel_result_to_json : alert_channel_result -> Yojson.Safe.t
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
val empty_keeper_state_snapshot : keeper_state_snapshot
type compaction_source =
  Keeper_memory_policy.compaction_source =
    Pre_dispatch_hygiene
  | MASC_policy
  | Memory_bank
val compaction_source_to_string : compaction_source -> string
val compaction_source_of_string_opt : string -> compaction_source option
type keeper_memory_line =
  Keeper_memory_policy.keeper_memory_line = {
  kind : string;
  text : string;
  priority : int;
  ts_unix : float;
}
type keeper_memory_summary =
  Keeper_memory_policy.keeper_memory_summary = {
  total_notes : int;
  last_ts_unix : float;
  top_kind : string option;
  kind_counts : (string * int) list;
  recent_notes : keeper_memory_line list;
}
type compaction_error = Keeper_memory_policy.compaction_error =
  | Read_error
  | Write_error of string
  | Schema_mismatch

type memory_bank_compaction =
  Keeper_memory_policy.memory_bank_compaction = {
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
val default_continuity_summary_max_chars : int
val cap_string : max_chars:int -> string option -> string option
val cap_list :
  max_items:int -> max_item_chars:int -> string list -> string list
val cap_snapshot :
  ?max_string_chars:int ->
  ?max_list_items:int ->
  ?max_item_chars:int -> keeper_state_snapshot -> keeper_state_snapshot
val cap_continuity_summary_text : ?max_chars:int -> string -> string
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
  Agent_sdk.Types.message -> keeper_state_snapshot -> Agent_sdk.Types.message
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
val with_stdlib_mutex : Mutex.t -> (unit -> 'a) -> 'a
val memory_bank_locks_mu : Mutex.t
val memory_bank_locks : (string, Mutex.t) Hashtbl.t
val memory_bank_lock_for : string -> Mutex.t
val with_memory_bank_lock : string -> (unit -> 'a) -> 'a
type candidate_selection_result = {
  selected : (string * string * int) list;
  dropped_by_kind : (string * int) list;
  dropped_by_total_cap : int;
  suppressed_synthetic_candidates : int;
}
val select_memory_candidates :
  (string * string * int) list -> candidate_selection_result
val dedup_by_key : ('a -> string) -> 'a list -> 'a list
val jaccard_similarity : string -> string -> float
val semantic_dedup_similarity_threshold : unit -> float
val dedup_memory_candidates :
  (string * string * int) list -> (string * string * int) list
val normalize_punct_re : Re.re
val normalize_memory_text_key : string -> string
val consensus_default_re : Re.re
val consensus_re_mu : Mutex.t
val consensus_re_cached : (string * Re.re) option ref
val memory_env_opt : string -> string option
val memory_env_int_logged : string -> default:int -> int
val memory_env_bool_logged : string -> default:bool -> bool
val memory_llm_summary_enabled : unit -> bool
val consensus_pattern_key : unit -> string
val compile_consensus_re : string -> Re.re
val consensus_re : unit -> Re.re
val has_inflated_consensus_marker : string -> bool
val memory_placeholders : unit -> string list
val max_memory_text_length : unit -> int
val is_meaningful_memory_text : string -> bool
val memory_candidates_from_snapshot :
  keeper_state_snapshot -> candidate_selection_result

val memory_candidates_from_snapshot_gated :
  is_synthetic:bool ->
  keeper_state_snapshot ->
  candidate_selection_result
  (** Gated variant used by post-turn persistence. When [is_synthetic] (the
      snapshot was fabricated from run metadata, not model-authored), no durable
      memory candidates are produced — synthetic snapshots are resume aids only.
      [suppressed_synthetic_candidates] records how many otherwise valid
      candidates were intentionally suppressed by this gate. *)
