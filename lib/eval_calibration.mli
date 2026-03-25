(** Eval_calibration — Verdict logging and evaluator calibration loop.

    Persists anti-rationalization verdicts to date-partitioned JSONL
    ([data/verdicts/YYYY-MM/DD.jsonl]).  Supports human-label ground-truth
    tracking, divergence analysis, and few-shot calibration example
    generation.

    @since #3068 *)

(** {1 Types} *)

type verdict_record = {
  record_type : string;
  notes_hash : string;
  task_id : string;
  task_title : string;
  agent_name : string;
  verdict : string;
  gate : string;
  evaluator_cascade : string;
  generator_cascade : string option;
  timestamp : float;
}

type label_record = {
  record_type : string;
  notes_hash : string;
  human_verdict : string;
  labeler : string;
  reason : string;
  timestamp : float;
}

type divergence = {
  notes_hash : string;
  evaluator_verdict : string;
  human_verdict : string;
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
  unit
(** Append a verdict record to the JSONL store. *)

val record_human_label :
  notes_hash:string ->
  human_verdict:string ->
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

val calibration_stats :
  ?since:string -> ?until:string -> unit -> Yojson.Safe.t
(** Compute summary statistics: verdict counts, gate distribution,
    false positive/negative rates, agreement rate. *)
