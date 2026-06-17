(* Fusion 하네스 코어 결정론 테스트 — mock run_result로 다수결·채점·delta 검증.
   실모델 없이 집계/채점/비교 로직만 검증한다 (RFC-0252 §11 결정론 부분). *)

module H = Fusion_harness_core

let usage i o : Fusion_types.usage =
  { Fusion_types.input_tokens = i; output_tokens = o }

(* ── 다수결 (self-consistency 집계, 결정론) ── *)

let test_majority_basic () =
  Alcotest.(check string)
    "최빈 답" "yes"
    (H.majority_vote [ "yes"; "no"; "yes" ])

let test_majority_tie_first () =
  (* 동률(각 1표)이면 입력에서 먼저 등장한 답. *)
  Alcotest.(check string)
    "동률 -> 첫 등장" "a"
    (H.majority_vote [ "a"; "b" ])

let test_majority_normalize () =
  (* "Yes"/"yes " 는 정규화 후 같은 키 -> 카운트 2, 원문은 첫 등장 "Yes". *)
  Alcotest.(check string)
    "정규화로 표기차 흡수" "Yes"
    (H.majority_vote [ "Yes"; "yes "; "no" ])

let test_majority_singleton () =
  Alcotest.(check string) "1개" "only" (H.majority_vote [ "only" ])

let test_majority_not_first () =
  (* 다수결이 첫 원소가 아닌 케이스 — List.hd 스텁을 잡는 결정적 테스트.
     "no"가 첫 원소지만 "yes"가 2표라 다수결은 "yes". *)
  Alcotest.(check string)
    "다수결은 첫 원소가 아님" "yes"
    (H.majority_vote [ "no"; "yes"; "yes" ])

let test_majority_last_wins () =
  (* 최빈이 마지막에 몰린 케이스 — first/hd 편향을 추가로 배제. *)
  Alcotest.(check string)
    "후미 최빈" "b"
    (H.majority_vote [ "a"; "b"; "c"; "b"; "b" ])

(* ── 정답 매칭 (채점, 결정론) ── *)

let test_score_match_normalized () =
  Alcotest.(check bool)
    "정규화 매칭(공백/대소문자)" true
    (H.score_answer ~reference:"42" ~answer:" 42 ");
  Alcotest.(check bool)
    "대소문자 무시" true
    (H.score_answer ~reference:"Paris" ~answer:"paris")

let test_score_mismatch () =
  Alcotest.(check bool)
    "다른 답" false
    (H.score_answer ~reference:"42" ~answer:"43")

(* ── 4-way 비교 (delta, 결정론) ── *)

let test_compare_delta () =
  let r st correct = { H.strategy = st; answer = "x"; correct; usage = usage 10 10 } in
  (* fusion 2/2=1.0, self_moa 1/2=0.5, self_consistency 1/2=0.5, single 0/2=0.0 *)
  let results =
    [ r H.Fusion true; r H.Fusion true
    ; r H.Self_moa true; r H.Self_moa false
    ; r H.Self_consistency true; r H.Self_consistency false
    ; r H.Single false; r H.Single false
    ]
  in
  let c = H.compare results in
  Alcotest.(check (float 0.001)) "fusion score" 1.0 (List.assoc H.Fusion c.H.score);
  (* cost_matched = 1.0 - max(0.5, 0.5) = 0.5 *)
  Alcotest.(check (float 0.001)) "cost_matched_delta" 0.5 c.H.cost_matched_delta;
  (* single_delta = 1.0 - 0.0 = 1.0 (참고용, 자명) *)
  Alcotest.(check (float 0.001)) "single_delta" 1.0 c.H.single_delta

let test_compare_cost_ratio () =
  let r st itok = { H.strategy = st; answer = "x"; correct = true; usage = usage itok 0 } in
  (* single 100 토큰, fusion 400 토큰 -> ratio 4.0 *)
  let results = [ r H.Single 100; r H.Fusion 400 ] in
  let c = H.compare results in
  Alcotest.(check (float 0.001)) "single ratio=1" 1.0 (List.assoc H.Single c.H.cost_ratio);
  Alcotest.(check (float 0.001)) "fusion ratio=4" 4.0 (List.assoc H.Fusion c.H.cost_ratio)

let test_compare_fusion_not_better () =
  (* fusion이 cost-matched 대안을 못 이기는 경우: cost_matched_delta <= 0 = 머지 게이트 실패. *)
  let r st correct = { H.strategy = st; answer = "x"; correct; usage = usage 10 10 } in
  let results =
    [ r H.Fusion true; r H.Fusion false (* 0.5 *)
    ; r H.Self_consistency true; r H.Self_consistency true (* 1.0 *)
    ; r H.Single false; r H.Single false
    ]
  in
  let c = H.compare results in
  Alcotest.(check bool)
    "fusion이 self-consistency보다 나쁨 -> delta 음수" true
    (c.H.cost_matched_delta < 0.0)

let () =
  Alcotest.run "fusion_harness_core"
    [ ( "majority_vote"
      , [ Alcotest.test_case "basic" `Quick test_majority_basic
        ; Alcotest.test_case "tie_first" `Quick test_majority_tie_first
        ; Alcotest.test_case "normalize" `Quick test_majority_normalize
        ; Alcotest.test_case "singleton" `Quick test_majority_singleton
        ; Alcotest.test_case "not_first" `Quick test_majority_not_first
        ; Alcotest.test_case "last_wins" `Quick test_majority_last_wins
        ] )
    ; ( "score_answer"
      , [ Alcotest.test_case "match_normalized" `Quick test_score_match_normalized
        ; Alcotest.test_case "mismatch" `Quick test_score_mismatch
        ] )
    ; ( "compare"
      , [ Alcotest.test_case "delta" `Quick test_compare_delta
        ; Alcotest.test_case "cost_ratio" `Quick test_compare_cost_ratio
        ; Alcotest.test_case "fusion_not_better" `Quick test_compare_fusion_not_better
        ] )
    ]
