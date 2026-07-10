(** MASC-owned durable-memory facade. *)

type line =
  Keeper_memory_policy.keeper_memory_line =
  { kind : string
  ; text : string
  ; priority : int
  ; ts_unix : float
  }

type summary =
  Keeper_memory_policy.keeper_memory_summary =
  { total_notes : int
  ; last_ts_unix : float
  ; top_kind : string option
  ; kind_counts : (string * int) list
  ; recent_notes : line list
  }

type compaction_source =
  Keeper_memory_policy.compaction_source =
  | Pre_dispatch_hygiene
  | MASC_policy
  | Memory_bank

type compaction_error =
  Keeper_memory_policy.compaction_error =
  | Read_error
  | Write_error of string
  | Schema_mismatch

type compaction =
  Keeper_memory_policy.memory_bank_compaction =
  { performed : bool
  ; source : compaction_source option
  ; target_notes : int
  ; before_notes : int
  ; after_notes : int
  ; dropped_notes : int
  ; dedup_dropped : int
  ; invalid_dropped : int
  ; dropped_by_kind : (string * int) list
  ; error : compaction_error option
  }

type read_error = Keeper_memory_recall_exn_class.t
type consolidation_summarizer = Keeper_memory_bank.memory_consolidation_summarizer

type t =
  { bank_summary : summary
  ; last_compaction : compaction
  }

val empty_summary : summary
val empty : t

val make :
  ?bank_summary:summary ->
  ?last_compaction:compaction ->
  unit ->
  t

val bank_summary : t -> summary
val last_compaction : t -> compaction
val compaction_source_to_string : compaction_source -> string
val compaction_source_of_string_opt : string -> compaction_source option

val read_summary :
  config:Workspace.config ->
  name:string ->
  ?max_bytes:int ->
  ?max_lines:int ->
  ?recent_limit:int ->
  unit ->
  (summary, read_error) result

val read :
  config:Workspace.config ->
  name:string ->
  ?max_bytes:int ->
  ?max_lines:int ->
  ?recent_limit:int ->
  unit ->
  (t, read_error) result

val append_from_tool_results :
  Workspace.config ->
  Keeper_meta_contract.keeper_meta ->
  turn:int ->
  results:Yojson.Safe.t list ->
  int

val compact_if_needed :
  ?summarizer:consolidation_summarizer ->
  Workspace.config ->
  Keeper_meta_contract.keeper_meta ->
  compaction

val summary_to_json : summary -> Yojson.Safe.t
val compaction_to_json : compaction -> Yojson.Safe.t
val to_json : t -> Yojson.Safe.t
