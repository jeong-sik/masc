(** Keeper memory policy -- alert outcomes, durable-memory classification,
    compaction outcomes, and memory-bank capacity policy. *)

type keeper_memory_line =
  { kind : string
  ; text : string
  ; priority : int
  ; ts_unix : float
  }

type keeper_memory_summary =
  { total_notes : int
  ; last_ts_unix : float
  ; top_kind : string option
  ; kind_counts : (string * int) list
  ; recent_notes : keeper_memory_line list
  }

type compaction_source =
  | Pre_dispatch_hygiene
  | MASC_policy
  | Memory_bank

val compaction_source_to_string : compaction_source -> string
val compaction_source_of_string_opt : string -> compaction_source option

type compaction_error =
  | Read_error
  | Write_error of string
  | Schema_mismatch

val compaction_error_to_string : compaction_error -> string

type memory_bank_compaction =
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

val no_memory_bank_compaction : memory_bank_compaction
val keeper_memory_schema_version : int
val short_term_horizon : string
val mid_term_horizon : string
val long_term_horizon : string

type memory_kind =
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
