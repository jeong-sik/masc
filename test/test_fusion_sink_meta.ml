(* RFC-0252 §8 — judge_meta 가 board meta_json 에 구조화 5섹션을 보존하는지 핀한다.

   프론트(FusionJudgeEvidence, keeper-v2 fusion.jsx)가 consensus/contradictions/
   partial_coverage/unique_insights/blind_spots + decision-variant 최상위
   recommend|missing 를 소비한다. 키 매핑(OCaml 레코드명 → LLM-facing JSON 키:
   gap_topic→topic, insight_text→text, from_model→model, supporting_models→models)이
   틀리면 프론트가 빈 배열만 보게 되므로 이 테스트가 회귀를 잡는다. ppx 자동
   직렬화가 OCaml 필드명을 그대로 쓰는 실수를 방어하는 것이 이 테스트의 핵심 가치다. *)

open Alcotest
open Fusion_types

let lookup k a = List.find_opt (fun (k', _) -> String.equal k k') a

let keys a = List.map fst a

let string_field a k =
  match lookup k a with Some (_, `String s) -> Some s | _ -> None

let list_field a k =
  match lookup k a with Some (_, `List l) -> Some l | _ -> None

let assoc_of = function `Assoc a -> a | _ -> []

let full_synthesis ?(decision = Answer "a") () : judge_synthesis =
  { consensus = [ { text = "c1"; supporting_models = [ "m1"; "m2" ] } ]
  ; contradictions =
      [ { topic = "t1"; positions = [ ("m1", "yes"); ("m2", "no") ]; evidence = [] } ]
  ; partial_coverage = [ { gap_topic = "g1"; addressed_by = [ "m1" ]; missing = Some "x" } ]
  ; unique_insights = [ { insight_text = "u1"; from_model = "m2" } ]
  ; blind_spots = [ "b1" ]
  ; resolved_answer = "RA"
  ; decision }

(* --- 5섹션 키 존재 + 기존 평탄화 필드 보존 --- *)

let test_ok_has_five_sections () =
  let a = assoc_of (Masc.Fusion_sink.judge_meta (Ok (full_synthesis ()))) in
  let ks = keys a in
  check bool "consensus key" true (List.mem "consensus" ks);
  check bool "contradictions key" true (List.mem "contradictions" ks);
  check bool "partial_coverage key" true (List.mem "partial_coverage" ks);
  check bool "unique_insights key" true (List.mem "unique_insights" ks);
  check bool "blind_spots key" true (List.mem "blind_spots" ks);
  (* 구형 호환 필드도 보존 — synthesis markdown 제거는 별도 마이그레이션. *)
  check (option string) "resolved_answer preserved" (Some "RA") (string_field a "resolved_answer");
  check bool "synthesis preserved" true (Option.is_some (string_field a "synthesis"))

(* --- decision variant → 최상위 recommend|missing --- *)

let test_answer_has_no_recommend_missing () =
  let a =
    assoc_of
      (Masc.Fusion_sink.judge_meta (Ok (full_synthesis ~decision:(Answer "a") ())))
  in
  let ks = keys a in
  check bool "no recommend on Answer" false (List.mem "recommend" ks);
  check bool "no missing on Answer" false (List.mem "missing" ks)

let test_recommend_emits_top_level_recommend () =
  let d = Recommend { action = "do"; rationale = "why" } in
  let a = assoc_of (Masc.Fusion_sink.judge_meta (Ok (full_synthesis ~decision:d ()))) in
  match lookup "recommend" a with
  | Some (_, `Assoc r) ->
    check (option string) "recommend.action" (Some "do") (string_field r "action");
    check (option string) "recommend.rationale" (Some "why") (string_field r "rationale")
  | _ -> fail "recommend field missing or not an object"

let test_insufficient_emits_top_level_missing () =
  let d = Insufficient { missing_for_decision = [ "a"; "b" ] } in
  let a = assoc_of (Masc.Fusion_sink.judge_meta (Ok (full_synthesis ~decision:d ()))) in
  (match list_field a "missing" with
   | Some [ `String x; `String y ] ->
     check string "missing[0]" "a" x;
     check string "missing[1]" "b" y
   | _ -> fail "missing field missing or wrong shape")

(* --- 키 매핑 정확성 (이 테스트의 핵심 가치) --- *)

let test_key_mapping_claim () =
  (* supporting_models → models *)
  let a = assoc_of (Masc.Fusion_sink.judge_meta (Ok (full_synthesis ()))) in
  match list_field a "consensus" with
  | Some (`Assoc c0 :: _) ->
    check (option string) "claim.text" (Some "c1") (string_field c0 "text");
    (match lookup "models" c0 with
     | Some (_, `List ms) -> check int "claim.models length" 2 (List.length ms)
     | _ -> fail "models key missing — did ppx field name leak?");
    check bool "no supporting_models key" false (List.mem "supporting_models" (keys c0))
  | _ -> fail "consensus[0] missing"

let test_key_mapping_coverage_and_insight () =
  let a = assoc_of (Masc.Fusion_sink.judge_meta (Ok (full_synthesis ()))) in
  (* gap_topic → topic *)
  (match list_field a "partial_coverage" with
   | Some (`Assoc g0 :: _) ->
     check (option string) "gap.topic" (Some "g1") (string_field g0 "topic");
     check (option string) "gap.addressed_by[0]" (Some "m1")
       (match list_field g0 "addressed_by" with
        | Some (`String m :: _) -> Some m
        | _ -> None);
     check (option string) "gap.missing" (Some "x") (string_field g0 "missing");
     check bool "no gap_topic key" false (List.mem "gap_topic" (keys g0))
   | _ -> fail "partial_coverage[0] missing");
  (* insight_text → text, from_model → model *)
  (match list_field a "unique_insights" with
   | Some (`Assoc i0 :: _) ->
     check (option string) "insight.text" (Some "u1") (string_field i0 "text");
     check (option string) "insight.model" (Some "m2") (string_field i0 "model");
     check bool "no insight_text key" false (List.mem "insight_text" (keys i0));
     check bool "no from_model key" false (List.mem "from_model" (keys i0))
   | _ -> fail "unique_insights[0] missing")

let test_contradiction_positions () =
  let a = assoc_of (Masc.Fusion_sink.judge_meta (Ok (full_synthesis ()))) in
  (match list_field a "contradictions" with
   | Some (`Assoc ct0 :: _) ->
     check (option string) "contra.topic" (Some "t1") (string_field ct0 "topic");
     (match list_field ct0 "positions" with
      | Some (`Assoc p0 :: _) ->
        check (option string) "pos.model" (Some "m1") (string_field p0 "model");
        check (option string) "pos.stance" (Some "yes") (string_field p0 "stance")
      | _ -> fail "positions missing")
   | _ -> fail "contradictions[0] missing")

let test_error_branch () =
  let a = assoc_of (Masc.Fusion_sink.judge_meta (Error "boom")) in
  check (option string) "status failed" (Some "failed") (string_field a "status");
  check (option string) "error message" (Some "boom") (string_field a "error");
  check bool "no consensus on error" false (List.mem "consensus" (keys a))

let () =
  run "Fusion_sink.judge_meta"
    [ ( "structured"
      , [ test_case "ok_has_five_sections" `Quick test_ok_has_five_sections
        ; test_case "answer_has_no_recommend_missing" `Quick
            test_answer_has_no_recommend_missing
        ; test_case "recommend_emits_top_level" `Quick
            test_recommend_emits_top_level_recommend
        ; test_case "insufficient_emits_top_level_missing" `Quick
            test_insufficient_emits_top_level_missing
        ; test_case "error_branch" `Quick test_error_branch
        ] )
    ; ( "key_mapping"
      , [ test_case "claim_text_models" `Quick test_key_mapping_claim
        ; test_case "coverage_gap_and_insight" `Quick
            test_key_mapping_coverage_and_insight
        ; test_case "contradiction_positions" `Quick test_contradiction_positions
        ] )
    ]
