(** Repo_synthesis_benchmark — Score answers against gold-standard
    repo synthesis questions.

    Compares two answer sets ([baseline] vs [swarm]) on a shared
    question list.  Each question carries [required_claims] and
    [gold_paths]; each answer reports [claims] and [cited_paths];
    scoring computes per-question evidence_precision +
    claim_coverage + unsupported_claim_penalty and folds these
    into a [score_summary] composite.

    Internal: 38 helpers stay private — bench_root /
    contains_substring / validate_run_id / run_dir_unchecked /
    run_json_path_unchecked / score_json_path_unchecked / run_dir
    / run_json_path / score_json_path / write_json_file /
    read_json_file_opt / normalize_ci_string / normalize_rel_path
    / path_matches / string_list_member_ci / avg_float, the
    per-type yojson encoders/decoders (question_to_yojson +
    question_of_yojson, answer_of_yojson, question_score_to_yojson,
    score_summary_of_yojson, run_record_to_yojson +
    run_record_of_yojson), make_run_id, the run-state I/O
    (save_run, save_score, load_run, load_score, scan_run_ids,
    list_runs), find_question_by_id, score_answer (per-question
    grader), and run_summary_json + run_record type.  All consumed
    only inside the 5 public entries or the file-state I/O block. *)

(** {1 Question / answer types} *)

type question = {
  question_id : string;
  title : string;
  question : string;
  artifact_scope : string list;
      (** Repo-relative paths the answer is allowed to cite. *)
  required_claims : string list;
      (** Claims that must appear (case-insensitive) for full
          [claim_coverage]. *)
  gold_paths : string list;
      (** Paths the answer should cite — used for
          [evidence_precision]. *)
  difficulty : string option;
  tags : string list;
}

type answer = {
  question_id : string;
  claims : string list;
  cited_paths : string list;
  latency_ms : int;
}

(** {1 Score types} *)

type question_score = {
  question_id : string;
  evidence_precision : float;
      (** Fraction of [cited_paths] matched against [gold_paths]. *)
  claim_coverage : float;
      (** Fraction of [required_claims] satisfied by [claims]. *)
  unsupported_claim_penalty : float;
      (** Penalty for claims not backed by [cited_paths]. *)
  latency_ms : int;
  matched_claims : string list;
  missing_claims : string list;
  matched_paths : string list;
  unsupported_claims : string list;
}

type score_summary = {
  answer_set_label : string;
      (** Caller-supplied label (typically ["baseline"] / ["swarm"]). *)
  question_count : int;
  answered_count : int;
  evidence_precision : float;
  claim_coverage : float;
  unsupported_claim_penalty : float;
  avg_latency_ms : float;
  composite_score : float;
      (** Folded score.  Drift in the composite formula changes
          baseline-vs-swarm comparison verdicts — pinned at
          contract seam. *)
  per_question : question_score list;
}

(** {1 Path resolution} *)

val default_question_set_path : repo_root:string -> string
(** [default_question_set_path ~repo_root] is the canonical
    relative path to the gold question-set JSON.  Pinned at the
    contract seam — drift would silently change which questions
    the benchmark uses. *)

(** {1 Loading} *)

val load_question_set : repo_root:string -> question list
(** [load_question_set ~repo_root] reads
    [default_question_set_path ~repo_root] and parses it as a
    list of {!question} records. *)

val load_answers_from_file : string -> answer list
(** [load_answers_from_file path] reads [path] as a JSON array
    and parses each element as an {!answer} record. *)

(** {1 Scoring} *)

val score_answers :
  label:string ->
  questions:question list ->
  answers:answer list ->
  score_summary
(** [score_answers ~label ~questions ~answers] grades [answers]
    against [questions] using {!score_answer} per-question, then
    folds into a {!score_summary}.  Unanswered questions still
    appear in [per_question] with zero scores; [answered_count]
    counts only questions for which an answer was supplied.
    [composite_score] aggregates the three core scoring
    dimensions — see {!score_summary.composite_score} for the
    drift pin rationale. *)

(** {1 JSON encoding} *)

val score_summary_to_yojson : score_summary -> Yojson.Safe.t
(** [score_summary_to_yojson summary] renders the summary as a
    JSON object suitable for benchmark report inclusion.  Used
    by callers to embed baseline / swarm comparison snapshots
    alongside a [swarm_beats_baseline] flag. *)
