(** Unit tests for source-bound Keeper compaction windows. *)

open Masc
module C = Keeper_compaction_llm_summarizer
module S = Keeper_structured_output_schema
module T = Agent_core.Types
module U = Keeper_compaction_unit

let message ?name ?tool_call_id ?(metadata = []) role content : T.message =
  { role; content; name; tool_call_id; metadata }
;;

let text role value = message role [ T.Text value ]
let ordinary value = U.Ordinary_message value

let tool_use id =
  T.ToolUse { id; name = "test_tool"; input = `Assoc [ "source", `String id ] }
;;

let tool_result id =
  T.ToolResult
    { tool_use_id = id
    ; content = "result:" ^ id
    ; outcome = T.Tool_succeeded
    ; json = Some (`Assoc [ "result_id", `String id ])
    ; content_blocks = None
    }
;;

let closed_cycle id =
  U.Closed_tool_cycle
    [ message
        ~metadata:[ "private-cycle-metadata", `String id ]
        T.Assistant
        [ T.Thinking { content = "private-thinking:" ^ id; signature = None }
        ; tool_use id
        ]
    ; message T.Tool [ tool_result id ]
    ; text T.Assistant ("final:" ^ id)
    ]
;;

let media_cycle id =
  U.Closed_tool_cycle
    [ message T.Assistant [ tool_use id ]
    ; message T.Tool
        [ T.ToolResult
            { tool_use_id = id
            ; content = "binary"
            ; outcome = T.Tool_succeeded
            ; json = None
            ; content_blocks =
                Some
                  [ T.Image
                      { media_type = "image/png"
                      ; data = "SECRET_BINARY"
                      ; source_type = T.Base64
                      }
                  ]
            }
        ]
    ]
;;

let window units =
  match C.For_testing.planning_window_for_units units with
  | Ok window -> window
  | Error detail -> Alcotest.failf "planning window rejected: %s" detail
;;

let plan_json ~summary ~keep_from_unit_index =
  `Assoc
    [ S.compaction_plan_field_summary, `String summary
    ; S.compaction_plan_field_keep_from_unit_index, `Int keep_from_unit_index
    ]
;;

let plan window ~summary ~keep_from_unit_index =
  match C.plan_of_json ~window (plan_json ~summary ~keep_from_unit_index) with
  | Ok plan -> plan
  | Error detail -> Alcotest.failf "boundary plan rejected: %s" detail
;;

let wire_of_window window =
  C.For_testing.messages_for_plan ~window
  |> List.map T.text_of_message
  |> String.concat "\n"
;;

let test_oldest_contiguous_typed_window () =
  let units =
    [ ordinary (text T.System "system")
    ; ordinary (text T.User "goal")
    ; ordinary (text T.User "later-user-state")
    ; ordinary
        (message T.Assistant
           [ T.Thinking { content = "private"; signature = None }
           ; T.Text "old-assistant"
           ])
    ; closed_cycle "old-tool"
    ; ordinary
        (message
           ~metadata:[ "producer", `String "exact" ]
           T.Assistant
           [ T.Text "barrier" ])
    ; ordinary (text T.Assistant "later-run")
    ]
  in
  let planning_window = window units in
  Alcotest.(check (list int))
    "only the oldest contiguous eligible run enters planning"
    [ 2; 3; 4 ]
    (C.For_testing.planning_window_source_indices planning_window);
  Alcotest.(check bool) "a lone first User goal stays exact" false
    (C.has_eligible_units [ ordinary (text T.User "goal") ]);
  let wire = wire_of_window planning_window in
  Alcotest.(check bool) "later User state crosses the typed window" true
    (Astring.String.is_infix ~affix:"later-user-state" wire);
  Alcotest.(check bool) "later User role stays explicit" true
    (Astring.String.is_infix ~affix:{|"role":"user"|} wire)
;;

let test_media_and_unseen_tail_stay_outside () =
  let units =
    [ ordinary (text T.System "system")
    ; ordinary (text T.User "goal")
    ; ordinary (text T.Assistant "visible-oldest")
    ; media_cycle "media"
    ; ordinary (text T.Assistant "UNSEEN_LATER_TAIL")
    ]
  in
  let planning_window = window units in
  Alcotest.(check (list int))
    "media starts an exact protected boundary"
    [ 2 ]
    (C.For_testing.planning_window_source_indices planning_window);
  let wire = wire_of_window planning_window in
  Alcotest.(check bool) "oldest source crosses boundary" true
    (Astring.String.is_infix ~affix:"visible-oldest" wire);
  Alcotest.(check bool) "media bytes stay private" false
    (Astring.String.is_infix ~affix:"SECRET_BINARY" wire);
  Alcotest.(check bool) "unseen tail stays outside request" false
    (Astring.String.is_infix ~affix:"UNSEEN_LATER_TAIL" wire)
;;

let test_tool_cycle_semantics_cross_without_private_reasoning () =
  let planning_window =
    window
      [ ordinary (text T.System "system")
      ; ordinary (text T.User "goal")
      ; closed_cycle "cycle"
      ]
  in
  let wire = wire_of_window planning_window in
  List.iter
    (fun expected ->
       Alcotest.(check bool) (expected ^ " crosses typed boundary") true
         (Astring.String.is_infix ~affix:expected wire))
    [ "test_tool"; "result:cycle"; "final:cycle" ];
  List.iter
    (fun private_value ->
       Alcotest.(check bool) (private_value ^ " remains private") false
         (Astring.String.is_infix ~affix:private_value wire))
    [ "private-thinking:cycle"; "private-cycle-metadata" ]
;;

let test_boundary_plan_validation_is_constant_size () =
  let planning_window =
    window
      [ ordinary (text T.System "system")
      ; ordinary (text T.User "goal")
      ; ordinary (text T.Assistant "old-assistant")
      ; closed_cycle "old-cycle"
      ; ordinary (text T.Assistant "tail")
      ]
  in
  let valid = plan planning_window ~summary:"faithful memory" ~keep_from_unit_index:4 in
  Alcotest.(check (list int))
    "boundary summarizes a prefix without enumeration"
    [ 2; 3 ]
    (C.summarized_indices valid);
  Alcotest.(check (list int)) "boundary drops no implicit units" []
    (C.dropped_indices valid);
  let request_wire = wire_of_window planning_window in
  Alcotest.(check bool) "model is asked for the latest faithful boundary" true
    (Astring.String.is_infix ~affix:"latest boundary" request_wire);
  Alcotest.(check bool) "exact suffix is explicitly minimal" true
    (Astring.String.is_infix ~affix:"minimal recent suffix" request_wire);
  let invalid =
    [ plan_json ~summary:"" ~keep_from_unit_index:4
    ; plan_json ~summary:"x" ~keep_from_unit_index:2
    ; plan_json ~summary:"x" ~keep_from_unit_index:6
    ; `Assoc
        [ S.compaction_plan_field_summary, `String "x"
        ; S.compaction_plan_field_keep_from_unit_index, `Int 4
        ; "unexpected", `Null
        ]
    ; `Assoc
        [ S.compaction_plan_field_summary, `String "x"
        ; S.compaction_plan_field_summary, `String "duplicate"
        ; S.compaction_plan_field_keep_from_unit_index, `Int 4
        ]
    ]
  in
  List.iter
    (fun json ->
       Alcotest.(check bool) "invalid boundary is rejected" true
         (Result.is_error (C.plan_of_json ~window:planning_window json)))
    invalid;
  let json = plan_json ~summary:"memory" ~keep_from_unit_index:4 in
  Alcotest.(check bool) "wire output has no per-unit decisions" false
    (Astring.String.is_infix ~affix:"decisions" (Yojson.Safe.to_string json));
  Alcotest.(check bool) "wire output remains constant-size" true
    (String.length (Yojson.Safe.to_string json) < 200)
;;

let test_apply_preserves_exact_outside_state_and_cycle () =
  let system = text T.System "system" in
  let goal = text T.User "goal" in
  let old_user = text T.User "old-user-state" in
  let old_assistant = text T.Assistant "old-assistant" in
  let cycle = closed_cycle "cycle" in
  let exact_tail =
    message
      ~metadata:[ "producer", `String "exact" ]
      T.Assistant
      [ T.Text "exact-tail" ]
  in
  let units =
    [ ordinary system
    ; ordinary goal
    ; ordinary old_user
    ; ordinary old_assistant
    ; cycle
    ; ordinary exact_tail
    ]
  in
  let compacted =
    C.apply
      (plan (window units) ~summary:"old state summary" ~keep_from_unit_index:4)
  in
  let cycle_messages =
    match cycle with
    | U.Closed_tool_cycle messages -> messages
    | U.Ordinary_message _ -> Alcotest.fail "expected closed cycle"
  in
  match compacted with
  | system' :: goal' :: summary :: rest ->
    Alcotest.(check bool) "system stays exact" true (system' = system);
    Alcotest.(check bool) "User goal stays exact" true (goal' = goal);
    Alcotest.(check bool)
      "summary is explicit derived state"
      true
      (summary.role = T.Assistant
       && T.text_of_message summary = "old state summary"
       && summary.metadata
          = [ "masc.compaction.bounded_summary", `Bool true ]);
    Alcotest.(check bool)
      "kept cycle and protected tail stay byte-identical"
      true
      (rest = cycle_messages @ [ exact_tail ])
  | _ -> Alcotest.fail "boundary application changed protected source shape"
;;

let test_whole_tool_cycle_is_summarized_atomically () =
  let units =
    [ ordinary (text T.System "system")
    ; ordinary (text T.User "goal")
    ; ordinary (text T.User "old-user-state")
    ; ordinary (text T.Assistant "old-assistant")
    ; closed_cycle "cycle"
    ; ordinary (text T.Assistant "tail")
    ]
  in
  let compacted_plan =
    plan (window units) ~summary:"cycle result retained" ~keep_from_unit_index:5
  in
  Alcotest.(check (list int))
    "the complete tool cycle is summarized before one exact suffix"
    [ 2; 3; 4 ]
    (C.summarized_indices compacted_plan);
  Alcotest.(check int)
    "one summary replaces assistant plus complete cycle and keeps the tail"
    4
    (List.length (C.apply compacted_plan))
;;

let test_plan_must_leave_a_future_rolling_source () =
  let planning_window =
    window
      [ ordinary (text T.Assistant "oldest")
      ; ordinary (text T.Assistant "newest")
      ]
  in
  Alcotest.(check bool)
    "the terminal source cannot be swallowed without a later rolling source"
    true
    (Result.is_error
       (C.plan_of_json
          ~window:planning_window
          (plan_json ~summary:"all gone" ~keep_from_unit_index:2)));
  Alcotest.(check bool)
    "keeping the newest exact source remains valid"
    true
    (Result.is_ok
       (C.plan_of_json
          ~window:planning_window
          (plan_json ~summary:"bounded" ~keep_from_unit_index:1)))
;;

let test_derived_summary_folds_hierarchically () =
  let units =
    [ ordinary (text T.System "system")
    ; ordinary (text T.User "goal")
    ; ordinary (text T.Assistant "old-a")
    ; ordinary (text T.Assistant "old-b")
    ; ordinary
        (message
           ~metadata:[ "protected", `Bool true ]
           T.Assistant
           [ T.Text "barrier" ])
    ; ordinary (text T.User "next-user-state")
    ; ordinary (text T.Assistant "next-run")
    ]
  in
  let first =
    plan (window units) ~summary:"already compacted" ~keep_from_unit_index:4
    |> C.apply
  in
  match U.partition first with
  | Error _ -> Alcotest.fail "compacted messages lost structural validity"
  | Ok partition ->
    let next = window partition.closed_prefix in
    let wire = wire_of_window next in
    Alcotest.(check bool) "derived summary re-enters as prior memory" true
      (Astring.String.is_infix ~affix:"already compacted" wire);
    Alcotest.(check bool) "later User state enters the next window" true
      (Astring.String.is_infix ~affix:"next-user-state" wire);
    Alcotest.(check bool) "later run becomes the next window" true
      (Astring.String.is_infix ~affix:"next-run" wire);
    let folded =
      C.apply
        (plan next ~summary:"one rolling memory" ~keep_from_unit_index:5)
    in
    let summaries =
      List.filter
        (fun (message : T.message) ->
           message.metadata
           = [ "masc.compaction.bounded_summary", `Bool true ])
        folded
    in
    Alcotest.(check int) "hierarchical fold keeps one summary" 1
      (List.length summaries);
    Alcotest.(check bool) "old summary is replaced" false
      (List.exists
         (fun message -> T.text_of_message message = "already compacted")
         folded);
    Alcotest.(check bool) "new rolling summary is installed" true
      (List.exists
         (fun message -> T.text_of_message message = "one rolling memory")
         folded);
    Alcotest.(check bool) "protected barrier stays exact" true
      (List.exists
         (fun message -> T.text_of_message message = "barrier")
         folded)
;;

(* #26420 regression. A checkpoint that has already been compacted carries its
   summary right behind the leading User message, because the first User message
   is held out of the selection. Making that message selectable puts an eligible
   source in front of the summary, which [planning_window_for_units] rejects
   outright -- so an already-compacted checkpoint could never be compacted
   again. Six of eleven live keeper checkpoints took that shape on 2026-07-30;
   their windows went from 85-98% of the transcript to a hard error. Any change
   to selection eligibility has to keep this layout planable. *)
let test_summary_behind_leading_user_message_still_plans () =
  let units =
    [ ordinary
        (text
           T.User
           "(autonomous wake — the current observation frame is provided per-turn in \
            system context)")
    ; ordinary
        (message
           ~metadata:[ "masc.compaction.bounded_summary", `Bool true ]
           T.Assistant
           [ T.Text "already compacted" ])
    ; ordinary (text T.Assistant "post-summary-one")
    ; ordinary (text T.Assistant "post-summary-two")
    ]
  in
  match C.For_testing.planning_window_for_units units with
  | Error message ->
    Alcotest.failf "an already-compacted checkpoint lost its window: %s" message
  | Ok window ->
    Alcotest.(check (list int))
      "the window resumes after the prior summary"
      [ 2; 3 ]
      (C.For_testing.planning_window_source_indices window)
;;

let test_multiple_current_summaries_are_rejected () =
  let summary value =
    ordinary
      (message
         ~metadata:[ "masc.compaction.bounded_summary", `Bool true ]
         T.Assistant
         [ T.Text value ])
  in
  let units =
    [ ordinary (text T.System "system")
    ; ordinary (text T.User "goal")
    ; summary "first"
    ; summary "second"
    ; ordinary (text T.Assistant "raw")
    ]
  in
  Alcotest.(check bool) "ambiguous rolling-summary state fails closed" true
    (Result.is_error (C.For_testing.planning_window_for_units units))
;;

let test_open_cycle_remains_protected () =
  let open_messages =
    [ message T.Assistant
        [ T.Thinking { content = "OPEN_PRIVATE"; signature = None }
        ; tool_use "OPEN_TOOL"
        ]
    ]
  in
  match U.partition open_messages with
  | Error _ -> Alcotest.fail "valid open cycle was structurally rejected"
  | Ok partition ->
    Alcotest.(check bool) "open prefix has no eligible units" false
      (C.has_eligible_units partition.closed_prefix);
    Alcotest.(check bool) "open cycle remains exact protected suffix" true
      (partition.protected_suffix = open_messages)
;;

let () =
  Alcotest.run
    "compaction_llm_summarizer"
    [ ( "window"
      , [ Alcotest.test_case "oldest contiguous typed run" `Quick
            test_oldest_contiguous_typed_window
        ; Alcotest.test_case "media and unseen tail stay outside" `Quick
            test_media_and_unseen_tail_stay_outside
        ; Alcotest.test_case "tool semantics omit private reasoning" `Quick
            test_tool_cycle_semantics_cross_without_private_reasoning
        ; Alcotest.test_case "open cycle remains protected" `Quick
            test_open_cycle_remains_protected
        ] )
    ; ( "plan"
      , [ Alcotest.test_case "constant-size boundary validation" `Quick
            test_boundary_plan_validation_is_constant_size
        ; Alcotest.test_case "apply preserves exact outside state" `Quick
            test_apply_preserves_exact_outside_state_and_cycle
        ; Alcotest.test_case "tool cycle is summarized atomically" `Quick
            test_whole_tool_cycle_is_summarized_atomically
        ; Alcotest.test_case "plan leaves a future rolling source" `Quick
            test_plan_must_leave_a_future_rolling_source
        ; Alcotest.test_case "derived summary folds hierarchically" `Quick
            test_derived_summary_folds_hierarchically
        ; Alcotest.test_case "multiple current summaries are rejected" `Quick
            test_multiple_current_summaries_are_rejected
        ; Alcotest.test_case "summary behind a leading User message still plans"
            `Quick
            test_summary_behind_leading_user_message_still_plans
        ] )
    ]
;;
