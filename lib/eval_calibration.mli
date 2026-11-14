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
  gate : Task.Anti_rationalization.gate;
  task_title : string;
}

(** One row of the store, as one of its two writers wrote it. *)
type stored_record =
  | Verdict of verdict_record
  | Label of label_record

(** The newest rows of the store, oldest first. [unreadable_rows] counts the
    rows of the window {!stored_record_of_json} refused; they are in neither
    list. *)
type window = {
  verdicts : verdict_record list;
  labels : label_record list;
  unreadable_rows : int;
}

type divergence_scan = {
  divergences : divergence list;
  unreadable_rows : int;  (** As in {!window}. *)
}

type calibration_example = {
  task_title : string;
  notes_excerpt : string;
  correct_verdict : string;
}

(** {1 Store management} *)

val store : base_path:string -> Dated_jsonl.t
(** The verdict store of the workspace at [base_path]
    ([.masc/verdicts/]). Every reader and writer below takes the workspace
    it works on, so verdicts and labels of two workspaces never mix. *)

(** {1 Hashing} *)

val notes_hash : task_title:string -> notes:string -> string
(** SHA256 hex digest of [(task_title ^ "\n" ^ notes)].
    Used to cross-reference verdict and label records. *)

(** {1 Recording} *)

val install_written_observer : (base_path:string -> unit) -> unit
(** Install the process-wide observer {!record_verdict} and
    {!record_human_label} call after they append a record (RFC-0480 §3.4).
    An append that raises calls nothing. The observer must not raise. *)

val record_verdict :
  ?producer_execution:Runtime_response_identity.t ->
  base_path:string ->
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
  base_path:string ->
  notes_hash:string ->
  human_verdict:label_verdict ->
  labeler:string ->
  reason:string ->
  unit
(** Append a human label for ground-truth tracking. *)

(** {1 Reading} *)

val stored_record_of_json : Yojson.Safe.t -> (stored_record, string) result
(** The inverse of the two writers above, and the only decoder of a stored
    row. Every key is read the way its writer writes it: a key the writer
    always writes is required, [fallback_reason] is absent for [None], and
    [generator_runtime], [producer_execution] and [evaluator_execution] are
    [null] for [None]. A row neither writer produces -- a missing or repeated
    key, a value of another JSON type, a verdict, gate, label or record type
    outside the current vocabulary -- is an [Error] naming the key. *)

val read_window :
  ?since:string -> ?until:string -> base_path:string -> max_rows:int -> unit -> window
(** Decode at most the newest [max_rows] rows, within the ["YYYY-MM-DD"] date
    filters when given. Every reader of the store goes through this. *)

(** {1 Analysis} *)

val find_divergences :
  ?since:string -> ?until:string -> base_path:string -> unit -> divergence_scan
(** Find cases where evaluator and human verdicts disagree.
    Date filters use ["YYYY-MM-DD"] format. *)

val select_examples : base_path:string -> max_examples:int -> calibration_example list
(** Select few-shot calibration examples from recent divergences.
    Prioritizes false positives (evaluator approve + human reject). *)

val format_few_shot_block : calibration_example list -> string
(** Format examples into a text block for prompt injection.
    Returns [""] for an empty list. *)

(** {1 Statistics} *)

val calibration_stats :
  ?since:string -> ?until:string -> base_path:string -> unit -> Yojson.Safe.t
(** Compute summary statistics: verdict counts, gate distribution,
    false positive/negative rates, agreement rate. [distinct_runtime_rate]
    compares recorded runtime identifiers and is [null] when no pair was
    recorded. [model_identity_observation] separately compares the captured
    submitting-response/verdict-response provider and reported-model
    identities, retaining observed
    and unobserved coverage and causes. Its rate is [null] without a complete
    pair. Submission identity does not identify every model or collaborator
    that authored an artifact; identity diversity does not establish weight
    differences or statistical independence. [unreadable_record_count] is the
    number of rows in the window that {!stored_record_of_json} refused; no
    other count includes them. *)
