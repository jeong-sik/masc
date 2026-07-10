(** Keeper Memory Bank -- durable note storage, provenance, recall-row
    validation, and compaction. *)

(** {1 Re-exports from [Keeper_memory_policy]}

    Type equalities are preserved so policy and bank can share values
    without conversion.  See [Keeper_memory_policy] for full
    documentation; brief intent only here. *)

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
val short_term_horizon : string
val mid_term_horizon : string
val long_term_horizon : string

type memory_kind =
  Keeper_memory_policy.memory_kind =
  | Goal
  | Progress
  | Decision
  | Open_question
  | Long_term

val memory_kind_to_wire : memory_kind -> string
val memory_kind_of_wire : string -> memory_kind option
val all_memory_kinds : memory_kind list
val memory_kind_is_writable : memory_kind -> bool
val writable_memory_kinds : memory_kind list
val valid_memory_kind_strings : string list
val writable_memory_kind_strings : string list
val memory_horizon_of_kind : memory_kind -> string
val memory_horizon_of_json_opt : Yojson.Safe.t -> string option
val priority_for_kind : kind:memory_kind -> int
val tuned_priority_for_candidate : kind:memory_kind -> text:string -> int
val total_cap : unit -> int
val kind_caps : unit -> (memory_kind * int) list
val cap_for_kind : (memory_kind * int) list -> memory_kind -> int

(** {1 Bank-specific: dedup} *)

val dedup_by_key : ('a -> string) -> 'a list -> 'a list
(** Keep the first occurrence per key. *)

val jaccard_similarity : string -> string -> float
(** Token-set Jaccard similarity over normalised words; used as the
    semantic-dedup distance metric. *)

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

(** {1 Bank wire format} *)

type memory_row_source =
  | Progress_consolidation
  | Cross_trace_recurrence
  | Explicit_memory_write
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
  kind : memory_kind;
  horizon : string;
  source : memory_row_source;
  generation : int;
  text : string;
  priority : int;
  ts_unix : float;
}
(** Raw row from [memory_bank.jsonl] with both the original JSON and
    parsed columns kept side by side. *)

type memory_consolidation_summarizer =
  trace_id:string -> texts:string list -> string option
(** Optional semantic summarizer for progress-cluster consolidation.
    Returning [None], an empty string, or a non-meaningful memory string
    falls back to the deterministic summary. *)

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
  target_notes:int -> (memory_kind, int) Hashtbl.t
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

type explicit_memory_write_error =
  | Explicit_memory_kind_not_writable of memory_kind
  | Rejected_explicit_memory_text
  | Explicit_memory_write_failed of string

val append_explicit_memory_note :
  Workspace.config ->
  Keeper_meta_contract.keeper_meta ->
  turn:int ->
  kind:memory_kind ->
  text:string ->
  (unit, explicit_memory_write_error) result
(** Persist one note produced by the explicit memory tool. The result carries
    validation and persistence failures instead of silently dropping the note. *)

(** Promote explicitly tagged tool results into durable [long_term]
    memory-bank rows. Only results carrying the existing
    [Multimodal.Tool_emission] reserved kind/id tags are eligible. *)
val append_memory_notes_from_tool_results :
  Workspace.config ->
  Keeper_meta_contract.keeper_meta ->
  turn:int ->
  results:Yojson.Safe.t list ->
  (int, string) result
(** Idempotently promote tool-result artifacts. Existing [tool_result] rows are
    keyed by their typed [artifact_id], so replaying a durable post-turn job
    writes only artifacts that are not already in the bank. Read/write failures
    are explicit. *)

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
