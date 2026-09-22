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

(* Every item in this projection needs operator attention, and the panel that
   draws it is titled for that. On the live fleet the Overview's Attention panel
   gives a row forty-one cells for its reading; the phrase spent twenty-seven of
   them, and five of six rows read "<keeper> needs operator attention: paus…" --
   the reason, which is what the operator acts on, was the half that was cut. *)
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

(* A blocker with no reason of its own is still the row's reading. *)
let test_a_blocker_alone_is_the_reading () =
  check string "the keeper and its blocker" "lane-smith: keepalive lost"
    (summary ~reason:None ~runtime_blocker_summary:(Some "keepalive lost"))

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
        ; test_case "a blocker alone is the reading" `Quick
            test_a_blocker_alone_is_the_reading
        ; test_case "a row with nothing else keeps the phrase" `Quick
            test_a_row_with_nothing_else_keeps_the_phrase
        ; test_case "a row with a reason does not repeat the panel" `Quick
            test_a_row_with_a_reason_does_not_repeat_the_panel
        ] )
    ]
