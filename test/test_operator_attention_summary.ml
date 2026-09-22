open Alcotest

let summary ~reason ~runtime_blocker_summary =
  Operator_digest.keeper_attention_summary ~name:"lane-smith" ~reason
    ~runtime_blocker_summary

let contains needle text =
  let text_length = String.length text in
  let needle_length = String.length needle in
  let rec walk index =
    if index + needle_length > text_length then false
    else if String.sub text index needle_length = needle then true
    else walk (index + 1)
  in
  walk 0

(* The row carries what differs between rows: the Keeper and the reason. *)
let test_a_row_says_which_keeper_and_why () =
  check string "the keeper and its reason" "lane-smith: paused"
    (summary ~reason:(Some "paused") ~runtime_blocker_summary:None)

(* The blocker summary is the second half of the same answer: why the runtime
   cannot proceed, beside the reason the Keeper was flagged. *)
let test_a_blocker_summary_follows_the_reason () =
  check string "both readings, the reason first"
    "lane-smith: runtime_blocked (every candidate refused)"
    (summary ~reason:(Some "runtime_blocked")
       ~runtime_blocker_summary:(Some "every candidate refused"))

(* A blocker with no reason of its own keeps the parentheses it has beside a
   reason, so the row still says which reading it is. *)
let test_a_blocker_alone_keeps_its_parentheses () =
  check string "the keeper and its blocker" "lane-smith (keepalive lost)"
    (summary ~reason:None ~runtime_blocker_summary:(Some "keepalive lost"))

(* The two readings never print the same way: "x: paused" is a reason and
   "x (paused)" is a blocker summary. *)
let test_a_reason_and_a_blocker_are_told_apart () =
  let as_reason = summary ~reason:(Some "paused") ~runtime_blocker_summary:None in
  let as_blocker = summary ~reason:None ~runtime_blocker_summary:(Some "paused") in
  check bool
    (Printf.sprintf "%S and %S differ" as_reason as_blocker)
    false
    (String.equal as_reason as_blocker)

(* And where there is neither, the phrase is all the row has to say. *)
let test_a_row_with_nothing_else_keeps_the_phrase () =
  check string "the phrase stands alone"
    "lane-smith needs operator attention"
    (summary ~reason:None ~runtime_blocker_summary:None)

let test_a_row_with_a_reason_does_not_repeat_the_panel () =
  List.iter
    (fun (reason, blocker) ->
      let drawn = summary ~reason ~runtime_blocker_summary:blocker in
      check bool
        (Printf.sprintf "%S does not spell the panel's own title" drawn)
        false
        (contains "needs operator attention" drawn))
    [ (Some "paused", None)
    ; (Some "runtime_blocked", Some "every candidate refused")
    ; (None, Some "keepalive lost")
    ]

let () =
  run "operator attention summary"
    [ ( "what a row says"
      , [ test_case "a row says which keeper and why" `Quick
            test_a_row_says_which_keeper_and_why
        ; test_case "a blocker summary follows the reason" `Quick
            test_a_blocker_summary_follows_the_reason
        ; test_case "a blocker alone keeps its parentheses" `Quick
            test_a_blocker_alone_keeps_its_parentheses
        ; test_case "a reason and a blocker are told apart" `Quick
            test_a_reason_and_a_blocker_are_told_apart
        ; test_case "a row with nothing else keeps the phrase" `Quick
            test_a_row_with_nothing_else_keeps_the_phrase
        ; test_case "a row with a reason does not repeat the panel" `Quick
            test_a_row_with_a_reason_does_not_repeat_the_panel
        ] )
    ]
