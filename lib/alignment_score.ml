(* Alignment Score backend - implementation.

   See alignment_score.mli for the interface contract.

   This follows the Master Report section 3.3 formula with two obvious
   threshold fixes applied on raw metrics:

     1. `normalized.TMP > 150 -> Behind_schedule` is impossible because
        normalized values are capped at 100. Use raw `tmp > 1.5`.

     2. `normalized.DBT > 50 -> High_debt` is inverted because DBT
        normalization gives higher scores to lower debt. Use raw
        `dbt > 0.5`.

   See the PR body's "Master Report bug fixes" section. *)

type metrics = {
  trc : float;
  cov : float;
  cmp : float;
  crn : float;
  dbt : float;
  tmp : float;
  dir : float;
  coh : float;
  bnd : float;
  cnf : float;
}

type weights = {
  trc : float;
  cov : float;
  cmp : float;
  crn : float;
  dbt : float;
  tmp : float;
  dir : float;
  coh : float;
  bnd : float;
  cnf : float;
}

let default_weights = {
  trc = 0.15;
  cov = 0.15;
  cmp = 0.10;
  crn = 0.10;
  dbt = 0.10;
  tmp = 0.10;
  dir = 0.10;
  coh = 0.05;
  bnd = 0.05;
  cnf = 0.10;
}

let sum_weights w =
  w.trc +. w.cov +. w.cmp +. w.crn +. w.dbt +. w.tmp
  +. w.dir +. w.coh +. w.bnd +. w.cnf

type normalized = {
  trc : float;
  cov : float;
  cmp : float;
  crn : float;
  dbt : float;
  tmp : float;
  dir : float;
  coh : float;
  bnd : float;
  cnf : float;
}

type grade = A | B | C | D | F

let grade_to_string = function
  | A -> "A"
  | B -> "B"
  | C -> "C"
  | D -> "D"
  | F -> "F"

let grade_of_score s =
  if s >= 90.0 then A
  else if s >= 75.0 then B
  else if s >= 60.0 then C
  else if s >= 40.0 then D
  else F

type warning =
  | Low_traceability
  | Low_coverage
  | High_debt
  | Behind_schedule
  | Wrong_direction

let warning_to_string = function
  | Low_traceability -> "low_traceability"
  | Low_coverage -> "low_coverage"
  | High_debt -> "high_debt"
  | Behind_schedule -> "behind_schedule"
  | Wrong_direction -> "wrong_direction"

type result = {
  score : int;
  grade : grade;
  warnings : warning list;
  normalized : normalized;
}

(* Helpers ------------------------------------------------------------ *)

let clamp01 x = if x < 0.0 then 0.0 else if x > 1.0 then 1.0 else x

let clamp01_to_100 x = clamp01 x *. 100.0

let dist_from_one x = Float.abs (x -. 1.0)

let normalize (m : metrics) : normalized =
  {
    trc = clamp01_to_100 m.trc;
    cov = clamp01_to_100 m.cov;
    cmp = clamp01_to_100 (1.0 -. dist_from_one m.cmp);
    crn = clamp01_to_100 (1.0 -. dist_from_one m.crn);
    dbt = clamp01_to_100 (1.0 -. m.dbt);
    tmp = clamp01_to_100 (1.0 -. dist_from_one m.tmp);
    dir = clamp01_to_100 ((m.dir +. 1.0) /. 2.0);
    coh = clamp01_to_100 m.coh;
    bnd = clamp01_to_100 (1.0 -. m.bnd);
    cnf = clamp01_to_100 m.cnf;
  }

let weighted_score (w : weights) (n : normalized) =
  (w.trc *. n.trc)
  +. (w.cov *. n.cov)
  +. (w.cmp *. n.cmp)
  +. (w.crn *. n.crn)
  +. (w.dbt *. n.dbt)
  +. (w.tmp *. n.tmp)
  +. (w.dir *. n.dir)
  +. (w.coh *. n.coh)
  +. (w.bnd *. n.bnd)
  +. (w.cnf *. n.cnf)

let warnings_of_metrics (m : metrics) : warning list =
  let acc = ref [] in
  let push w = acc := w :: !acc in
  if m.trc < 0.5 then push Low_traceability;
  if m.cov < 0.5 then push Low_coverage;
  if m.dbt > 0.5 then push High_debt;
  if m.tmp > 1.5 then push Behind_schedule;
  if m.dir < 0.0 then push Wrong_direction;
  List.rev !acc

let calculate ?(weights = default_weights) (m : metrics) : result =
  let n = normalize m in
  let s = weighted_score weights n in
  let s = if s < 0.0 then 0.0 else if s > 100.0 then 100.0 else s in
  let score = int_of_float (Float.round s) in
  {
    score;
    grade = grade_of_score (float_of_int score);
    warnings = warnings_of_metrics m;
    normalized = n;
  }

(* JSON codec --------------------------------------------------------- *)

let normalized_to_yojson (n : normalized) : Yojson.Safe.t =
  `Assoc
    [
      "trc", `Float n.trc;
      "cov", `Float n.cov;
      "cmp", `Float n.cmp;
      "crn", `Float n.crn;
      "dbt", `Float n.dbt;
      "tmp", `Float n.tmp;
      "dir", `Float n.dir;
      "coh", `Float n.coh;
      "bnd", `Float n.bnd;
      "cnf", `Float n.cnf;
    ]

let result_to_yojson (r : result) : Yojson.Safe.t =
  `Assoc
    [
      "score", `Int r.score;
      "grade", `String (grade_to_string r.grade);
      "warnings",
        `List (List.map (fun w -> `String (warning_to_string w)) r.warnings);
      "normalized", normalized_to_yojson r.normalized;
    ]
