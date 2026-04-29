(* Tier A10b — Multimodal Review evaluation tests. *)

module R = Multimodal.Review
module Aid = Shared_types.Artifact_id

let check_bool label b =
  if not b then failwith (Printf.sprintf "%s: false" label)

let check_int label expected actual =
  if expected <> actual then
    failwith
      (Printf.sprintf "%s: expected %d, got %d" label expected actual)

let check_float label expected actual =
  if not (Float.equal expected actual) then
    failwith
      (Printf.sprintf "%s: expected %f, got %f" label expected actual)

let check_str label expected actual =
  if not (String.equal expected actual) then
    failwith
      (Printf.sprintf "%s: expected %S, got %S" label expected actual)

let must = function Ok v -> v | Error e -> failwith e

let make_id _ts = Aid.generate ()

let assoc_string key json =
  match json with
  | `Assoc kv -> (
      match List.assoc_opt key kv with
      | Some (`String s) -> s
      | _ -> failwith (Printf.sprintf "no string field %S" key))
  | _ -> failwith "expected JSON object"

let assoc_float key json =
  match json with
  | `Assoc kv -> (
      match List.assoc_opt key kv with
      | Some (`Float f) -> f
      | _ -> failwith (Printf.sprintf "no float field %S" key))
  | _ -> failwith "expected JSON object"

(* ── Score boundaries ──────────────────────────────────────────── *)

let test_score_clip () =
  check_float "clip 0.5" 0.5 (R.score_to_float (R.score_clip 0.5));
  check_float "clip neg → 0" 0.0 (R.score_to_float (R.score_clip (-1.0)));
  check_float "clip >1 → 1" 1.0 (R.score_to_float (R.score_clip 1.5));
  check_float "clip nan → 0" 0.0
    (R.score_to_float (R.score_clip Float.nan))

let test_score_of_float () =
  let ok = R.score_of_float 0.7 in
  check_bool "0.7 ok" (Result.is_ok ok);
  check_bool "1.5 err" (Result.is_error (R.score_of_float 1.5));
  check_bool "-0.1 err" (Result.is_error (R.score_of_float (-0.1)));
  check_bool "nan err"
    (Result.is_error (R.score_of_float Float.nan));
  check_bool "inf err"
    (Result.is_error (R.score_of_float Float.infinity))

let test_score_constants () =
  check_float "score_zero" 0.0 (R.score_to_float R.score_zero);
  check_float "score_one" 1.0 (R.score_to_float R.score_one)

(* ── Assessment kinds ──────────────────────────────────────────── *)

let test_all_assessment_kinds () =
  check_int "kind count" 4 (List.length R.all_assessment_kinds);
  check_str "Quality" "quality"
    (R.assessment_kind_to_string R.Quality);
  check_str "Safety" "safety"
    (R.assessment_kind_to_string R.Safety);
  check_str "Coherence" "coherence"
    (R.assessment_kind_to_string R.Coherence);
  check_str "Coverage" "coverage"
    (R.assessment_kind_to_string R.Coverage)

(* ── Rubric JSON ───────────────────────────────────────────────── *)

let test_rubric_score_json_with_notes () =
  let rs : R.rubric_score =
    {
      kind = R.Quality;
      rubric = "design clarity";
      score = R.score_clip 0.8;
      notes = Some "minor ambiguity";
    }
  in
  let json = R.rubric_score_to_json rs in
  check_str "rubric kind json" "quality" (assoc_string "kind" json);
  check_str "rubric notes json" "minor ambiguity"
    (assoc_string "notes" json);
  check_float "rubric score json" 0.8 (assoc_float "score" json)

let test_rubric_score_json_no_notes () =
  let rs : R.rubric_score =
    {
      kind = R.Safety;
      rubric = "no PII";
      score = R.score_clip 1.0;
      notes = None;
    }
  in
  let json = R.rubric_score_to_json rs in
  match json with
  | `Assoc kv ->
      check_bool "no notes field"
        (not (List.mem_assoc "notes" kv));
      check_str "kind" "safety" (assoc_string "kind" json)
  | _ -> failwith "expected object"

(* ── Verdict tag projection ────────────────────────────────────── *)

let test_verdict_to_tag () =
  check_bool "Pass → Pass_tag"
    (R.verdict_to_tag R.Pass = R.Pass_tag);
  check_bool "Fail → Fail_tag"
    (R.verdict_to_tag R.Fail = R.Fail_tag);
  check_bool "Conditional → Conditional_tag"
    (R.verdict_to_tag (R.Conditional { conditions = [ "a" ] })
    = R.Conditional_tag)

let test_all_verdict_tags () =
  check_int "verdict_tag count" 3 (List.length R.all_verdict_tags);
  check_bool "Pass_tag in list"
    (List.mem R.Pass_tag R.all_verdict_tags);
  check_bool "Fail_tag in list"
    (List.mem R.Fail_tag R.all_verdict_tags);
  check_bool "Conditional_tag in list"
    (List.mem R.Conditional_tag R.all_verdict_tags)

(* ── Empty review ──────────────────────────────────────────────── *)

let test_empty_review () =
  let aid = make_id 1.0 in
  let r = R.empty_review ~artifact_id:aid ~reviewed_at:1.0 in
  check_int "empty rubric_scores length" 0
    (List.length r.rubric_scores);
  check_float "empty overall" 0.0 (R.score_to_float r.overall);
  check_bool "empty verdict = Fail" (r.verdict = R.Fail);
  check_float "reviewed_at" 1.0 r.reviewed_at

let test_add_rubric_score () =
  let aid = make_id 2.0 in
  let r0 = R.empty_review ~artifact_id:aid ~reviewed_at:2.0 in
  let rs : R.rubric_score =
    {
      kind = R.Quality;
      rubric = "x";
      score = R.score_clip 0.9;
      notes = None;
    }
  in
  let r1 = R.add_rubric_score rs r0 in
  check_int "after add" 1 (List.length r1.rubric_scores)

(* ── Evaluate verdict branches ────────────────────────────────── *)

let mk_rs k r s =
  ({
     R.kind = k;
     rubric = r;
     score = R.score_clip s;
     notes = None;
   }
    : R.rubric_score)

let test_evaluate_pass () =
  let aid = make_id 3.0 in
  let r =
    R.empty_review ~artifact_id:aid ~reviewed_at:3.0
    |> R.with_rubric_scores
         [
           mk_rs R.Quality "design" 0.9;
           mk_rs R.Safety "no PII" 0.95;
           mk_rs R.Coverage "spec match" 0.85;
         ]
  in
  let r =
    R.evaluate ~pass_threshold:(R.score_clip 0.8)
      ~conditional_threshold:(R.score_clip 0.5)
      r
  in
  check_bool "pass" (r.verdict = R.Pass);
  check_bool "overall ≥ 0.8" (R.score_to_float r.overall >= 0.8)

let test_evaluate_fail () =
  let aid = make_id 4.0 in
  let r =
    R.empty_review ~artifact_id:aid ~reviewed_at:4.0
    |> R.with_rubric_scores
         [
           mk_rs R.Quality "design" 0.2;
           mk_rs R.Safety "PII leak" 0.1;
         ]
  in
  let r =
    R.evaluate ~pass_threshold:(R.score_clip 0.8)
      ~conditional_threshold:(R.score_clip 0.5)
      r
  in
  check_bool "fail" (r.verdict = R.Fail)

let test_evaluate_conditional () =
  let aid = make_id 5.0 in
  let r =
    R.empty_review ~artifact_id:aid ~reviewed_at:5.0
    |> R.with_rubric_scores
         [
           mk_rs R.Quality "design" 0.9;
           mk_rs R.Safety "PII partial" 0.4;
           mk_rs R.Coverage "spec gap" 0.5;
         ]
  in
  (* mean = (0.9 + 0.4 + 0.5) / 3 = 0.6 *)
  let r =
    R.evaluate ~pass_threshold:(R.score_clip 0.8)
      ~conditional_threshold:(R.score_clip 0.5)
      r
  in
  match r.verdict with
  | Conditional { conditions } ->
      (* Two rubrics below pass_threshold (0.4, 0.5) *)
      check_int "conditional count" 2 (List.length conditions);
      check_bool "PII partial in conditions"
        (List.mem "PII partial" conditions);
      check_bool "spec gap in conditions"
        (List.mem "spec gap" conditions)
  | _ -> failwith "expected Conditional"

let test_evaluate_empty_scores () =
  let aid = make_id 6.0 in
  let r0 = R.empty_review ~artifact_id:aid ~reviewed_at:6.0 in
  let r =
    R.evaluate ~pass_threshold:(R.score_clip 0.5)
      ~conditional_threshold:(R.score_clip 0.0)
      r0
  in
  (* mean = 0.0; 0.0 >= conditional_threshold 0.0 → Conditional with 0 conditions *)
  check_bool "empty → Conditional"
    (R.verdict_to_tag r.verdict = R.Conditional_tag)

(* ── JSON shape ────────────────────────────────────────────────── *)

let test_review_to_json_shape () =
  let aid = make_id 7.0 in
  let r =
    R.empty_review ~artifact_id:aid ~reviewed_at:7.0
    |> R.with_rubric_scores
         [ mk_rs R.Quality "x" 0.9 ]
    |> R.evaluate ~pass_threshold:(R.score_clip 0.5)
         ~conditional_threshold:(R.score_clip 0.0)
  in
  let json = R.review_to_json r in
  match json with
  | `Assoc kv ->
      check_bool "has artifact_id" (List.mem_assoc "artifact_id" kv);
      check_bool "has rubric_scores"
        (List.mem_assoc "rubric_scores" kv);
      check_bool "has overall" (List.mem_assoc "overall" kv);
      check_bool "has verdict" (List.mem_assoc "verdict" kv);
      check_bool "has reviewed_at"
        (List.mem_assoc "reviewed_at" kv)
  | _ -> failwith "expected object"

let test_verdict_json () =
  let _ =
    R.verdict_to_json (R.Conditional { conditions = [ "a"; "b" ] })
  in
  check_str "Pass kind" "pass"
    (assoc_string "kind" (R.verdict_to_json R.Pass));
  check_str "Fail kind" "fail"
    (assoc_string "kind" (R.verdict_to_json R.Fail));
  check_str "Conditional kind" "conditional"
    (assoc_string "kind"
       (R.verdict_to_json
          (R.Conditional { conditions = [ "x" ] })))

(* ── Driver ─────────────────────────────────────────────────────── *)

let () =
  let cases =
    [
      ("score_clip", test_score_clip);
      ("score_of_float", test_score_of_float);
      ("score_constants", test_score_constants);
      ("all_assessment_kinds", test_all_assessment_kinds);
      ("rubric_score_json_with_notes", test_rubric_score_json_with_notes);
      ("rubric_score_json_no_notes", test_rubric_score_json_no_notes);
      ("verdict_to_tag", test_verdict_to_tag);
      ("all_verdict_tags", test_all_verdict_tags);
      ("empty_review", test_empty_review);
      ("add_rubric_score", test_add_rubric_score);
      ("evaluate_pass", test_evaluate_pass);
      ("evaluate_fail", test_evaluate_fail);
      ("evaluate_conditional", test_evaluate_conditional);
      ("evaluate_empty_scores", test_evaluate_empty_scores);
      ("review_to_json_shape", test_review_to_json_shape);
      ("verdict_json", test_verdict_json);
    ]
  in
  ignore must;
  List.iter
    (fun (name, f) ->
      try f ()
      with e ->
        Printf.printf "FAIL %s: %s\n" name (Printexc.to_string e);
        exit 1)
    cases;
  Printf.printf "test_review: %d cases OK\n" (List.length cases)
