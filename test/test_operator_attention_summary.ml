open Alcotest
module Reason = Masc.Keeper_attention_reason

let summary ~reason ~runtime_blocker_summary =
  Operator_digest.keeper_attention_summary ~name:"lane-smith" ~reason
    ~runtime_blocker_summary

(* The row carries what differs between rows: the Keeper and the reason. *)
let test_a_row_says_which_keeper_and_why () =
  check string "the keeper and its reason" "lane-smith: paused"
    (summary ~reason:Reason.Paused ~runtime_blocker_summary:None)

(* The blocker summary is the second half of the same answer: why the runtime
   cannot proceed, beside the reason the Keeper was flagged. *)
let test_a_blocker_summary_follows_the_reason () =
  check string "both readings, the reason first"
    "lane-smith: runtime_blocked (every candidate refused)"
    (summary ~reason:Reason.Runtime_blocked
       ~runtime_blocker_summary:(Some "every candidate refused"))

let () =
  run "operator attention summary"
    [ ( "what a row says"
      , [ test_case "a row says which keeper and why" `Quick
            test_a_row_says_which_keeper_and_why
        ; test_case "a blocker summary follows the reason" `Quick
            test_a_blocker_summary_follows_the_reason
        ] )
    ]
