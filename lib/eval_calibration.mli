(** Eval_calibration — Verdict logging and evaluator calibration loop.

    Persists anti-rationalization verdicts to date-partitioned JSONL
    ([data/verdicts/YYYY-MM/DD.jsonl]).  Supports human-label ground-truth
    tracking, divergence analysis, and few-shot calibration example
    generation.

    @since #3068 *)

(** {1 Types} *)

type record_type =
  | Verdict_record
  | Label_record

val record_type_to_string : record_type -> string
val record_type_of_string : string -> record_type option

type label_verdict =
  | Approve_label
  | Reject_label

val label_verdict_to_string : label_verdict -> string
val label_verdict_of_string : string -> label_verdict option

val verdict_to_string : Anti_rationalization.verdict -> string
val verdict_of_string : string -> Anti_rationalization.verdict option

type verdict_record = {
  record_type : record_type;
  notes_hash : string;
  task_id : string;
  task_title : string;
  agent_name : string;
  verdict : Anti_rationalization.verdict;
  gate : Anti_rationalization.gate;
  evaluator_cascade : string;
  generator_cascade : string option;
  fallback_reason : string option;
  timestamp : float;
}

type label_record = {
  record_type : record_type;
  notes_hash : string;
  human_verdict : label_verdict;
  labeler : string;
  reason : string;
  timestamp : float;
}

type divergence = {
  notes_hash : string;
  evaluator_verdict : Anti_rationalization.verdict;
  human_verdict : label_verdict;
  gate : string;
  task_title : string;
}

type calibration_example = {
  task_title : string;
  notes_excerpt : string;
  correct_verdict : string;
}

(** {1 Store management} *)

val get_store : unit -> Dated_jsonl.t
(** Get or create the global verdict store at [data/verdicts/]. *)

val reset_store_for_testing : unit -> unit
(** Reset the store reference.  For testing only. *)

val set_store_for_testing : base_dir:string -> unit
(** Set store to a custom directory.  For testing only. *)

(** {1 Hashing} *)

val notes_hash : task_title:string -> notes:string -> string
(** SHA256 hex digest of [(task_title ^ "\n" ^ notes)].
    Used to cross-reference verdict and label records. *)

(** {1 Recording} *)

val record_verdict :
  task_id:string ->
  req:Anti_rationalization.review_request ->
  result:Anti_rationalization.review_result ->
  ?on_harness_verdict:(Agent_sdk.Harness.verdict -> unit) ->
  unit ->
  unit
(** Append a verdict record to the JSONL store.
    If [~on_harness_verdict] is provided, converts the record to an OAS
    [Harness.verdict] and invokes the callback after persistence.
    This enables wiring to [Eval.add_verdict] or SSE event publishers. *)

val record_human_label :
  notes_hash:string ->
  human_verdict:label_verdict ->
  labeler:string ->
  reason:string ->
  unit
(** Append a human label for ground-truth tracking. *)

(** {1 Analysis} *)

val find_divergences :
  ?since:string -> ?until:string -> unit -> divergence list
(** Find cases where evaluator and human verdicts disagree.
    Date filters use ["YYYY-MM-DD"] format. *)

val select_examples : max_examples:int -> calibration_example list
(** Select few-shot calibration examples from recent divergences.
    Prioritizes false positives (evaluator approve + human reject). *)

val format_few_shot_block : calibration_example list -> string
(** Format examples into a text block for prompt injection.
    Returns [""] for an empty list. *)

(** {1 OAS Integration} *)

val to_harness_verdict : verdict_record -> Agent_sdk.Harness.verdict
(** Convert a MASC verdict record to an OAS [Harness.verdict].
    [Approve] maps to [passed=true, score=1.0];
    [Reject _] maps to [passed=false, score=0.0] with gate detail. *)

(** {1 Statistics} *)

val calibration_stats :
  ?since:string -> ?until:string -> unit -> Yojson.Safe.t
(** Compute summary statistics: verdict counts, gate distribution,
    false positive/negative rates, agreement rate. *)
