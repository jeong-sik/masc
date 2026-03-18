(** Anti-Fake Test Quality Scoring — Pure heuristic analysis.

    Detects common patterns of low-quality ("fake") tests:
    - [assert true] (vacuous assertion)
    - [let _ = expr] (discarding results)
    - TODO / FIXME comments (incomplete tests)
    - [skip] / [ignore] (disabled tests)

    And rewards quality indicators:
    - [Alcotest.check] / [assert_equal] (real assertions)
    - [roundtrip] (encoding/decoding verification)
    - [property] / [quickcheck] / [QCheck] (property-based testing)

    @since 2.75.0 *)

type severity =
  | Info
  | Warning
  | Critical

type finding = {
  line_number : int;
  pattern : string;
  severity : severity;
  penalty : float;
  context : string;
}

type score_result = {
  file_path : string;
  raw_score : float;
  final_score : float;
  findings : finding list;
  total_lines : int;
  test_lines : int;
  quality_tier : string;
}

type audit_summary = {
  total_files : int;
  avg_score : float;
  min_score : float;
  max_score : float;
  fake_count : int;
  suspect_count : int;
  results : score_result list;
}

(** Penalty patterns: (substring, weight, severity).
    Weights are negative — they reduce the score. *)
let penalties : (string * float * severity) list = [
  ("assert true", -0.3, Critical);
  ("assert_bool \"\" true", -0.3, Critical);
  ("let _ =", -0.2, Warning);
  ("(* TODO", -0.15, Warning);
  ("(* FIXME", -0.15, Warning);
  ("skip", -0.1, Info);
  ("ignore", -0.1, Info);
  ("fun _ ->", -0.05, Info);
]

(** Bonus patterns: (substring, weight).
    Weights are positive — each distinct occurrence (capped at 3)
    adds [weight * min(count, 3)] to the score. *)
let bonuses : (string * float) list = [
  ("Alcotest.(check", 0.15);
  ("Alcotest.check", 0.15);
  ("assert_equal", 0.1);
  ("check_raises", 0.1);
  ("expect", 0.1);
  ("roundtrip", 0.15);
  ("property", 0.1);
  ("quickcheck", 0.1);
  ("QCheck", 0.1);
  ("Crowbar", 0.1);
]

let base_score = 0.5

let clamp v ~lo ~hi = Float.max lo (Float.min hi v)

(** Return ["excellent"], ["good"], ["suspect"], or ["fake"]. *)
let quality_tier (score : float) : string =
  if score >= 0.8 then "excellent"
  else if score >= 0.5 then "good"
  else if score >= 0.3 then "suspect"
  else "fake"

(** True when [needle] is a substring of [haystack]. *)
let contains_substring haystack needle =
  let nlen = String.length needle in
  let hlen = String.length haystack in
  if nlen > hlen then false
  else begin
    let found = ref false in
    let i = ref 0 in
    while !i <= hlen - nlen && not !found do
      if String.sub haystack !i nlen = needle then found := true
      else incr i
    done;
    !found
  end

(** Truncate [s] to at most [max_len] characters, appending ["..."]
    when truncated. *)
let truncate_line s max_len =
  if String.length s > max_len then String.sub s 0 max_len ^ "..."
  else s

(** Score the content of a single test file.
    Pure function — no I/O. *)
let score_content ~(file_path : string) (content : string) : score_result =
  let lines = String.split_on_char '\n' content in
  let total_lines = List.length lines in
  let findings = ref [] in
  let bonus_total = ref 0.0 in

  (* Scan each line for penalty patterns *)
  List.iteri (fun i line ->
    let trimmed = String.trim line in
    if String.length trimmed > 0 then
      List.iter (fun (pattern, penalty, sev) ->
        if contains_substring trimmed pattern then
          findings := {
            line_number = i + 1;
            pattern;
            severity = sev;
            penalty;
            context = truncate_line trimmed 80;
          } :: !findings
      ) penalties
  ) lines;

  (* Scan all lines for bonus patterns, count occurrences (capped at 3) *)
  List.iter (fun (pattern, bonus) ->
    let count = List.fold_left (fun acc line ->
      if contains_substring line pattern then acc + 1 else acc
    ) 0 lines in
    if count > 0 then
      bonus_total := !bonus_total +. (bonus *. Float.of_int (min count 3))
  ) bonuses;

  (* Count lines that contain any test-related pattern *)
  let test_lines = List.length (List.filter (fun line ->
    let t = String.trim line in
    List.exists (fun (p, _) -> contains_substring t p) bonuses
    || List.exists (fun (p, _, _) -> contains_substring t p) penalties
  ) lines) in

  let penalty_total =
    List.fold_left (fun acc f -> acc +. f.penalty) 0.0 !findings
  in
  let raw_score = base_score +. penalty_total +. !bonus_total in
  let final_score = clamp raw_score ~lo:0.0 ~hi:1.0 in

  {
    file_path;
    raw_score;
    final_score;
    findings = List.rev !findings;
    total_lines;
    test_lines;
    quality_tier = quality_tier final_score;
  }

(** Score a test file by reading it from disk. *)
let score_file (file_path : string) : score_result =
  let content = Fs_compat.load_file file_path in
  score_content ~file_path content

(** Aggregate multiple [score_result]s into a summary. *)
let summarize (results : score_result list) : audit_summary =
  let n = List.length results in
  if n = 0 then {
    total_files = 0; avg_score = 0.0; min_score = 0.0;
    max_score = 0.0; fake_count = 0; suspect_count = 0; results = [];
  }
  else
    let scores = List.map (fun r -> r.final_score) results in
    let sum = List.fold_left ( +. ) 0.0 scores in
    let min_s = List.fold_left Float.min 1.0 scores in
    let max_s = List.fold_left Float.max 0.0 scores in
    {
      total_files = n;
      avg_score = sum /. Float.of_int n;
      min_score = min_s;
      max_score = max_s;
      fake_count =
        List.length (List.filter (fun r -> r.final_score < 0.3) results);
      suspect_count =
        List.length (List.filter (fun r ->
          r.final_score >= 0.3 && r.final_score < 0.5) results);
      results;
    }

(* ── JSON serialization ─────────────────────────────────────── *)

let severity_to_string = function
  | Info -> "info"
  | Warning -> "warning"
  | Critical -> "critical"

let finding_to_json (f : finding) : Yojson.Safe.t =
  `Assoc [
    ("line", `Int f.line_number);
    ("pattern", `String f.pattern);
    ("severity", `String (severity_to_string f.severity));
    ("penalty", `Float f.penalty);
    ("context", `String f.context);
  ]

let result_to_json (r : score_result) : Yojson.Safe.t =
  `Assoc [
    ("file", `String r.file_path);
    ("raw_score", `Float r.raw_score);
    ("final_score", `Float r.final_score);
    ("quality_tier", `String r.quality_tier);
    ("total_lines", `Int r.total_lines);
    ("test_lines", `Int r.test_lines);
    ("findings", `List (List.map finding_to_json r.findings));
  ]

let summary_to_json (s : audit_summary) : Yojson.Safe.t =
  `Assoc [
    ("total_files", `Int s.total_files);
    ("avg_score", `Float s.avg_score);
    ("min_score", `Float s.min_score);
    ("max_score", `Float s.max_score);
    ("fake_count", `Int s.fake_count);
    ("suspect_count", `Int s.suspect_count);
    ("results", `List (List.map result_to_json s.results));
  ]
