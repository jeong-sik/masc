(** Eval_calibration — Verdict logging and evaluator calibration loop.

    Persists anti-rationalization verdicts to date-partitioned JSONL
    ([.masc/verdicts/YYYY-MM/DD.jsonl]).  Supports human-label ground-truth
    tracking, divergence analysis, and few-shot calibration example
    generation.

    @since #3068 *)

(** {1 Types} *)

type record_type =
  | Verdict_record
  | Label_record

type label_verdict =
  | Approve_label
  | Reject_label

val label_verdict_to_string : label_verdict -> string
val verdict_to_string : Task.Anti_rationalization.verdict -> string
val verdict_of_string : string -> Task.Anti_rationalization.verdict option

type verdict_record = {
  record_type : record_type;
  notes_hash : string;
  task_id : string;
  task_title : string;
  agent_name : string;
  verdict : Task.Anti_rationalization.verdict;
  gate : Task.Anti_rationalization.gate;
  evaluator_runtime : string;
  generator_runtime : string option;
  producer_execution : Runtime_response_identity.t option;
  evaluator_execution : Runtime_response_identity.t option;
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
  evaluator_verdict : Task.Anti_rationalization.verdict;
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
(** Get or create the global verdict store at [.masc/verdicts/]. *)

module For_testing : sig
  val reset_store : unit -> unit
  val set_store : base_path:string -> unit
end

(** {1 Hashing} *)

val notes_hash : task_title:string -> notes:string -> string
(** SHA256 hex digest of [(task_title ^ "\n" ^ notes)].
    Used to cross-reference verdict and label records. *)

(** {1 Recording} *)

val record_verdict :
  ?producer_execution:Runtime_response_identity.t ->
  task_id:string ->
  req:Task.Anti_rationalization.review_request ->
  result:Task.Anti_rationalization.review_result ->
  unit ->
  unit
(** Append a verdict record to the JSONL store. A result without a verdict is
    a no-op: nobody judged, so there is nothing to remember.
    [producer_execution] identifies the submitting tool response only, not
    every earlier model or collaborator that authored the artifact. *)

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

(** {1 AGENT_CORE Integration} *)

(** {1 Statistics} *)

val calibration_stats :
  ?since:string -> ?until:string -> unit -> Yojson.Safe.t
(** Compute summary statistics: verdict counts, gate distribution,
    false positive/negative rates, agreement rate. [distinct_runtime_rate]
    compares recorded runtime identifiers and is [null] when no pair was
    recorded. [model_identity_observation] separately compares the captured
    submitting-response/verdict-response provider and reported-model
    identities, retaining observed
    and unobserved coverage and causes. Its rate is [null] without a complete
    pair. Submission identity does not identify every model or collaborator
    that authored an artifact; identity diversity does not establish weight
    differences or statistical independence. *)
