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

let compaction_source_to_string = function
  | Pre_dispatch_hygiene -> "pre_dispatch_hygiene"
  | MASC_policy -> "masc_policy"
  | Memory_bank -> "memory_bank"
;;

let compaction_source_of_string_opt = function
  | "pre_dispatch_hygiene" -> Some Pre_dispatch_hygiene
  | "masc_policy" -> Some MASC_policy
  | "memory_bank" -> Some Memory_bank
  | _ -> None
;;

type compaction_error =
  | Read_error
  | Write_error of string
  | Schema_mismatch

let compaction_error_to_string = function
  | Read_error -> "read_error"
  | Write_error message -> "write_error: " ^ message
  | Schema_mismatch -> "schema_mismatch"
;;

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

let no_memory_bank_compaction =
  { performed = false
  ; source = None
  ; target_notes = 0
  ; before_notes = 0
  ; after_notes = 0
  ; dropped_notes = 0
  ; dedup_dropped = 0
  ; invalid_dropped = 0
  ; dropped_by_kind = []
  ; error = None
  }
;;

(** RFC-0327 §A1 — Outcome of a memory bank write operation.
    [Persisted] means the row was written as-is.
    [Merged_into target_id] means the row was similarity-matched (jaccard >= 0.85)
    to an existing row and merged into it instead of creating a duplicate. *)
type write_outcome =
  | Persisted
  | Merged_into of string
;;

let keeper_memory_schema_version = 2
let short_term_horizon = "short_term"
let mid_term_horizon = "mid_term"
let long_term_horizon = "long_term"

type memory_kind =
  | Goal
  | Progress
  | Decision
  | Open_question
  | Long_term

let memory_kind_to_wire = function
  | Goal -> "goal"
  | Progress -> "progress"
  | Decision -> "decision"
  | Open_question -> "open_question"
  | Long_term -> "long_term"
;;

let memory_kind_of_wire = function
  | "goal" -> Some Goal
  | "progress" -> Some Progress
  | "decision" -> Some Decision
  | "open_question" -> Some Open_question
  | "long_term" -> Some Long_term
  | _ -> None
;;

let all_memory_kinds = [ Decision; Goal; Progress; Open_question; Long_term ]

let memory_kind_is_writable = function
  | Long_term -> false
  | Goal | Progress | Decision | Open_question -> true
;;

let writable_memory_kinds = List.filter memory_kind_is_writable all_memory_kinds
let valid_memory_kind_strings = List.map memory_kind_to_wire all_memory_kinds
let writable_memory_kind_strings = List.map memory_kind_to_wire writable_memory_kinds

let memory_horizon_of_kind = function
  | Open_question | Progress -> short_term_horizon
  | Goal | Decision -> mid_term_horizon
  | Long_term -> long_term_horizon
;;

let memory_horizon_of_json_opt json =
  match
    Safe_ops.json_string ~default:"" "horizon" json
    |> String.trim
    |> String.lowercase_ascii
  with
  | "short_term" -> Some short_term_horizon
  | "mid_term" -> Some mid_term_horizon
  | "long_term" -> Some long_term_horizon
  | _ -> None
;;

let priority_for_kind ~kind =
  match kind with
  | Decision -> 86
  | Long_term -> 95
  | Open_question -> 76
  | Goal -> 72
  | Progress -> 66
;;

let tuned_priority_for_candidate ~kind ~text =
  ignore text;
  priority_for_kind ~kind |> max 1 |> min 100
;;

let total_cap () = 12

let kind_caps () =
  List.map
    (fun kind ->
       let cap =
         match kind with
         | Long_term -> 4
         | Goal | Progress | Decision | Open_question -> 2
       in
       kind, cap)
    all_memory_kinds
;;

let cap_for_kind caps kind =
  List.assoc_opt kind caps |> Option.value ~default:1
;;
