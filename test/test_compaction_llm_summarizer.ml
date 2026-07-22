(** Unit tests for the source-bound Keeper compaction planner. *)

open Masc
module C = Keeper_compaction_llm_summarizer
module Compact_policy = Keeper_compact_policy
module S = Keeper_structured_output_schema
module T = Agent_sdk.Types
module U = Keeper_compaction_unit

let plan_of_json ~units json = C.plan_of_json ~units json

let decision ?summary unit_index action : Yojson.Safe.t =
  `Assoc
    [ S.compaction_plan_field_unit_index, `Int unit_index
    ; S.compaction_plan_field_action, `String action
    ; S.compaction_plan_field_summary, Option.fold ~none:`Null ~some:(fun value -> `String value) summary
    ]

let plan_json decisions : Yojson.Safe.t =
  `Assoc [ S.compaction_plan_field_decisions, `List decisions ]

let keep unit_index = decision unit_index S.compaction_plan_action_keep
let drop unit_index = decision unit_index S.compaction_plan_action_drop
let summarize unit_index summary =
  decision ~summary unit_index S.compaction_plan_action_summarize

let is_ok = function Ok _ -> true | Error _ -> false
let is_error = function Ok _ -> false | Error _ -> true

let message ?name ?tool_call_id ?(metadata = []) role content : T.message =
  { role; content; name; tool_call_id; metadata }

let text role value = message role [ T.Text value ]
let ordinary message = U.Ordinary_message message

let tool_use id =
  T.ToolUse { id; name = "test_tool"; input = `Assoc [ "secret", `String id ] }

let tool_result id =
  T.ToolResult
    { tool_use_id = id
    ; content = "result:" ^ id
    ; outcome = T.Tool_succeeded
    ; json = None
    ; content_blocks = None
    }

let closed_cycle id =
  U.Closed_tool_cycle
    [ message T.Assistant [ tool_use id ]
    ; message T.Tool [ tool_result id ]
    ]

let eligibility_units =
  [ ordinary (text T.System "system")
  ; ordinary (text T.User "user")
  ; ordinary (text T.Tool "tool")
  ; ordinary (text T.Assistant "eligible")
  ; ordinary (text T.Assistant "   ")
  ; ordinary (message T.Assistant [ T.Text "text"; T.RedactedThinking "opaque" ])
  ; ordinary (message ~name:"named" T.Assistant [ T.Text "named" ])
  ; ordinary (message ~tool_call_id:"call" T.Assistant [ T.Text "linked" ])
  ; ordinary (message ~metadata:[ "source", `String "producer" ] T.Assistant [ T.Text "meta" ])
  ; closed_cycle "closed"
  ]

let test_only_plain_assistant_text_is_eligible () =
  Alcotest.(check bool) "mixed source has eligible text" true
    (C.has_eligible_units eligibility_units);
  List.iteri
    (fun index unit_ ->
      Alcotest.(check bool)
        (Printf.sprintf "unit %d eligibility" index)
        (index = 3)
        (C.has_eligible_units [ unit_ ]))
    eligibility_units

let validation_units =
  [ ordinary (text T.System "protected-system")
  ; ordinary (text T.Assistant "first")
  ; closed_cycle "protected-cycle"
  ; ordinary (text T.User "protected-user")
  ; ordinary (text T.Assistant "second")
  ]

let test_valid_source_decisions_accepted () =
  let result =
    plan_of_json
      ~units:validation_units
      (plan_json [ summarize 1 "first summary"; keep 4 ])
  in
  match result with
  | Error detail -> Alcotest.failf "valid source-bound plan rejected: %s" detail
  | Ok plan ->
    Alcotest.(check (list int)) "summarized source index" [ 1 ]
      (C.summarized_indices plan);
    Alcotest.(check (list int)) "nothing dropped" [] (C.dropped_indices plan)

let test_all_kept_rejected () =
  Alcotest.(check bool) "all-kept is not compaction" true
    (is_error
       (plan_of_json ~units:validation_units (plan_json [ keep 1; keep 4 ])))

let test_drop_with_kept_accepted () =
  Alcotest.(check bool) "drop plus keep is a valid change" true
    (is_ok
       (plan_of_json ~units:validation_units (plan_json [ drop 1; keep 4 ])))

let test_protected_index_rejected () =
  Alcotest.(check bool) "provider cannot target protected source index" true
    (is_error
       (plan_of_json ~units:validation_units (plan_json [ summarize 0 "x"; keep 4 ])))

let test_missing_eligible_index_rejected () =
  Alcotest.(check bool) "every eligible source needs a decision" true
    (is_error
       (plan_of_json ~units:validation_units (plan_json [ summarize 1 "x" ])))

let test_duplicate_index_rejected () =
  Alcotest.(check bool) "duplicate source decision rejected" true
    (is_error
       (plan_of_json
          ~units:validation_units
          (plan_json [ summarize 1 "x"; drop 1; keep 4 ])))

let test_all_dropped_rejected () =
  Alcotest.(check bool) "planner cannot remove every eligible unit" true
    (is_error
       (plan_of_json ~units:validation_units (plan_json [ drop 1; drop 4 ])))

let test_action_summary_contract_rejected () =
  let invalid =
    [ decision ~summary:"unexpected" 1 S.compaction_plan_action_keep
    ; decision ~summary:"unexpected" 1 S.compaction_plan_action_drop
    ; decision 1 S.compaction_plan_action_summarize
    ; summarize 1 "   "
    ; decision 1 "unknown-action"
    ]
  in
  List.iter
    (fun invalid_decision ->
      Alcotest.(check bool) "invalid action/summary pair" true
        (is_error
           (plan_of_json
              ~units:validation_units
              (plan_json [ invalid_decision; keep 4 ]))))
    invalid

let test_unknown_and_duplicate_fields_rejected () =
  let unknown_top =
    `Assoc
      [ S.compaction_plan_field_decisions, `List [ summarize 1 "x"; keep 4 ]
      ; "unexpected", `Null
      ]
  in
  let duplicate_top =
    `Assoc
      [ S.compaction_plan_field_decisions, `List [ summarize 1 "x"; keep 4 ]
      ; S.compaction_plan_field_decisions, `List []
      ]
  in
  let unknown_decision =
    `Assoc
      [ S.compaction_plan_field_unit_index, `Int 1
      ; S.compaction_plan_field_action, `String S.compaction_plan_action_summarize
      ; S.compaction_plan_field_summary, `String "x"
      ; "unexpected", `Null
      ]
  in
  let duplicate_decision =
    `Assoc
      [ S.compaction_plan_field_unit_index, `Int 1
      ; S.compaction_plan_field_unit_index, `Int 1
      ; S.compaction_plan_field_action, `String S.compaction_plan_action_summarize
      ; S.compaction_plan_field_summary, `String "x"
      ]
  in
  List.iter
    (fun json ->
      Alcotest.(check bool) "non-canonical object rejected" true
        (is_error (plan_of_json ~units:validation_units json)))
    [ `Assoc []
    ; unknown_top
    ; duplicate_top
    ; plan_json [ unknown_decision; keep 4 ]
    ; plan_json [ duplicate_decision; keep 4 ]
    ]

let test_request_excludes_protected_content () =
  let units =
    [ ordinary (text T.System "SECRET_SYSTEM")
    ; ordinary (text T.User "SECRET_USER")
    ; closed_cycle "SECRET_TOOL"
    ; ordinary
        (message T.Assistant
           [ T.Text "SECRET_MIXED"; T.Thinking { content = "SECRET_THINKING"; signature = None } ])
    ; ordinary
        (message ~metadata:[ "secret", `Bool true ] T.Assistant [ T.Text "SECRET_METADATA" ])
    ; ordinary (text T.Assistant "VISIBLE_ASSISTANT")
    ]
  in
  let request = C.For_testing.messages_for_plan ~units in
  let wire = request |> List.map T.text_of_message |> String.concat "\n" in
  Alcotest.(check bool) "eligible assistant text crosses boundary" true
    (Astring.String.is_infix ~affix:"VISIBLE_ASSISTANT" wire);
  List.iter
    (fun secret ->
      Alcotest.(check bool) (secret ^ " remains private") false
        (Astring.String.is_infix ~affix:secret wire))
    [ "SECRET_SYSTEM"
    ; "SECRET_USER"
    ; "SECRET_TOOL"
    ; "SECRET_MIXED"
    ; "SECRET_THINKING"
    ; "SECRET_METADATA"
    ]

let test_apply_preserves_protected_units_and_source_order () =
  let system = text T.System "system" in
  let first = text T.Assistant "first" in
  let cycle = closed_cycle "cycle" in
  let user = text T.User "user" in
  let metadata_assistant =
    message ~metadata:[ "producer", `String "exact" ] T.Assistant [ T.Text "metadata" ]
  in
  let second = text T.Assistant "second" in
  let thinking =
    message T.Assistant
      [ T.Thinking { content = "private"; signature = Some "signed" } ]
  in
  let units =
    [ ordinary system
    ; ordinary first
    ; cycle
    ; ordinary user
    ; ordinary metadata_assistant
    ; ordinary second
    ; ordinary thinking
    ]
  in
  match
    plan_of_json
      ~units
      (plan_json [ summarize 1 "first summary"; summarize 5 "second summary" ])
  with
  | Error detail -> Alcotest.failf "expected valid plan: %s" detail
  | Ok plan ->
    let summary =
      { first with content = [ T.Text "first summary" ] }
    in
    let second_summary =
      { second with content = [ T.Text "second summary" ] }
    in
    let expected =
      [ system; summary ]
      @ (match cycle with U.Closed_tool_cycle messages -> messages | Ordinary_message _ -> [])
      @ [ user; metadata_assistant; second_summary; thinking ]
    in
    Alcotest.(check bool) "protected source constructors and order are exact" true
      (C.apply plan = expected)

let () =
  Alcotest.run "compaction_llm_summarizer"
    [ ( "eligibility"
      , [ Alcotest.test_case "plain Assistant text only" `Quick
            test_only_plain_assistant_text_is_eligible
        ; Alcotest.test_case "protected content never reaches exact boundary" `Quick
            test_request_excludes_protected_content
        ] )
    ; ( "plan_of_json"
      , [ Alcotest.test_case "valid source decisions accepted" `Quick
            test_valid_source_decisions_accepted
        ; Alcotest.test_case "all kept rejected" `Quick test_all_kept_rejected
        ; Alcotest.test_case "drop with kept accepted" `Quick
            test_drop_with_kept_accepted
        ; Alcotest.test_case "protected index rejected" `Quick
            test_protected_index_rejected
        ; Alcotest.test_case "missing eligible index rejected" `Quick
            test_missing_eligible_index_rejected
        ; Alcotest.test_case "duplicate index rejected" `Quick
            test_duplicate_index_rejected
        ; Alcotest.test_case "all dropped rejected" `Quick test_all_dropped_rejected
        ; Alcotest.test_case "action summary contract rejected" `Quick
            test_action_summary_contract_rejected
        ; Alcotest.test_case "unknown and duplicate fields rejected" `Quick
            test_unknown_and_duplicate_fields_rejected
        ] )
    ; ( "apply"
      , [ Alcotest.test_case "protected units and source order stay exact" `Quick
            test_apply_preserves_protected_units_and_source_order
        ] )
    ]
