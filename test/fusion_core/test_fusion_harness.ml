(* Fusion 하네스 — self-consistency 다수결 집계 테스트 (결정론).
   채점·전략 우열은 judge(LLM 판단) 몫이라 여기서 검증하지 않는다. *)

module H = Fusion_harness_core

let test_majority_basic () =
  Alcotest.(check string) "최빈 답" "yes" (H.majority_vote [ "yes"; "no"; "yes" ])

let test_majority_tie_first () =
  (* 동률(각 1표)이면 입력에서 먼저 등장한 답. *)
  Alcotest.(check string) "동률 -> 첫 등장" "a" (H.majority_vote [ "a"; "b" ])

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
    ]
