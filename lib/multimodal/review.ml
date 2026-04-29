(* Review — Cycle 26 / Tier A10b.
   See review.mli for design rationale. *)

(* ── Score ─────────────────────────────────────────────────────── *)

type score = float

let score_of_float f =
  if Float.is_nan f then Error "score must not be NaN"
  else if not (Float.is_finite f) then
    Error "score must be a finite float"
  else if f < 0.0 then
    Error (Printf.sprintf "score %f below 0.0" f)
  else if f > 1.0 then
    Error (Printf.sprintf "score %f above 1.0" f)
  else Ok f

let score_to_float s = s

let score_clip f =
  if Float.is_nan f then 0.0
  else if f < 0.0 then 0.0
  else if f > 1.0 then 1.0
  else f

let score_zero = 0.0

let score_one = 1.0

(* ── Assessment kind ───────────────────────────────────────────── *)

type assessment_kind =
  | Quality [@tla.symbol "quality"]
  | Safety [@tla.symbol "safety"]
  | Coherence [@tla.symbol "coherence"]
  | Coverage [@tla.symbol "coverage"]
[@@deriving tla]

let all_assessment_kinds = [ Quality; Safety; Coherence; Coverage ]

let assessment_kind_to_string = function
  | Quality -> "quality"
  | Safety -> "safety"
  | Coherence -> "coherence"
  | Coverage -> "coverage"

(* ── Rubric ────────────────────────────────────────────────────── *)

type rubric_score = {
  kind : assessment_kind;
  rubric : string;
  score : score;
  notes : string option;
}

let rubric_score_to_json rs =
  let notes_field =
    match rs.notes with
    | Some n -> [ ("notes", `String n) ]
    | None -> []
  in
  `Assoc
    ([
       ("kind", `String (assessment_kind_to_string rs.kind));
       ("rubric", `String rs.rubric);
       ("score", `Float (score_to_float rs.score));
     ]
    @ notes_field)

(* ── Verdict ───────────────────────────────────────────────────── *)

type verdict =
  | Pass
  | Fail
  | Conditional of { conditions : string list }

type verdict_tag =
  | Pass_tag [@tla.symbol "pass"]
  | Fail_tag [@tla.symbol "fail"]
  | Conditional_tag [@tla.symbol "conditional"]
[@@deriving tla]

let all_verdict_tags = [ Pass_tag; Fail_tag; Conditional_tag ]

let verdict_to_tag = function
  | Pass -> Pass_tag
  | Fail -> Fail_tag
  | Conditional _ -> Conditional_tag

let verdict_to_json = function
  | Pass -> `Assoc [ ("kind", `String "pass") ]
  | Fail -> `Assoc [ ("kind", `String "fail") ]
  | Conditional { conditions } ->
      `Assoc
        [
          ("kind", `String "conditional");
          ( "conditions",
            `List (List.map (fun c -> `String c) conditions) );
        ]

(* ── Review ────────────────────────────────────────────────────── *)

type review = {
  artifact_id : Shared_types.Artifact_id.t;
  rubric_scores : rubric_score list;
  overall : score;
  verdict : verdict;
  reviewed_at : float;
}

let empty_review ~artifact_id ~reviewed_at =
  {
    artifact_id;
    rubric_scores = [];
    overall = score_zero;
    verdict = Fail;
    reviewed_at;
  }

let add_rubric_score rs r =
  { r with rubric_scores = rs :: r.rubric_scores }

let with_rubric_scores rss r = { r with rubric_scores = rss }

let mean_score scores =
  match scores with
  | [] -> score_zero
  | _ ->
      let total =
        List.fold_left (fun acc s -> acc +. score_to_float s) 0.0 scores
      in
      score_clip (total /. float_of_int (List.length scores))

let evaluate ~pass_threshold ~conditional_threshold review =
  let scores =
    List.map (fun rs -> rs.score) review.rubric_scores
  in
  let overall = mean_score scores in
  let verdict =
    if overall >= score_to_float pass_threshold then Pass
    else if overall >= score_to_float conditional_threshold then
      let conditions =
        List.filter_map
          (fun rs ->
            if score_to_float rs.score < score_to_float pass_threshold
            then Some rs.rubric
            else None)
          review.rubric_scores
      in
      Conditional { conditions }
    else Fail
  in
  { review with overall; verdict }

let review_to_json r =
  `Assoc
    [
      ( "artifact_id",
        Shared_types.Artifact_id.to_json r.artifact_id );
      ( "rubric_scores",
        `List (List.map rubric_score_to_json r.rubric_scores) );
      ("overall", `Float (score_to_float r.overall));
      ("verdict", verdict_to_json r.verdict);
      ("reviewed_at", `Float r.reviewed_at);
    ]
