(** Regression tests for the live OAS checkpoint replay contract.

    These tests deliberately exercise typed checkpoint messages. Retired
    model-authored prose state is not a checkpoint authority. *)

module Finalize = Masc.Keeper_agent_run_finalize_response.For_testing
module Receipt = Masc.Keeper_execution_receipt
module Replay_prefix = Masc.Keeper_replay_prefix

let message role content =
  Agent_sdk.Types.{ role; content; name = None; tool_call_id = None; metadata = [] }
;;

let checkpoint ?(working_context = Some (`Assoc [])) messages =
  Agent_sdk.Checkpoint.
    { version = checkpoint_version
    ; session_id = "old-session"
    ; agent_name = "test-agent"
    ; model = "test-model"
    ; system_prompt = Some "system"
    ; messages
    ; usage = Agent_sdk.Types.empty_usage
    ; turn_count = 1
    ; created_at = 1_000.0
    ; tools = []
    ; tool_choice = None
    ; disable_parallel_tool_use = false
    ; temperature = None
    ; top_p = None
    ; top_k = None
    ; min_p = None
    ; reasoning_effort = None
    ; enable_thinking = None
    ; preserve_thinking = None
    ; response_format = Agent_sdk.Types.Off
    ; thinking_budget = None
    ; cache_system_prompt = false
    ; context = Agent_sdk.Context.create_sync ()
    ; mcp_sessions = []
    ; working_context
  }

let input_required_request () : Agent_sdk.Error.input_required =
  { request_id = "recovery-input-1"
  ; participant_name = Some "operator"
  ; question = "Which repository should I inspect?"
  ; schema = Some (`Assoc [ "type", `String "string" ])
  ; timeout_s = None
  ; created_at = 1_000.0
  }
;;

let expect_ok = function
  | Ok value -> value
  | Error detail -> Alcotest.fail detail
;;

let prune_reason_to_string =
  Option.map Finalize.replay_suffix_prune_reason_to_string
;;

let text_of_last_assistant messages =
  messages
  |> List.rev
  |> List.find_opt (fun (msg : Agent_sdk.Types.message) ->
    msg.role = Agent_sdk.Types.Assistant)
  |> Option.map Agent_sdk.Types.text_of_message
;;

let has_content predicate messages =
  List.exists
    (fun (msg : Agent_sdk.Types.message) -> List.exists predicate msg.content)
    messages
;;

let rec remove_tree path =
  if Sys.is_directory path
  then (
    Sys.readdir path
    |> Array.iter (fun name -> remove_tree (Filename.concat path name));
    Unix.rmdir path)
  else Unix.unlink path
;;

let with_temp_dir f =
  let dir = Filename.temp_dir "keeper-replay-projection-" "" in
  Fun.protect ~finally:(fun () -> remove_tree dir) (fun () -> f dir)
;;

let test_patch_last_assistant_preserves_typed_reasoning () =
  let open Agent_sdk.Types in
  let cp =
    checkpoint
      [ message User [ Text "question" ]
      ; message Assistant
          [ Thinking { signature = Some "sig"; content = "reasoning" }
          ; Text "draft"
          ]
      ]
  in
  let patched =
    Masc.Keeper_context_core.patch_checkpoint_last_assistant
      cp
      ~session_id:"new-session"
      ~response_text:"final"
  in
  Alcotest.(check string) "session unified" "new-session" patched.session_id;
  Alcotest.(check bool) "working context cleared" true
    (patched.working_context = None);
  Alcotest.(check (option string)) "visible text patched" (Some "final")
    (text_of_last_assistant patched.messages);
  Alcotest.(check bool) "thinking preserved" true
    (has_content (function Thinking _ -> true | _ -> false) patched.messages)
;;

let test_contract_observation_preserves_current_turn_suffix () =
  let open Agent_sdk.Types in
  let history =
    [ message User [ Text "old user" ]; message Assistant [ Text "old answer" ] ]
  in
  let current_turn =
    [ message User [ Text "current user" ]
    ; message Assistant
        [ ToolUse { id = "tool-1"; name = "keeper_context_status"; input = `Assoc [] } ]
    ; message Tool
        [ ToolResult
            { tool_use_id = "tool-1"
            ; content = "status"
            ; outcome = Tool_succeeded
            ; json = None
            ; content_blocks = None
            }
        ]
    ; message Assistant [ Text "" ]
    ]
  in
  let patched, reason =
    Finalize.checkpoint_for_replay_persistence
      ~history_messages:history
      ~pre_turn_working_context:(Some (`Assoc [ "pre_turn", `Bool true ]))
      ~completion_contract_result:Receipt.Completion_no_visible_output
      ~session_id:"new-session"
      ~response_text:"visible result"
      (checkpoint (history @ current_turn))
    |> expect_ok
  in
  Alcotest.(check int) "current typed replay remains" 6
    (List.length patched.messages);
  Alcotest.(check (option string)) "visible assistant text retained"
    (Some "visible result")
    (text_of_last_assistant patched.messages);
  Alcotest.(check bool) "canonical replay clears working context" true
    (patched.working_context = None);
  Alcotest.(check (option string)) "canonical replay reason"
    (Some "canonical_success_replay")
    (prune_reason_to_string reason)
;;

let test_contract_observation_rejects_mismatched_history_prefix () =
  let open Agent_sdk.Types in
  let expected_history =
    [ message User [ Text "expected" ]; message Assistant [ Text "old answer" ] ]
  in
  let actual_history =
    [ message User [ Text "actual" ]; message Assistant [ Text "old answer" ] ]
  in
  match
    Finalize.checkpoint_for_replay_persistence
      ~history_messages:expected_history
      ~pre_turn_working_context:None
      ~completion_contract_result:Receipt.Completion_no_visible_output
      ~session_id:"new-session"
      ~response_text:"suppressed"
      (checkpoint (actual_history @ [ message Assistant [ Text "" ] ]))
  with
  | Ok _ -> Alcotest.fail "mismatched replay prefix was accepted"
  | Error detail ->
    Alcotest.(check bool) "failure is explicit" true
      (String.trim detail <> "")
;;

let test_success_preserves_typed_replay_suffix () =
  let open Agent_sdk.Types in
  let history =
    [ message User [ Text "old user" ]; message Assistant [ Text "old answer" ] ]
  in
  let current_turn =
    [ message User [ Text "current user" ]
    ; message Assistant
        [ Thinking { signature = None; content = "think before tool" }
        ; ToolUse { id = "tool-1"; name = "keeper_context_status"; input = `Assoc [] }
        ]
    ; message Tool
        [ ToolResult
            { tool_use_id = "tool-1"
            ; content = "status"
            ; outcome = Tool_succeeded
            ; json = None
            ; content_blocks = None
            }
        ]
    ; message Assistant
        [ Thinking { signature = Some "final-sig"; content = "final reasoning" }
        ; Text "draft"
        ]
    ]
  in
  let patched, reason =
    Finalize.checkpoint_for_replay_persistence
      ~history_messages:history
      ~pre_turn_working_context:None
      ~completion_contract_result:Receipt.Completion_tool_execution_observed
      ~session_id:"new-session"
      ~response_text:"visible answer"
      (checkpoint (history @ current_turn))
    |> expect_ok
  in
  Alcotest.(check int) "full replay retained" 6 (List.length patched.messages);
  Alcotest.(check (option string)) "canonicalization reason"
    (Some "canonical_success_replay")
    (prune_reason_to_string reason);
  Alcotest.(check bool) "thinking remains typed" true
    (has_content (function Thinking _ -> true | _ -> false) patched.messages);
  Alcotest.(check bool) "tool use remains typed" true
    (has_content (function ToolUse _ -> true | _ -> false) patched.messages);
  Alcotest.(check bool) "tool result remains typed" true
    (has_content (function ToolResult _ -> true | _ -> false) patched.messages);
  Alcotest.(check (option string)) "final assistant canonicalized"
    (Some "visible answer")
    (text_of_last_assistant patched.messages);
  Alcotest.(check bool) "working context cleared" true
    (patched.working_context = None)
;;

let test_success_appends_missing_final_assistant () =
  let open Agent_sdk.Types in
  let history =
    [ message User [ Text "old user" ]; message Assistant [ Text "old answer" ] ]
  in
  let patched, _reason =
    Finalize.checkpoint_for_replay_persistence
      ~history_messages:history
      ~pre_turn_working_context:None
      ~completion_contract_result:Receipt.Completion_tool_execution_observed
      ~session_id:"new-session"
      ~response_text:"visible answer"
      (checkpoint (history @ [ message User [ Text "current user" ] ]))
    |> expect_ok
  in
  Alcotest.(check int) "assistant appended" 4 (List.length patched.messages);
  Alcotest.(check (option string)) "appended assistant is visible"
    (Some "visible answer")
    (text_of_last_assistant patched.messages)
;;

let test_empty_success_drops_current_turn_replay () =
  let open Agent_sdk.Types in
  let history =
    [ message User [ Text "old user" ]; message Assistant [ Text "old answer" ] ]
  in
  let patched, reason =
    Finalize.checkpoint_for_replay_persistence
      ~history_messages:history
      ~pre_turn_working_context:(Some (`Assoc [ "pre_turn", `Bool true ]))
      ~completion_contract_result:Receipt.Completion_tool_execution_observed
      ~session_id:"new-session"
      ~response_text:""
      (checkpoint (history @ [ message User [ Text "current user" ] ]))
    |> expect_ok
  in
  Alcotest.(check int) "empty visible result is not replayed" 2
    (List.length patched.messages);
  Alcotest.(check bool) "working context cleared on canonical success" true
    (patched.working_context = None);
  Alcotest.(check (option string)) "canonicalization remains observable"
    (Some "canonical_success_replay")
    (prune_reason_to_string reason)
;;

let test_input_required_preserves_exact_tool_failure_suffix () =
  let open Agent_sdk.Types in
  let history =
    [ message User [ Text "old user" ]; message Assistant [ Text "old answer" ] ]
  in
  let current_turn =
    [ message User [ Text "inspect the source" ]
    ; message Assistant
        [ ToolUse
            { id = "tool-ask-1"
            ; name = "Execute"
            ; input = `Assoc [ "cmd", `String "gh pr list" ]
            }
        ]
    ; message Tool
        [ ToolResult
            { tool_use_id = "tool-ask-1"
            ; content = "working directory is required"
            ; outcome =
                Tool_failed
                  { failure_kind = Validation_error
                  ; error_class = Some Deterministic
                  }
            ; json = None
            ; content_blocks = None
            }
        ]
    ]
  in
  let request = input_required_request () in
  let patched, reason =
    Finalize.checkpoint_for_replay_persistence
      ~history_messages:history
      ~pre_turn_working_context:None
      ~completion_contract_result:Receipt.Completion_observation_unknown
      ~session_id:"new-session"
      ~response_text:request.question
      ~stop_reason:(Runtime_agent.InputRequired { turns_used = 2; request })
      (checkpoint (history @ current_turn))
    |> expect_ok
  in
  Alcotest.(check string) "session unified" "new-session" patched.session_id;
  Alcotest.(check bool)
    "InputRequired replay suffix is structurally unchanged"
    true
    (patched.messages = history @ current_turn);
  Alcotest.(check (option string)) "no prune reason" None
    (prune_reason_to_string reason)
;;

let test_media_degraded_projection_persists_canonical_checkpoint () =
  let open Agent_sdk.Types in
  let canonical_history =
    [ message User
        [ Text "canonical history"
        ; image_block ~media_type:"image/png" ~data:"canonical-image" ()
        ]
    ]
  in
  let dispatch_history = [ message User [ Text "canonical history" ] ] in
  let current_assistant = message Assistant [ Text "completed" ] in
  let projection =
    Replay_prefix.media_degraded
      ~canonical_prefix:canonical_history
      ~dispatch_prefix:dispatch_history
  in
  let restored_checkpoint =
    match
      Replay_prefix.restore_checkpoint
        projection
        (checkpoint ~working_context:None (dispatch_history @ [ current_assistant ]))
    with
    | Ok checkpoint -> checkpoint
    | Error error -> Alcotest.fail (Replay_prefix.restore_error_to_string error)
  in
  let checkpoint_for_save, _reason =
    Finalize.checkpoint_for_replay_persistence
      ~history_messages:canonical_history
      ~pre_turn_working_context:None
      ~completion_contract_result:Receipt.Completion_tool_execution_observed
      ~session_id:"media-projection-session"
      ~response_text:"completed"
      restored_checkpoint
    |> expect_ok
  in
  with_temp_dir (fun session_dir ->
    (match
       Masc.Keeper_checkpoint_store.save_oas_classified
         ~session_dir
         checkpoint_for_save
     with
     | Ok (Masc.Keeper_checkpoint_store.Saved _) -> ()
     | Ok (Masc.Keeper_checkpoint_store.Stale_noop _) ->
       Alcotest.fail "fresh projected checkpoint was classified as stale"
     | Error detail -> Alcotest.fail ("projected checkpoint save failed: " ^ detail));
    match
      Masc.Keeper_checkpoint_store.load_oas
        ~session_dir
        ~session_id:"media-projection-session"
    with
    | Error _ -> Alcotest.fail "persisted projected checkpoint could not be loaded"
    | Ok persisted ->
      Alcotest.(check bool)
        "durable checkpoint keeps canonical media and current assistant suffix"
        true
        (persisted.messages = canonical_history @ [ current_assistant ]))
;;

let () =
  Alcotest.run
    "keeper replay checkpoint"
    [ ( "persistence"
      , [ Alcotest.test_case
            "patch preserves typed reasoning"
            `Quick
            test_patch_last_assistant_preserves_typed_reasoning
        ; Alcotest.test_case
            "contract observation preserves current turn"
            `Quick
            test_contract_observation_preserves_current_turn_suffix
        ; Alcotest.test_case
            "contract observation rejects prefix mismatch"
            `Quick
            test_contract_observation_rejects_mismatched_history_prefix
        ; Alcotest.test_case
            "success preserves typed replay"
            `Quick
            test_success_preserves_typed_replay_suffix
        ; Alcotest.test_case
            "success appends final assistant"
            `Quick
            test_success_appends_missing_final_assistant
        ; Alcotest.test_case
            "empty success drops current turn"
            `Quick
            test_empty_success_drops_current_turn_replay
        ; Alcotest.test_case
            "InputRequired preserves exact tool-failure suffix"
            `Quick
            test_input_required_preserves_exact_tool_failure_suffix
        ; Alcotest.test_case
            "media-degraded projection persists canonical checkpoint"
            `Quick
            test_media_degraded_projection_persists_canonical_checkpoint
        ] )
    ]
;;
