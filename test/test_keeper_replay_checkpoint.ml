(** Regression tests for the live OAS checkpoint replay contract.

    These tests deliberately exercise typed checkpoint messages. A successful
    assistant response is durable conversation state even when the autonomous
    cycle has no external effect. *)

module Finalize = Masc.Keeper_agent_run_finalize_response.For_testing
module Replay_prefix = Masc.Keeper_replay_prefix

let message role content =
  Agent_sdk.Types.{ role; content; name = None; tool_call_id = None; metadata = [] }
;;

let text_of_message = Agent_sdk.Types.text_of_message

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

let test_finalization_reuses_matching_pipeline_checkpoint () =
  let open Agent_sdk.Types in
  let history = [ message User [ Text "question" ] ] in
  let messages = history @ [ message Assistant [ Text "final" ] ] in
  let persisted =
    { (checkpoint ~working_context:None messages) with
      session_id = "new-session"
    }
  in
  let rebuilt =
    { persisted with
      messages = List.map Fun.id persisted.messages
    ; created_at = persisted.created_at +. 1.0
    ; context = Agent_sdk.Context.copy persisted.context
    }
  in
  let selected, source_already_persisted =
    Finalize.select_finalization_checkpoint
      ~last_persisted_checkpoint:(Some persisted)
      rebuilt
  in
  Alcotest.(check bool)
    "matching pipeline checkpoint selected"
    true
    (source_already_persisted && selected == persisted);
  let patched, replay_suffix_pruned =
    Finalize.checkpoint_for_replay_persistence
      ~history_messages:history
      ~session_id:"new-session"
      ~response_text:"final"
      selected
    |> expect_ok
  in
  Alcotest.(check bool)
    "canonical no-op preserves the durable message spine"
    true
    (patched.messages == persisted.messages);
  Alcotest.(check bool)
    "final duplicate persistence is unnecessary"
    true
    (Finalize.finalization_checkpoint_already_persisted
       ~source_already_persisted
       ~source:selected
       ~patched
       ~replay_suffix_pruned)
;;

let test_finalization_does_not_reuse_distinct_message_state () =
  let open Agent_sdk.Types in
  let persisted =
    checkpoint ~working_context:None
      [ message User [ Text "question" ]; message Assistant [ Text "old" ] ]
  in
  let rebuilt =
    match persisted.messages with
    | [] -> Alcotest.fail "test checkpoint must contain messages"
    | first :: rest ->
      let copied_first = { first with metadata = first.metadata } in
      { persisted with
        messages = copied_first :: rest
      ; created_at = persisted.created_at +. 1.0
      }
  in
  let selected, source_already_persisted =
    Finalize.select_finalization_checkpoint
      ~last_persisted_checkpoint:(Some persisted)
      rebuilt
  in
  Alcotest.(check bool)
    "distinct message spine keeps the rebuilt checkpoint"
    true
    ((not source_already_persisted) && selected == rebuilt)
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
  Alcotest.(check (option string)) "retained replay has no prune reason"
    None
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
      ~session_id:"new-session"
      ~response_text:"visible answer"
      (checkpoint (history @ current_turn))
    |> expect_ok
  in
  Alcotest.(check int) "full replay retained" 6 (List.length patched.messages);
  Alcotest.(check (option string)) "retained replay has no prune reason"
    None
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

let test_empty_success_preserves_recorded_user_turn () =
  let open Agent_sdk.Types in
  let history =
    [ message User [ Text "old user" ]; message Assistant [ Text "old answer" ] ]
  in
  let patched, reason =
    Finalize.checkpoint_for_replay_persistence
      ~history_messages:history
      ~session_id:"new-session"
      ~response_text:""
      (checkpoint (history @ [ message User [ Text "current user" ] ]))
    |> expect_ok
  in
  Alcotest.(check int) "recorded user input survives blank completion" 3
    (List.length patched.messages);
  Alcotest.(check bool) "working context cleared on canonical success" true
    (patched.working_context = None);
  Alcotest.(check (option string)) "nothing was pruned"
    None
    (prune_reason_to_string reason)
;;

let test_empty_success_preserves_tool_execution_suffix () =
  let open Agent_sdk.Types in
  let history =
    [ message User [ Text "old user" ]; message Assistant [ Text "old answer" ] ]
  in
  let current_turn =
    [ message User [ Text "current user" ]
    ; message Assistant
        [ ToolUse
            { id = "tool-1"; name = "keeper_context_status"; input = `Assoc [] }
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
    ; message Assistant [ Text "" ]
    ]
  in
  let patched, reason =
    Finalize.checkpoint_for_replay_persistence
      ~history_messages:history
      ~session_id:"new-session"
      ~response_text:""
      (checkpoint (history @ current_turn))
    |> expect_ok
  in
  Alcotest.(check bool)
    "effectful replay survives without the trailing blank assistant"
    true
    (patched.messages = history @ List.rev (List.tl (List.rev current_turn)));
  Alcotest.(check bool) "working context cleared on canonical success" true
    (patched.working_context = None);
  Alcotest.(check (option string)) "blank assistant pruning is observable"
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

(* Each autonomous cycle is an ordinary durable user/assistant exchange. This
   continuation boundary does not depend on a tool call, an external delivery,
   or a turn identifier. *)
let wake_marker_text = Masc.Keeper_unified_prompt.autonomous_wake_marker

let wake_persistence ~history_messages ~response_text messages =
  Finalize.checkpoint_for_replay_persistence
    ~history_messages
    ~session_id:"new-session"
    ~response_text
    (checkpoint messages)
;;

let history_seed = [ message Agent_sdk.Types.User [ Agent_sdk.Types.Text "seed" ] ]

let test_autonomous_response_is_durable_conversation () =
  Alcotest.(check (option string))
    "assistant response is durable without an external effect"
    (Some "I will inspect the queue next.")
    (Finalize.replay_response_text_for_persistence
       ~suppress_visible_response:false
       ~response_text:"I will inspect the queue next.")
;;

let test_autonomous_turn_persists_cue_and_assistant () =
  let open Agent_sdk.Types in
  let suffix =
    [ message User [ Text wake_marker_text ]
    ; message Assistant [ Text "I will inspect the queue next." ]
    ]
  in
  let patched, _ =
    wake_persistence
      ~history_messages:history_seed
      ~response_text:"I will inspect the queue next."
      (history_seed @ suffix)
    |> expect_ok
  in
  Alcotest.(check int)
    "assistant joins the durable conversation"
    3
    (List.length patched.messages);
  Alcotest.(check string)
    "assistant intent survives"
    "I will inspect the queue next."
    (patched.messages |> List.rev |> List.hd |> text_of_message);
  Alcotest.(check bool)
    "ordinary continuation cue is durable"
    true
    (List.exists
       (fun (m : message) -> m.content = [ Text wake_marker_text ])
       patched.messages)
;;

let test_two_autonomous_cycles_continue_same_conversation () =
  let open Agent_sdk.Types in
  let first_response = "I will inspect the queue next." in
  let first_suffix =
    [ message User [ Text wake_marker_text ]
    ; message Assistant [ Text first_response ]
    ]
  in
  let first, _ =
    wake_persistence
      ~history_messages:history_seed
      ~response_text:first_response
      (history_seed @ first_suffix)
    |> expect_ok
  in
  with_temp_dir (fun session_dir ->
    (match
       Masc.Keeper_checkpoint_store.save_oas_classified ~session_dir first
     with
     | Ok (Masc.Keeper_checkpoint_store.Saved _) -> ()
     | Ok (Masc.Keeper_checkpoint_store.Stale_noop _) ->
       Alcotest.fail "first autonomous checkpoint was classified as stale"
     | Error detail -> Alcotest.fail ("first checkpoint save failed: " ^ detail));
    let reloaded =
      match
        Masc.Keeper_checkpoint_store.load_oas
          ~session_dir
          ~session_id:"new-session"
      with
      | Ok checkpoint -> checkpoint
      | Error _ -> Alcotest.fail "first autonomous checkpoint did not reload"
    in
    let second_response = "The queue inspection is complete." in
    let second_suffix =
      [ message User [ Text wake_marker_text ]
      ; message Assistant [ Text second_response ]
      ]
    in
    let second, _ =
      wake_persistence
        ~history_messages:reloaded.messages
        ~response_text:second_response
        (reloaded.messages @ second_suffix)
      |> expect_ok
    in
    Alcotest.(check (list string))
      "both ordinary turns survive save, reload, and conversation order"
      [ "seed"; wake_marker_text; first_response; wake_marker_text; second_response ]
      (List.map text_of_message second.messages))
;;

let test_non_marker_user_turn_is_untouched () =
  let open Agent_sdk.Types in
  let suffix =
    [ message User [ Text "an actual user question" ]
    ; message Assistant [ Text "reply" ]
    ]
  in
  let patched, _ =
    wake_persistence
      ~history_messages:history_seed
      ~response_text:"reply"
      (history_seed @ suffix)
    |> expect_ok
  in
  Alcotest.(check int)
    "ordinary user message remains in replay"
    3
    (List.length patched.messages)
;;

let test_blank_response_drops_only_blank_assistant () =
  let open Agent_sdk.Types in
  let suffix =
    [ message User [ Text wake_marker_text ]; message Assistant [ Text "" ] ]
  in
  let patched, _ =
    wake_persistence
      ~history_messages:history_seed
      ~response_text:""
      (history_seed @ suffix)
    |> expect_ok
  in
  Alcotest.(check int)
    "blank canonicalization keeps the current user turn"
    2
    (List.length patched.messages)
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
            "finalization reuses matching pipeline checkpoint"
            `Quick
            test_finalization_reuses_matching_pipeline_checkpoint
        ; Alcotest.test_case
            "finalization rejects distinct message state"
            `Quick
            test_finalization_does_not_reuse_distinct_message_state
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
            "empty success preserves recorded user turn"
            `Quick
            test_empty_success_preserves_recorded_user_turn
        ; Alcotest.test_case
            "empty success preserves tool execution suffix"
            `Quick
            test_empty_success_preserves_tool_execution_suffix
        ; Alcotest.test_case
            "InputRequired preserves exact tool-failure suffix"
            `Quick
            test_input_required_preserves_exact_tool_failure_suffix
        ; Alcotest.test_case
            "media-degraded projection persists canonical checkpoint"
            `Quick
            test_media_degraded_projection_persists_canonical_checkpoint
        ; Alcotest.test_case
            "autonomous response is durable conversation"
            `Quick
            test_autonomous_response_is_durable_conversation
        ; Alcotest.test_case
            "autonomous turn persists cue and assistant"
            `Quick
            test_autonomous_turn_persists_cue_and_assistant
        ; Alcotest.test_case
            "two autonomous cycles continue one conversation"
            `Quick
            test_two_autonomous_cycles_continue_same_conversation
        ; Alcotest.test_case
            "non-marker user turn is untouched"
            `Quick
            test_non_marker_user_turn_is_untouched
        ; Alcotest.test_case
            "blank response drops only blank assistant"
            `Quick
            test_blank_response_drops_only_blank_assistant
        ] )
    ]
;;
