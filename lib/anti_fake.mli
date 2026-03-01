(** Anti-Fake Test Quality Scoring — Pure heuristic analysis.

    Scores test files based on pattern detection to identify
    vacuous ("fake") tests and reward genuine quality indicators.

    @since 2.75.0 *)

(** Severity classification for a detected pattern. *)
type severity =
  | Info
  | Warning
  | Critical

(** A single pattern match found in the source. *)
type finding = {
  line_number : int;
  pattern : string;
  severity : severity;
  penalty : float;
  context : string;
}

(** Scoring result for one test file. *)
type score_result = {
  file_path : string;
  raw_score : float;       (** Before clamping to [0.0, 1.0]. *)
  final_score : float;     (** Clamped to [0.0, 1.0]. *)
  findings : finding list;
  total_lines : int;
  test_lines : int;        (** Lines containing test-related patterns. *)
  quality_tier : string;   (** One of "excellent", "good", "suspect", "fake". *)
}

(** Aggregate statistics across multiple files. *)
type audit_summary = {
  total_files : int;
  avg_score : float;
  min_score : float;
  max_score : float;
  fake_count : int;        (** Files with [final_score < 0.3]. *)
  suspect_count : int;     (** Files with [0.3 <= final_score < 0.5]. *)
  results : score_result list;
}

(** Penalty patterns with their weights and severities. *)
val penalties : (string * float * severity) list

(** Bonus patterns with their weights. *)
val bonuses : (string * float) list

(** The base score before penalties and bonuses: [0.5]. *)
val base_score : float

(** [clamp v ~lo ~hi] constrains [v] to [[lo, hi]]. *)
val clamp : float -> lo:float -> hi:float -> float

(** Map a numeric score to a quality tier label. *)
val quality_tier : float -> string

(** [score_content ~file_path content] scores the given string
    as though it were the contents of [file_path].
    Pure — performs no I/O. *)
val score_content : file_path:string -> string -> score_result

(** [score_file path] reads [path] and scores its contents. *)
val score_file : string -> score_result

(** Aggregate a list of results into a summary. *)
val summarize : score_result list -> audit_summary

(** {2 JSON serialization} *)

val severity_to_string : severity -> string
val finding_to_json : finding -> Yojson.Safe.t
val result_to_json : score_result -> Yojson.Safe.t
val summary_to_json : audit_summary -> Yojson.Safe.t
