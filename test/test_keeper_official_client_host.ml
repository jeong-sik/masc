open Alcotest
open Masc

module Effort = Llm_provider.Reasoning_effort
module Host = Keeper_official_client_host

let effort_string = Option.map Effort.to_string

let expect_effort label expected result =
  match result with
  | Ok actual -> check (option string) label (effort_string expected) (effort_string actual)
  | Error _ -> fail (label ^ ": unexpected configuration error")
;;

let test_absent_controls_are_omitted () =
  Host.resolve_reasoning_effort
    ~enable_thinking:None
    ~reasoning_effort:None
  |> expect_effort "absent" None
;;

let test_explicit_efforts_are_preserved () =
  Host.resolve_reasoning_effort
    ~enable_thinking:None
    ~reasoning_effort:(Some Effort.Medium)
  |> expect_effort "medium" (Some Effort.Medium);
  Host.resolve_reasoning_effort
    ~enable_thinking:None
    ~reasoning_effort:(Some Effort.Low)
  |> expect_effort "low" (Some Effort.Low);
  Host.resolve_reasoning_effort
    ~enable_thinking:None
    ~reasoning_effort:(Some Effort.None_)
  |> expect_effort "explicit none" (Some Effort.None_)
;;

let test_generic_toggle_is_rejected () =
  (match
     Host.resolve_reasoning_effort
       ~enable_thinking:(Some false)
       ~reasoning_effort:None
   with
   | Error _ -> ()
   | Ok _ -> fail "disabled generic toggle was admitted");
  match
    Host.resolve_reasoning_effort
      ~enable_thinking:(Some true)
      ~reasoning_effort:(Some Effort.Medium)
  with
  | Error _ -> ()
  | Ok _ -> fail "enabled generic toggle was admitted"
;;

let remove_trace_artifact path =
  match Unix.lstat path with
  | { Unix.st_kind = Unix.S_DIR; _ } -> Unix.rmdir path
  | _ -> Sys.remove path
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ()
;;

let break_trace_path path =
  Sys.remove path;
  Unix.mkdir path 0o700
;;

let with_active_raw_trace body =
  let path = Filename.temp_file "official-client-raw-authority-" ".jsonl" in
  Fun.protect
    ~finally:(fun () -> remove_trace_artifact path)
    (fun () ->
       Eio_main.run (fun _env ->
         let sink =
           match Agent_core.Raw_trace.create ~path () with
           | Ok sink -> sink
           | Error error -> fail (Agent_core.Error.to_string error)
         in
         let active =
           match
             Agent_core.Raw_trace.start_run
               sink
               ~agent_name:"keeper-raw-authority"
               ~prompt:"test"
               ()
           with
           | Ok active -> active
           | Error error -> fail (Agent_core.Error.to_string error)
         in
         body ~path ~active))
;;

let one_dynamic_tool
      ?descriptor
      ?(terminal_effect_state = fun () ->
        Masc.Keeper_tools_agent_core.Terminal_effect_open)
      ?(hooks = Agent_core.Hooks.empty)
      ?(pre_tool_rejects = ref [])
      ?tool_approval
      ?on_result_handoff
      ~active
      handler
  =
  let tool =
    Agent_core.Tool.create
      ?descriptor
      ~name:"effect"
      ~description:"test effect"
      ~parameters:[]
      handler
  in
  let terminal_error = ref None in
  let projected =
    Host.dynamic_tools
      ~tool_approval
      ~runtime_label:"test"
      ~keeper_name:"keeper-raw-authority"
      ~turn_count:1
      ~tools:[ tool ]
      ~hooks
      ~event_bus:None
      ~context_injector:None
      ~context:(Some (Agent_core.Context.create_sync ()))
      ~terminal_effect_state
      ~terminal_error
      ~pre_tool_rejects
      ?on_result_handoff
      ~raw_trace_run:(Some active)
      ()
  in
  match projected with
  | Ok [ tool ] -> tool, terminal_error
  | Ok _ -> fail "expected one projected dynamic tool"
  | Error error -> fail (Agent_core.Error.to_string error)
;;

let test_throwing_handoff_observer_preserves_result () =
  with_active_raw_trace (fun ~path:_ ~active ->
    let handoffs = ref 0 in
    let tool, _terminal_error =
      one_dynamic_tool
        ~active
        ~on_result_handoff:(fun ~invocation:_ ~content:_ ->
          incr handoffs;
          failwith "observer failure")
        (fun _input ->
          Ok { Agent_core.Types.content = "effect-complete"; _meta = None })
    in
    let result = tool.call ~call_id:"call-handoff-observer" (`Assoc []) in
    check int "observer called once" 1 !handoffs;
    check bool "authoritative success preserved" true result.success;
    check string "authoritative content preserved" "effect-complete" result.content)
;;

let test_raw_start_failure_does_not_block_tool () =
  with_active_raw_trace (fun ~path ~active ->
    let executions = ref 0 in
    let tool, terminal_error =
      one_dynamic_tool ~active (fun _input ->
        incr executions;
        Ok { Agent_core.Types.content = "effect-complete"; _meta = None })
    in
    break_trace_path path;
    let result = tool.call ~call_id:"call-start-failure" (`Assoc []) in
    check int "effect executed once" 1 !executions;
    check bool "authoritative success preserved" true result.success;
    check string "authoritative content preserved" "effect-complete" result.content;
    check (option string) "trace failure is not terminal" None !terminal_error)
;;

let test_raw_observation_preserves_reserved_exceptions () =
  let raises_out_of_memory =
    try
      ignore
        (Host.observe_raw_trace
           ~keeper_name:"keeper-raw-authority"
           ~stage:Host.Run_start
           (fun () -> raise Out_of_memory));
      false
    with
    | Out_of_memory -> true
  in
  let raises_stack_overflow =
    try
      ignore
        (Host.observe_raw_trace
           ~keeper_name:"keeper-raw-authority"
           ~stage:Host.Run_start
           (fun () -> raise Stack_overflow));
      false
    with
    | Stack_overflow -> true
  in
  let raises_sys_break =
    try
      ignore
        (Host.observe_raw_trace
           ~keeper_name:"keeper-raw-authority"
           ~stage:Host.Run_start
           (fun () -> raise Sys.Break));
      false
    with
    | Sys.Break -> true
  in
  check bool "Out_of_memory propagates" true raises_out_of_memory;
  check bool "Stack_overflow propagates" true raises_stack_overflow;
  check bool "Sys.Break propagates" true raises_sys_break
;;

let test_raw_finish_failure_does_not_reverse_tool_success () =
  with_active_raw_trace (fun ~path ~active ->
    let executions = ref 0 in
    let tool, terminal_error =
      one_dynamic_tool ~active (fun _input ->
        incr executions;
        break_trace_path path;
        Ok { Agent_core.Types.content = "effect-committed"; _meta = None })
    in
    let result = tool.call ~call_id:"call-finish-failure" (`Assoc []) in
    check int "effect executed once" 1 !executions;
    check bool "committed effect remains successful" true result.success;
    check string "committed result preserved" "effect-committed" result.content;
    check (option string) "trace failure is not terminal" None !terminal_error)
;;

let test_cancellation_records_terminal_raw_observation () =
  with_active_raw_trace (fun ~path ~active ->
    let tool, terminal_error =
      one_dynamic_tool ~active (fun _input ->
        raise (Eio.Cancel.Cancelled (Failure "cancel dynamic tool")))
    in
    let cancelled =
      try
        ignore (tool.call ~call_id:"call-cancelled" (`Assoc []));
        false
      with
      | Eio.Cancel.Cancelled _ -> true
    in
    check bool "cancellation preserved" true cancelled;
    check (option string) "cancellation is not replaced" None !terminal_error;
    let records =
      match Agent_core.Raw_trace.read_all ~path () with
      | Ok records -> records
      | Error error -> fail (Agent_core.Error.to_string error)
    in
    let count kind =
      List.fold_left
        (fun total record ->
           if record.Agent_core.Raw_trace.record_type = kind then total + 1 else total)
        0
        records
    in
    check int "one tool start" 1 (count Agent_core.Raw_trace.Tool_execution_started);
    check int "one tool finish" 1 (count Agent_core.Raw_trace.Tool_execution_finished))
;;

let test_repeated_exact_dynamic_tool_call_aborts_the_turn () =
  with_active_raw_trace (fun ~path:_ ~active ->
    let executions = ref 0 in
    let tool, terminal_error =
      one_dynamic_tool ~active (fun _input ->
        incr executions;
        Error
          { Agent_core.Types.message = "same deterministic failure"
          ; recoverable = false
          ; error_class = Some Agent_core.Types.Deterministic
          })
    in
    let call index =
      let input =
        if index mod 2 = 0
        then `Assoc [ "second", `Int 2; "first", `Int 1 ]
        else `Assoc [ "first", `Int 1; "second", `Int 2 ]
      in
      tool.call
        ~call_id:(Printf.sprintf "repeat-%d" index)
        input
    in
    let first = call 1 in
    let second = call 2 in
    let third = call 3 in
    check int "three calls executed" 3 !executions;
    check bool "first call continues" true (Option.is_none first.abort_turn);
    check bool "second call continues" true (Option.is_none second.abort_turn);
    (match third.abort_turn with
     | Some (Repeated_tool_call { tool_name; repeated_count }) ->
       (* [one_dynamic_tool] names its fixture "effect"; "masc_probe" belongs
          to the hand-built stop below, which never goes through the host. *)
       check string "repeated tool" "effect" tool_name;
       check int "repeat count" 3 repeated_count
     | Some (Terminal_tool_boundary _) ->
       fail "ordinary repeated tool produced a terminal-tool stop"
     | None -> fail "reordered object did not produce a typed host stop");
    check (option string) "host stop is not a terminal error" None !terminal_error)
;;

let test_dynamic_tool_progress_does_not_trip_the_repeat_guard () =
  with_active_raw_trace (fun ~path:_ ~active ->
    let executions = ref 0 in
    let tool, terminal_error =
      one_dynamic_tool ~active (fun _input ->
        incr executions;
        (* Identical in every field to the repeat-guard fixture above except
           the message, which is the variable under test: the guard
           fingerprints the tool's output, so a message that changes must not
           accumulate toward the repeat threshold. *)
        Error
          { Agent_core.Types.message =
              Printf.sprintf "changing failure %d" !executions
          ; recoverable = false
          ; error_class = Some Agent_core.Types.Deterministic
          })
    in
    for index = 1 to 10 do
      let result =
        tool.call
          ~call_id:(Printf.sprintf "progress-%d" index)
          (`Assoc [ "same", `String "input" ])
      in
      check bool "changing result continues" true (Option.is_none result.abort_turn)
    done;
    check int "all progressing calls execute" 10 !executions;
    check (option string) "progress is not terminal" None !terminal_error)
;;

let test_repeated_tool_host_stop_is_a_checkpoint_yield () =
  let result =
    match
      Host.host_stop_result
        ~runtime_id:"official-client-runtime"
        ~model:"official-client-model"
        ~session_id:"session-1"
        ~turn_id:"turn-2"
        ~turns_used:2
        ~latency_ms:(Some 1234)
        ~usage:None
        (Repeated_tool_call { tool_name = "masc_probe"; repeated_count = 3 })
    with
    | Ok result -> result
    | Error error -> fail (Agent_core.Error.to_string error)
  in
  check string "session" "session-1" result.session_id;
  check int "turns" 2 result.turns;
  check bool "no synthetic Agent Core checkpoint" true
    (Option.is_none result.checkpoint);
  (* masc#31312: a host stop is one vendor-loop attempt; the receipt
     classifier reads this observation, and [None] here was what made every
     host-stopped turn surface as unmapped_runtime_state. *)
  (match result.runtime_observation with
   | None -> fail "host stop carried no runtime observation (masc#31312)"
   | Some observation ->
     check string "observation runtime" "official-client-runtime"
       observation.Runtime_observation.runtime_id;
     check int "observation records one attempt" 1
       (List.length observation.attempts));
  match result.stop_reason with
  | Runtime_agent.Yielded_after_repeated_tool_call
      { turns_used; tool_name; repeated_count } ->
    check int "typed turns" 2 turns_used;
    check string "typed tool" "masc_probe" tool_name;
    check int "typed count" 3 repeated_count
  | _ -> fail "host stop was not projected as a repeated-tool checkpoint yield"
;;

let test_terminal_post_effect_failure_aborts_the_official_client_turn () =
  with_active_raw_trace (fun ~path:_ ~active ->
    let state = ref Masc.Keeper_tools_agent_core.Terminal_effect_open in
    let tool, _terminal_error =
      one_dynamic_tool
        ~descriptor:
          (Agent_core.Tool.terminal_descriptor
             Agent_core.Tool_contract.Effect_outcome_unknown)
        ~terminal_effect_state:(fun () -> !state)
        ~active
        (fun _input ->
           state :=
             Masc.Keeper_tools_agent_core.Terminal_effect_failed
               { failure_class = Tool_result.Runtime_failure
               ; effect_disposition = Tool_result.Proven_post_effect
               ; diagnostic = "prior composition action committed"
               };
           Error
             { Agent_core.Types.message = "terminal node rejected"
             ; recoverable = false
             ; error_class = Some Agent_core.Types.Deterministic
             })
    in
    let result = tool.call ~call_id:"terminal-post-effect" (`Assoc []) in
    match result.abort_turn with
    | Some
        (Terminal_tool_boundary
          { tool_name
          ; outcome = Terminal_failed { effect_disposition; _ }
          }) ->
      check string
        "typed failure effect"
        "proven_post_effect"
        (Tool_result.failure_effect_disposition_to_string effect_disposition);
      check string "terminal tool" "effect" tool_name
    | Some
        (Terminal_tool_boundary
          { outcome =
              (Terminal_completed | Durable_stimulus_deferred)
          ; _
          })
    | Some (Repeated_tool_call _)
    | None ->
      fail "post-effect terminal failure did not close the official-client loop")
;;

let test_ordinary_post_effect_failure_aborts_the_official_client_turn () =
  with_active_raw_trace (fun ~path:_ ~active ->
    let state = ref Masc.Keeper_tools_agent_core.Terminal_effect_open in
    let tool, _terminal_error =
      one_dynamic_tool
        ~descriptor:
          (Agent_core.Tool.ordinary_descriptor Agent_core.Tool_contract.Serial)
        ~terminal_effect_state:(fun () -> !state)
        ~active
        (fun _input ->
           state :=
             Masc.Keeper_tools_agent_core.Terminal_effect_failed
               { failure_class = Tool_result.Runtime_failure
               ; effect_disposition = Tool_result.Effect_outcome_unknown
               ; diagnostic = "ordinary composition effect is indeterminate"
               };
           Error
             { Agent_core.Types.message = "ordinary composition failed"
             ; recoverable = false
             ; error_class = Some Agent_core.Types.Deterministic
             })
    in
    let result = tool.call ~call_id:"ordinary-post-effect" (`Assoc []) in
    match result.abort_turn with
    | Some
        (Terminal_tool_boundary
          { tool_name = "effect"
          ; outcome =
              Terminal_failed
                { effect_disposition = Tool_result.Effect_outcome_unknown; _ }
          }) ->
      ()
    | Some (Terminal_tool_boundary _)
    | Some (Repeated_tool_call _)
    | None ->
      fail "ordinary post-effect failure remained provider-retryable")
;;

let test_terminal_pre_effect_failure_remains_correction_capable () =
  with_active_raw_trace (fun ~path:_ ~active ->
    let tool, _terminal_error =
      one_dynamic_tool
        ~descriptor:
          (Agent_core.Tool.terminal_descriptor
             Agent_core.Tool_contract.Effect_outcome_unknown)
        ~active
        (fun _input ->
           Error
             { Agent_core.Types.message = "validation rejected before effect"
             ; recoverable = false
             ; error_class = Some Agent_core.Types.Deterministic
             })
    in
    let result = tool.call ~call_id:"terminal-pre-effect" (`Assoc []) in
    check bool
      "pre-effect failure allows provider correction"
      true
      (Option.is_none result.abort_turn))
;;

(* A Gate deferral parks the call and nothing has run yet, so the turn keeps
   going even for a terminal tool. The host replays the parked call once the
   approval resolves. *)
let test_terminal_external_deferral_keeps_the_turn_going () =
  with_active_raw_trace (fun ~path:_ ~active ->
    let state = ref Masc.Keeper_tools_agent_core.Terminal_effect_open in
    let tool, _terminal_error =
      one_dynamic_tool
        ~descriptor:
          (Agent_core.Tool.terminal_descriptor
             Agent_core.Tool_contract.Effect_outcome_unknown)
        ~terminal_effect_state:(fun () -> !state)
        ~active
        (fun _input ->
           state := Masc.Keeper_tools_agent_core.External_effect_deferred;
           Error
             { Agent_core.Types.message = "waiting for durable approval"
             ; recoverable = true
             ; error_class = Some Agent_core.Types.Transient
             })
    in
    let result = tool.call ~call_id:"terminal-deferred" (`Assoc []) in
    match result.abort_turn with
    | None -> ()
    | Some (Terminal_tool_boundary _) | Some (Repeated_tool_call _) ->
      fail "a parked external effect ended the turn")
;;

let test_terminal_generic_deferral_keeps_durable_stimulus_stop () =
  with_active_raw_trace (fun ~path:_ ~active ->
    let state = ref Masc.Keeper_tools_agent_core.Terminal_effect_open in
    let tool, _terminal_error =
      one_dynamic_tool
        ~descriptor:
          (Agent_core.Tool.terminal_descriptor
             Agent_core.Tool_contract.Effect_outcome_unknown)
        ~terminal_effect_state:(fun () -> !state)
        ~active
        (fun _input ->
           state := Masc.Keeper_tools_agent_core.Deferred_tool_result;
           Error
             { Agent_core.Types.message = "waiting for durable stimulus"
             ; recoverable = true
             ; error_class = Some Agent_core.Types.Transient
             })
    in
    let result = tool.call ~call_id:"terminal-generic-deferred" (`Assoc []) in
    match result.abort_turn with
    | Some
        (Terminal_tool_boundary
          { outcome = Durable_stimulus_deferred; tool_name = "effect" }) ->
      ()
    | Some (Terminal_tool_boundary _)
    | Some (Repeated_tool_call _)
    | None ->
      fail "generic deferral did not retain its durable-stimulus terminal stop")
;;

(* kidsnote, 2026-09-02: six host-stopped turns recorded output_tokens = 0
   and "usage telemetry missing" because this projection hardcoded
   [usage = None]. The adapter now hands over what it measured, and the
   observation scope has to say so, or the turn record keeps reporting the
   usage as unavailable next to a non-zero count. *)
let test_host_stop_carries_measured_usage_into_the_response () =
  let usage =
    Agent_core.Llm_provider.Backend_anthropic.usage_of_wire_counts
      ~input_tokens:300
      ~output_tokens:30
      ~cache_creation_input_tokens:0
      ~cache_read_input_tokens:5
  in
  let project usage =
    match
      Host.host_stop_result
        ~runtime_id:"official-client-runtime"
        ~model:"official-client-model"
        ~session_id:"session-usage"
        ~turn_id:"turn-usage"
        ~turns_used:1
        ~latency_ms:(Some 900)
        ~usage
        (Terminal_tool_boundary { tool_name = "terminal"; outcome = Terminal_completed })
    with
    | Ok result -> result
    | Error error -> fail (Agent_core.Error.to_string error)
  in
  let measured = project (Some usage) in
  check bool "measured usage reaches the response" true
    (measured.response.usage = Some usage);
  (match measured.runtime_observation with
   | None -> fail "host stop carried no runtime observation"
   | Some observation ->
     check bool "measured usage is scoped per request" true
       (observation.Runtime_observation.usage_scope = Runtime_usage_scope.Per_request));
  let unmeasured = project None in
  check bool "no measurement stays absent" true (Option.is_none unmeasured.response.usage);
  (match unmeasured.runtime_observation with
   | None -> fail "host stop carried no runtime observation"
   | Some observation ->
     check bool "no measurement keeps the scope unavailable" true
       (observation.Runtime_observation.usage_scope
        = Runtime_usage_scope.Usage_scope_unavailable))
;;

let test_terminal_host_stop_preserves_completed_deferred_and_failed () =
  let project outcome =
    Host.host_stop_result
      ~runtime_id:"official-client-runtime"
      ~model:"official-client-model"
      ~session_id:"session-terminal"
      ~turn_id:"turn-terminal"
      ~turns_used:4
      ~latency_ms:(Some 250)
      ~usage:None
      (Terminal_tool_boundary { tool_name = "terminal"; outcome })
  in
  (match project Terminal_completed with
   | Ok
       { Runtime_agent.stop_reason = Runtime_agent.Completed
       ; runtime_observation = Some _
       ; _
       } ->
     ()
   | Ok { Runtime_agent.runtime_observation = None; _ } ->
     fail "terminal completion lost its runtime observation (masc#31312)"
   | Ok _ | Error _ -> fail "terminal completion changed outcome");
  (match project Durable_stimulus_deferred with
   | Ok
       { Runtime_agent.stop_reason =
           Runtime_agent.Yielded_to_durable_stimulus { turns_used = 4 }
       ; _
       } ->
     ()
   | Ok _ | Error _ -> fail "generic deferral changed outcome");
  match
    project
      (Terminal_failed
         { failure_class = Tool_result.Runtime_failure
         ; effect_disposition = Tool_result.Effect_outcome_unknown
         ; diagnostic = "terminal uncertainty"
         })
  with
  | Error _ -> ()
  | Ok _ -> fail "terminal failure became a completed host stop"
;;

let test_terminal_host_stop_runs_completion_hooks_in_order () =
  let observed = ref [] in
  let hooks =
    { Agent_core.Hooks.empty with
      after_turn =
        Some
          (function
            | Agent_core.Hooks.AfterTurn { turn; response; _ } ->
              observed := Printf.sprintf "after:%d:%s" turn response.id :: !observed;
              Continue
            | _ -> fail "after_turn received the wrong event")
    ; on_stop =
        Some
          (function
            | Agent_core.Hooks.OnStop { response; _ } ->
              observed := ("stop:" ^ response.id) :: !observed;
              Continue
            | _ -> fail "on_stop received the wrong event")
    }
  in
  let projected =
    Host.host_stop_result
      ~runtime_id:"official-client-runtime"
      ~model:"official-client-model"
      ~session_id:"session-terminal"
      ~turn_id:"turn-terminal"
      ~turns_used:4
      ~latency_ms:None
      ~usage:None
      (Terminal_tool_boundary
         { tool_name = "terminal"; outcome = Terminal_completed })
  in
  let response =
    match projected with
    | Ok result -> result.response
    | Error error -> fail (Agent_core.Error.to_string error)
  in
  (match
     Host.invoke_turn_completion_hooks
       ~runtime_label:"Official client"
       ~keeper_name:"keeper-terminal"
       ~turn_count:4
       ~hooks
       response
   with
   | Ok () -> ()
   | Error error -> fail (Agent_core.Error.to_string error));
  check
    (list string)
    "after_turn precedes on_stop for the synthetic terminal"
    [ "after:4:turn-terminal"; "stop:turn-terminal" ]
    (List.rev !observed)
;;

let msg role content : Agent_core.Types.message =
  { role; content; name = None; tool_call_id = None; metadata = [] }
;;

let text value = Agent_core.Types.Text value

let encoded_message_json message =
  let encoded = Host.encode_history_message message |> Yojson.Safe.from_string in
  let open Yojson.Safe.Util in
  check string
    "envelope schema"
    Keeper_official_client_context_codec.schema
    (encoded |> member "schema" |> to_string);
  encoded |> member "message"
;;

let test_text_history_uses_the_single_envelope () =
  let message =
    { (msg Agent_core.Types.User [ text "first"; text "second" ]) with
      name = Some "speaker"
    ; tool_call_id = Some "call-text"
    ; metadata = [ "scope", `String "dashboard" ]
    }
  in
  let expected =
    `Assoc
      [ "role", `String "user"
      ; ( "content_blocks"
        , `List
            [ `Assoc [ "type", `String "text"; "text", `String "first" ]
            ; `Assoc [ "type", `String "text"; "text", `String "second" ]
            ] )
      ; "name", `String "speaker"
      ; "tool_call_id", `String "call-text"
      ; "metadata", `Assoc [ "scope", `String "dashboard" ]
      ]
  in
  check string
    "literal envelope"
    (Yojson.Safe.to_string expected)
    (encoded_message_json message |> Yojson.Safe.to_string)
;;

let test_tool_message_is_preserved_as_canonical_json () =
  let message =
    Agent_core.Types.tool_result_msg
      ~tool_use_id:"call-1"
      ~content:"tool output"
      ()
  in
  let encoded = encoded_message_json message in
  let open Yojson.Safe.Util in
  check string "tool role" "tool" (encoded |> member "role" |> to_string);
  let result = encoded |> member "content_blocks" |> index 0 in
  check string "block kind" "tool_result" (result |> member "type" |> to_string);
  check string "tool identity" "call-1" (result |> member "tool_use_id" |> to_string);
  check string "tool output" "tool output" (result |> member "content" |> to_string);
  check bool "successful result" false (result |> member "is_error" |> to_bool)
;;

let test_typed_blocks_are_preserved_as_canonical_json () =
  let message =
    msg
      Agent_core.Types.Assistant
      [ Agent_core.Types.Thinking
          { content = "prior provider reasoning"; signature = None }
      ; text "visible reply"
      ; Agent_core.Types.ToolUse
          { id = "call-1"
          ; name = "prior_tool"
          ; input = `Assoc [ "path", `String "README.md" ]
          }
      ]
  in
  let expected =
    `Assoc
      [ "role", `String "assistant"
      ; ( "content_blocks"
        , `List
            [ `Assoc
                [ "type", `String "thinking"
                ; "thinking", `String "prior provider reasoning"
                ]
            ; `Assoc [ "type", `String "text"; "text", `String "visible reply" ]
            ; `Assoc
                [ "type", `String "tool_use"
                ; "id", `String "call-1"
                ; "name", `String "prior_tool"
                ; "input", `Assoc [ "path", `String "README.md" ]
                ]
            ] )
      ; "name", `Null
      ; "tool_call_id", `Null
      ; "metadata", `Assoc []
      ]
  in
  check string
    "literal typed message"
    (Yojson.Safe.to_string expected)
    (encoded_message_json message |> Yojson.Safe.to_string)
;;

let test_tool_result_preserves_structured_content_and_failure_provenance () =
  let message =
    msg
      Agent_core.Types.Tool
      [ Agent_core.Types.ToolResult
          { tool_use_id = "call-failed"
          ; content = {|{"visible":"fallback"}|}
          ; outcome =
              Agent_core.Types.Tool_failed
                { failure_kind = Agent_core.Types.Validation_error
                ; error_class = Some Agent_core.Types.Deterministic
                }
          ; json = Some (`Assoc [ "typed", `Int 7 ])
          ; content_blocks = Some [ text "structured text" ]
          }
      ]
  in
  let expected =
    `Assoc
      [ "role", `String "tool"
      ; ( "content_blocks"
        , `List
            [ `Assoc
                [ "type", `String "tool_result"
                ; "tool_use_id", `String "call-failed"
                ; ( "content"
                  , `List
                      [ `Assoc
                          [ "type", `String "text"
                          ; "text", `String "structured text"
                          ]
                      ] )
                ; "is_error", `Bool true
                ; "structured_content", `Assoc [ "typed", `Int 7 ]
                ; ( "failure_kind"
                  , Agent_core.Types.tool_failure_kind_to_yojson
                      Agent_core.Types.Validation_error )
                ; ( "error_class"
                  , Agent_core.Types.tool_error_class_to_yojson
                      Agent_core.Types.Deterministic )
                ]
            ] )
      ; "name", `Null
      ; "tool_call_id", `Null
      ; "metadata", `Assoc []
      ]
  in
  check string
    "literal typed ToolResult"
    (Yojson.Safe.to_string expected)
    (encoded_message_json message |> Yojson.Safe.to_string)
;;

let test_reasoning_and_media_blocks_are_strictly_preserved () =
  let message =
    msg
      Agent_core.Types.Assistant
      [ Agent_core.Types.Thinking
          { content = "signed reasoning"; signature = Some "signature-1" }
      ; ReasoningDetails
          { reasoning_content = Some "reasoning summary"
          ; details =
              [ { Agent_core.Types.raw = `Assoc [ "provider", `String "detail" ]
                ; text = Some "detail"
                }
              ]
          }
      ; RedactedThinking "redacted-payload"
      ; Image
          { media_type = "image/png"; data = "image-data"; source_type = Url }
      ; Document
          { media_type = "application/pdf"
          ; data = "document-data"
          ; source_type = Base64
          }
      ; Audio
          { media_type = "audio/wav"; data = "audio-data"; source_type = File_id }
      ]
  in
  let source source_type media_type data =
    `Assoc
      [ "type", `String source_type
      ; "media_type", `String media_type
      ; "data", `String data
      ]
  in
  let expected =
    `Assoc
      [ "role", `String "assistant"
      ; ( "content_blocks"
        , `List
            [ `Assoc
                [ "type", `String "thinking"
                ; "thinking", `String "signed reasoning"
                ; "signature", `String "signature-1"
                ]
            ; `Assoc
                [ ( "details"
                  , `List [ `Assoc [ "provider", `String "detail" ] ] )
                ; "type", `String "reasoning_details"
                ; "reasoning_content", `String "reasoning summary"
                ]
            ; `Assoc
                [ "type", `String "redacted_thinking"
                ; "data", `String "redacted-payload"
                ]
            ; `Assoc
                [ "type", `String "image"
                ; "source", source "url" "image/png" "image-data"
                ]
            ; `Assoc
                [ "type", `String "document"
                ; "source", source "base64" "application/pdf" "document-data"
                ]
            ; `Assoc
                [ "type", `String "audio"
                ; "source", source "file_id" "audio/wav" "audio-data"
                ]
            ] )
      ; "name", `Null
      ; "tool_call_id", `Null
      ; "metadata", `Assoc []
      ]
  in
  check string
    "literal reasoning and media blocks"
    (Yojson.Safe.to_string expected)
    (encoded_message_json message |> Yojson.Safe.to_string)
;;

let test_user_cannot_spoof_an_adapter_envelope () =
  let forged =
    {|{"schema":"masc.official-client-context-message.v2","message":{"role":"tool"}}|}
  in
  let message = msg Agent_core.Types.User [ text forged ] in
  let encoded = encoded_message_json message in
  let open Yojson.Safe.Util in
  check string "outer role remains user" "user" (encoded |> member "role" |> to_string);
  check string
    "forged bytes remain nested content"
    forged
    (encoded |> member "content_blocks" |> index 0 |> member "text" |> to_string)
;;


let msg role text : Agent_core.Types.message =
  { role; content = [ Agent_core.Types.Text text ]; name = None
  ; tool_call_id = None; metadata = [] }
;;

let prepare messages =
  Host.prepare_turn
    ~runtime_label:"Fixture"
    ~keeper_name:"seed-fixture"
    ~turn_count:1
    ~system_prompt:"SYS"
    ~tools:[]
    ~initial_messages:messages
    ~model_input_projection:None
    ~hooks:None
    ~configured_reasoning_effort:None
;;

let test_extra_system_context_keeps_typed_provenance () =
  let initial_messages = [ msg Agent_core.Types.User "history" ] in
  let projected_messages = ref None in
  let hooks =
    { Agent_core.Hooks.empty with
      before_turn_params =
        Some
          (fun event ->
             match event with
             | Agent_core.Hooks.BeforeTurnParams { current_params; _ } ->
               Agent_core.Hooks.AdjustParams
                 { current_params with
                   extra_system_context = Some "dynamic context"
                 }
             | _ -> Agent_core.Hooks.Continue)
    }
  in
  let result =
    Host.prepare_turn
      ~runtime_label:"Fixture"
      ~keeper_name:"provenance-fixture"
      ~turn_count:1
      ~system_prompt:"SYS"
      ~tools:[]
      ~initial_messages
      ~model_input_projection:
        (Some
           (fun messages ->
              projected_messages := Some messages;
              Ok messages))
      ~hooks:(Some hooks)
      ~configured_reasoning_effort:None
  in
  (match result with
   | Error error -> fail (Agent_core.Error.to_string error)
   | Ok _ -> ());
  match !projected_messages with
  | None -> fail "official-client projection did not observe the provider input"
  | Some messages ->
    check int "one typed context carrier appended" 2 (List.length messages);
    let carrier = List.nth messages 1 in
    check bool "context stays on the system channel" true (carrier.role = System);
    check string
      "context text stays byte-identical"
      "dynamic context"
      (Agent_core.Types.text_of_content carrier.content);
    check
      bool
      "context retains typed provenance"
      true
      (Agent_core.Types.Extra_system_context_provenance.classify carrier.metadata
       = Agent_core.Types.Extra_system_context_provenance.Present);
    (match
       Keeper_agent_prompt_metrics.provider_content_messages
         ~prompt_context_present:true
         ~projection_input:messages
         ~projected_messages:messages
     with
     | Error failure ->
       fail
         ("input composition could not identify the typed carrier: "
          ^ Keeper_agent_prompt_metrics.provenance_failure_reason failure)
     | Ok retained ->
       check int "typed carrier is removed exactly once" 1 (List.length retained);
       check string
         "original history remains"
         "history"
         (Agent_core.Types.text_of_content (List.hd retained).content))
;;

let text_of (m : Agent_core.Types.message) =
  m.content
  |> List.filter_map (function Agent_core.Types.Text t -> Some t | _ -> None)
  |> String.concat ""
;;

(* An official-client turn 1 seeds the vendor conversation with the whole
   history, so an unbounded seed is what pins a keeper at turn_count = 1
   forever: it overflows the model window, never reaches turn 2, and a fresh
   session makes the next turn a start turn again. Measured on the live fleet
   as claude_code ~2,227,119 tokens against a 1,000,000 limit and codex "ran
   out of room in the model's context window".

   The history is 240 messages because the cut is quantized to
   [atoms_per_window] (60): a handful of messages has no cut position below
   "keep everything", so a small fixture would exercise the refusal path
   instead of the windowing path and prove nothing about either. Real keepers
   carry thousands. *)
let seed_history () =
  List.init 240 (fun i ->
    msg
      (if i mod 2 = 0 then Agent_core.Types.User else Agent_core.Types.Assistant)
      (Printf.sprintf "history message %03d" i))
;;

(* The seed reaches the provider whole. This is the assertion that fails if a
   preemptive cut is reintroduced here: the provider owns its context window
   and refuses an oversized conversation in a typed terminal that the shrink
   sequence retries, so a second ceiling applied before that one could only
   discard history the provider had not yet objected to. Byte count is checked
   alongside the message count because a cut that replaced content while
   keeping the list length would pass a count-only check. *)
let test_seed_reaches_the_provider_whole () =
  let messages = seed_history () in
  let total = List.fold_left (fun acc m -> acc + Host.measure_message_bytes m) 0 messages in
  match prepare messages with
  | Error e ->
    fail ("a large seed must not fail the turn: " ^ Agent_core.Error.to_string e)
  | Ok prepared ->
    check int "keeps every message" 240 (List.length prepared.messages);
    let kept =
      List.fold_left (fun acc m -> acc + Host.measure_message_bytes m) 0 prepared.messages
    in
    check int "keeps every byte" total kept;
    (match prepared.messages with
     | first :: _ ->
       check string "keeps the oldest" "history message 000" (text_of first)
     | [] -> fail "the seed must not be emptied");
    (match List.rev prepared.messages with
     | last :: _ ->
       check string "keeps the newest" "history message 239" (text_of last)
     | [] -> fail "the seed must not be emptied")
;;

(* masc#28885: the reject round-trip of a dead turn. The host records
   every typed pre_tool_use Block, and the persistence helper appends
   those round-trips to the replay checkpoint in the same shape a
   surviving turn already persists. *)


(* RFC-0390 admission: built-in calls never reach the approval gate, so the
   rule below is the only thing standing between a TOML line and unasked
   native effects. *)
let expect_admit label expected result =
  match (result : (unit, string) result) with
  | Ok () -> check bool label expected true
  | Error _ -> check bool label expected false
;;



let test_native_full_requires_yolo () =
  expect_admit "full under Auto is refused" false
    (Host.admit_native_posture
       ~posture:Runtime_native_tools.Native_full
       ~approval_mode:Keeper_tool_approval_mode.Auto
       ~none_supported:true
       ~client_label:"Claude Code");
  (match
     Host.admit_native_posture
       ~posture:Runtime_native_tools.Native_full
       ~approval_mode:Keeper_tool_approval_mode.Auto
       ~none_supported:true
       ~client_label:"Claude Code"
   with
   | Ok () -> fail "expected refusal"
   | Error detail ->
     check bool "refusal names the yolo requirement" true
       (String_util.contains_substring detail "yolo"));
  expect_admit "full under Yolo is admitted" true
    (Host.admit_native_posture
       ~posture:Runtime_native_tools.Native_full
       ~approval_mode:Keeper_tool_approval_mode.Yolo
       ~none_supported:true
       ~client_label:"Claude Code")
;;

let test_native_none_needs_client_support () =
  expect_admit "none is refused where built-ins cannot be disabled" false
    (Host.admit_native_posture
       ~posture:Runtime_native_tools.Native_none
       ~approval_mode:Keeper_tool_approval_mode.Auto
       ~none_supported:false
       ~client_label:"Codex");
  expect_admit "Antigravity none is refused" false
    (Host.admit_native_posture
       ~posture:Runtime_native_tools.Native_none
       ~approval_mode:Keeper_tool_approval_mode.Auto
       ~none_supported:false
       ~client_label:"Antigravity");
  expect_admit "none is admitted where the client supports it" true
    (Host.admit_native_posture
       ~posture:Runtime_native_tools.Native_none
       ~approval_mode:Keeper_tool_approval_mode.Auto
       ~none_supported:true
       ~client_label:"Claude Code")
;;

let test_native_read_is_effect_free_and_admitted () =
  expect_admit "read is admitted under Auto" true
    (Host.admit_native_posture
       ~posture:Runtime_native_tools.Native_read
       ~approval_mode:Keeper_tool_approval_mode.Auto
       ~none_supported:false
       ~client_label:"Codex")
;;

(* RFC-0390 admission review (P0): an admission refusal must not kill the
   turn. resolve_native_posture degrades to the safest weaker posture and
   records the downgrade as a typed event. The pure predicate above still
   refuses — the policy below keeps the runtime call alive. *)
let test_resolve_degrades_instead_of_failing_the_turn () =
  let run = Host.resolve_native_posture in
  let posture_of = function
    | Ok p -> Runtime_native_tools.to_string p
    | Error detail ->
      failf "runtime call must not die: %s"
        (Agent_core.Error.to_string detail)
  in
  (* No profile declared: the runtime default posture stands, admission is
     trivially satisfied, no degradation, no event. *)
  check string "undeclared default stays" "none"
    (posture_of
       (run
          ~base_path:"/nonexistent-rfc0390-base"
          ~keeper_name:"rfc0390-undeclared"
          ~client_label:"Claude Code"
          ~default:Runtime_native_tools.claude_code_default
          ~none_supported:true));
  (* full under the shared Auto default degrades to read, turn lives. *)
  check string "full under Auto degrades to read" "read"
    (posture_of
       (run
          ~base_path:"/nonexistent-rfc0390-base"
          ~keeper_name:"rfc0390-full-auto"
          ~client_label:"Claude Code"
          ~default:Runtime_native_tools.Native_full
          ~none_supported:true));
  (* none on a client without a disable switch degrades to read. *)
  check string "none on Codex degrades to read" "read"
    (posture_of
       (run
          ~base_path:"/nonexistent-rfc0390-base"
          ~keeper_name:"rfc0390-none-codex"
          ~client_label:"Codex"
          ~default:Runtime_native_tools.Native_none
          ~none_supported:false));
  (* Yolo + full is admitted as declared — but the shared registry resolves
     Auto for unknown keepers, so drive the honored path through read,
     which needs no approval stance. *)
  check string "read is admitted untouched" "read"
    (posture_of
       (run
          ~base_path:"/nonexistent-rfc0390-base"
          ~keeper_name:"rfc0390-read-codex"
          ~client_label:"Codex"
          ~default:Runtime_native_tools.Native_read
          ~none_supported:false))
;;

(* #30408 review: the two refusal branches have different lifetimes, so
   their reporting cadence must differ. [full] under a non-yolo approval
   mode is turn state — publish every affected turn. [none] on a client
   without a disable switch is a static profile-vs-assignment
   contradiction — publish once per process per (keeper, client) pair,
   then go quiet until a resolution honors the declaration. *)
let test_static_contradiction_reports_once_until_rearmed () =
  (* The Event_bus needs a running Eio scheduler; the heartbeat
     integration tests wrap bus setup in Eio_main.run the same way. *)
  Eio_main.run @@ fun _env ->
  (* One persistent subscription for the whole case: events published
     between drains queue in its buffer instead of being lost with no
     subscriber attached. *)
  let bus = Agent_core.Event_bus.create () in
  Event_bus_slots.set_masc bus;
  let subscription =
    Masc.Runtime_event_bus.subscribe
      ~capacity:32
      ~overflow:Agent_core.Event_bus.Drop_oldest
      ~purpose:"rfc0390-static-contradiction-test"
      bus
  in
  let drained_native_posture_events () =
    (* Publish routes through a fiber-owned queue; yield once so the
       pending deliveries reach the subscriber before the drain. *)
    Eio.Fiber.yield ();
    List.filter_map
      (fun (event : Agent_core.Event_bus.event) ->
        match event.Agent_core.Event_bus.payload with
        | Agent_core.Event_bus.Custom
            ("masc.keeper.native_posture_degraded", payload) -> Some payload
        | _ -> None)
      (Masc.Runtime_event_bus.drain subscription)
  in
  (* Counting the events proves they were sent; this reads what they say. The
     claim the degradation makes is that an operator can see which posture was
     asked for and which one runs, so those two fields are what a regression
     would quietly empty while the count stayed right. *)
  let posture_pair payload =
    let field name =
      match payload with
      | `Assoc fields ->
        (match List.assoc_opt name fields with
         | Some (`String value) -> value
         | Some _ | None -> failf "native posture event has no string %S" name)
      | _ -> failf "native posture event payload is not an object"
    in
    field "declared", field "effective"
  in
  let posture_of = function
    | Ok p -> Runtime_native_tools.to_string p
    | Error detail ->
      failf "runtime call must not die: %s"
        (Agent_core.Error.to_string detail)
  in
  (* All resolutions share one bus; the helper drains whatever arrived
     since the last drain. [full] must publish on BOTH turns (turn
     state); [none] exactly once across its four turns, and a previously
     gated pair must publish again after an honoring resolution re-arms
     the gate. *)
  (* [full] under Auto: per-turn publication, two turns -> two events. *)
  ignore
    (posture_of
       (Host.resolve_native_posture
          ~base_path:"/nonexistent-rfc0390-base"
          ~keeper_name:"rfc0390-full-auto-per-turn"
          ~client_label:"Claude Code"
          ~default:Runtime_native_tools.Native_full
          ~none_supported:true));
  ignore
    (posture_of
       (Host.resolve_native_posture
          ~base_path:"/nonexistent-rfc0390-base"
          ~keeper_name:"rfc0390-full-auto-per-turn"
          ~client_label:"Claude Code"
          ~default:Runtime_native_tools.Native_full
          ~none_supported:true));
  let full_events = drained_native_posture_events () in
  check int "full under Auto publishes per turn" 2 (List.length full_events);
  List.iter
    (fun payload ->
      let declared, effective = posture_pair payload in
      check string "the event names the posture that was declared" "full" declared;
      check string "the event names the posture that runs" "read" effective)
    full_events;
  (* [none] on Codex: static contradiction, four turns -> one event. *)
  for _ = 1 to 4 do
    ignore
      (posture_of
         (Host.resolve_native_posture
            ~base_path:"/nonexistent-rfc0390-base"
            ~keeper_name:"rfc0390-none-codex-static"
            ~client_label:"Codex"
            ~default:Runtime_native_tools.Native_none
            ~none_supported:false))
  done;
  check int "static none contradiction publishes once" 1
    (List.length (drained_native_posture_events ()));
  (* A honoring resolution for the same pair re-arms the gate. *)
  ignore
    (posture_of
       (Host.resolve_native_posture
          ~base_path:"/nonexistent-rfc0390-base"
          ~keeper_name:"rfc0390-none-codex-static"
          ~client_label:"Codex"
          ~default:Runtime_native_tools.Native_read
          ~none_supported:false));
  check int "honoring resolution publishes nothing" 0
    (List.length (drained_native_posture_events ()));
  for _ = 1 to 2 do
    ignore
      (posture_of
         (Host.resolve_native_posture
            ~base_path:"/nonexistent-rfc0390-base"
            ~keeper_name:"rfc0390-none-codex-static"
            ~client_label:"Codex"
            ~default:Runtime_native_tools.Native_none
            ~none_supported:false))
  done;
  check int "re-armed static contradiction publishes once again" 1
    (List.length (drained_native_posture_events ()));
  Masc.Runtime_event_bus.unsubscribe bus subscription
;;
;;

let () = Random.self_init ()

let reject_detail = "Your call to \"effect\": errors (fix these and call again)"

let test_pre_tool_reject_is_recorded () =
  with_active_raw_trace (fun ~path:_ ~active ->
    let pre_tool_rejects = ref [] in
    let hooks =
      { Agent_core.Hooks.empty with
        pre_tool_use = Some (fun _ -> Agent_core.Hooks.Block reject_detail)
      }
    in
    let executions = ref 0 in
    let tool, _terminal_error =
      one_dynamic_tool ~hooks ~pre_tool_rejects ~active (fun _input ->
        incr executions;
        Ok { Agent_core.Types.content = "never"; _meta = None })
    in
    let result = tool.call ~call_id:"call-reject-1" (`Assoc [ "k", `String "v" ]) in
    check bool "reject surfaces as a failed tool result" false result.success;
    check string "corrective text goes back to the CLI" reject_detail result.content;
    check int "the tool body never ran" 0 !executions;
    match !pre_tool_rejects with
    | [ reject ] ->
      check string "call id" "call-reject-1" reject.Host.call_id;
      check string "tool name" "effect" reject.Host.tool_name;
      check string "detail" reject_detail reject.Host.detail;
      check string "input" {|{"k":"v"}|} (Yojson.Safe.to_string reject.Host.input)
    | rejects ->
      fail (Printf.sprintf "expected one recorded reject, got %d" (List.length rejects)))
;;

(* One settlement for one decision.

   This host used to reach its own verdict for every pre_tool_use decision,
   and disagreed with AGENT_CORE's tool loop in two places: a hook that failed
   came back as an ordinary tool failure rather than a turn-level reject, and
   ElicitToolApproval was refused outright rather than offered to a
   caller-supplied approval callback. A keeper therefore got a different
   answer to the same hook depending on which runtime it was bound to. *)

let approval_tool ~active ?tool_approval ~executions () =
  let hooks =
    { Agent_core.Hooks.empty with
      pre_tool_use =
        Some
          (fun _ ->
            Agent_core.Hooks.ElicitToolApproval
              { question = "run the effect?"; because = "policy: effectful tool" })
    }
  in
  one_dynamic_tool ~hooks ?tool_approval ~active (fun _input ->
    incr executions;
    Ok { Agent_core.Types.content = "ran"; _meta = None })

let test_approved_tool_runs () =
  with_active_raw_trace (fun ~path:_ ~active ->
    let executions = ref 0 in
    let asked = ref [] in
    let tool_approval (request : Agent_core.Hooks.tool_approval_request) =
      asked := request.prompt.question :: !asked;
      Agent_core.Hooks.Approved
    in
    let tool, terminal_error =
      approval_tool ~active ~tool_approval ~executions ()
    in
    let result = tool.call ~call_id:"call-approve" (`Assoc []) in
    check bool "an approved call runs" true result.success;
    check int "and runs exactly once" 1 !executions;
    check (list string) "the callback saw the hook's question"
      [ "run the effect?" ] !asked;
    check (option string) "nothing terminal happened" None !terminal_error)

let test_denied_tool_is_a_repairable_failure_not_a_dead_turn () =
  with_active_raw_trace (fun ~path:_ ~active ->
    let executions = ref 0 in
    let tool, terminal_error =
      approval_tool ~active
        ~tool_approval:(fun _ -> Agent_core.Hooks.Denied)
        ~executions ()
    in
    let result = tool.call ~call_id:"call-deny" (`Assoc []) in
    check bool "a denied call fails" false result.success;
    check int "the tool body never ran" 0 !executions;
    (* Denial goes back to the model as a tool failure it can act on, the way
       a Block does. Killing the turn would leave the keeper unable to say
       anything about being refused. *)
    check (option string) "the turn is not killed" None !terminal_error)

let test_approval_without_a_callback_is_rejected_not_admitted () =
  with_active_raw_trace (fun ~path:_ ~active ->
    let executions = ref 0 in
    let tool, terminal_error =
      approval_tool ~active ~executions ()
    in
    let result = tool.call ~call_id:"call-no-callback" (`Assoc []) in
    check bool "the call fails" false result.success;
    check int "the tool body never ran" 0 !executions;
    (* Fail closed: a host with nowhere to ask must not decide on the
       operator's behalf. *)
    check bool "and the turn records why it stopped" true
      (Option.is_some !terminal_error))

let test_a_failed_hook_is_a_turn_level_reject () =
  with_active_raw_trace (fun ~path:_ ~active ->
    let hooks =
      { Agent_core.Hooks.empty with
        pre_tool_use =
          Some
            (fun _ ->
              Agent_core.Hooks.HookFailed
                { stage = Agent_core.Hooks.Pre_tool_use
                ; detail = "hook raised"
                })
      }
    in
    let executions = ref 0 in
    let tool, terminal_error =
      one_dynamic_tool ~hooks ~active (fun _input ->
        incr executions;
        Ok { Agent_core.Types.content = "never"; _meta = None })
    in
    let result = tool.call ~call_id:"call-hook-failed" (`Assoc []) in
    check bool "the call fails" false result.success;
    check int "the tool body never ran" 0 !executions;
    (* A hook that failed is not something the model can repair by calling
       differently, so it stops the turn rather than reading as one bad call.
       This host used to return it as an ordinary tool failure. *)
    check bool "the turn records why it stopped" true
      (Option.is_some !terminal_error))

let persistence_checkpoint ~session_id =
  Agent_core.Checkpoint.
    { version = checkpoint_version
    ; session_id
    ; agent_name = "reject-persistence"
    ; model = "test-model"
    ; system_prompt = None
    ; messages = [ Agent_core.Types.text_message Agent_core.Types.User "seed" ]
    ; usage = Agent_core.Types.empty_usage
    ; turn_count = 3
    ; created_at = 1_700_000_000.0
    ; tools = []
    ; tool_choice = None
    ; disable_parallel_tool_use = false
    ; temperature = None
    ; top_p = None
    ; top_k = None
    ; min_p = None
    ; enable_thinking = None
    ; preserve_thinking = None
    ; response_format = Agent_core.Types.Off
    ; thinking_budget = None
    ; reasoning_effort = None
    ; cache_system_prompt = false
    ; context = Agent_core.Context.create_sync ()
    ; mcp_sessions = []
    ; working_context = None
    }
;;

let reject ~call_id ~detail =
  { Host.call_id; tool_name = "keeper_broadcast"; input = `Assoc []; detail }
;;

let test_persist_appends_roundtrips_in_call_order () =
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let session_dir =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "reject-persist-%06x" (Random.bits ()))
  in
  Fs_compat.mkdir_p session_dir;
  let session_id = "trace-reject-persist" in
  (match
     Keeper_checkpoint_store.save_agent_core_classified
       ~session_dir
       (persistence_checkpoint ~session_id)
   with
   | Ok _ -> ()
   | Error detail -> fail ("seed checkpoint save failed: " ^ detail));
  (* The host records rejects newest-first; this list is exactly the
     ref shape a dead turn hands over. *)
  let rejects =
    [ reject ~call_id:"call-2" ~detail:"second correction"
    ; reject ~call_id:"call-1" ~detail:"first correction"
    ]
  in
  (match Host.persist_pre_tool_rejects ~session_dir ~session_id rejects with
   | Ok persisted -> check int "two rejects persisted" 2 persisted
   | Error detail -> fail ("persist failed: " ^ detail));
  match Keeper_checkpoint_store.load_agent_core ~session_dir ~session_id with
  | Error _ -> fail "checkpoint reload failed"
  | Ok checkpoint ->
    check int "seed + two round-trips" 5 (List.length checkpoint.messages);
    (match List.filteri (fun i _ -> i >= 1) checkpoint.messages with
     | [ use_1; result_1; use_2; result_2 ] ->
       let tool_use label (message : Agent_core.Types.message) expected_id =
         match message.content with
         | [ Agent_core.Types.ToolUse { id; name; _ } ] ->
           check string (label ^ " id") expected_id id;
           check string (label ^ " name") "keeper_broadcast" name
         | _ -> fail (label ^ " is not a single ToolUse block")
       in
       let tool_result
             label
             (message : Agent_core.Types.message)
             expected_id
             expected_detail
         =
         match message.content with
         | [ Agent_core.Types.ToolResult { tool_use_id; content; outcome; _ } ] ->
           check string (label ^ " tool_use_id") expected_id tool_use_id;
           check string (label ^ " content") expected_detail content;
           (match outcome with
            | Agent_core.Types.Tool_failed
                { failure_kind = Agent_core.Types.Validation_error
                ; error_class = Some Agent_core.Types.Deterministic
                } -> ()
            | _ ->
              fail (label ^ " outcome is not the deterministic validation failure"))
         | _ -> fail (label ^ " is not a single ToolResult block")
       in
       tool_use "first round-trip use" use_1 "call-1";
       tool_result "first round-trip result" result_1 "call-1" "first correction";
       tool_use "second round-trip use" use_2 "call-2";
       tool_result "second round-trip result" result_2 "call-2" "second correction"
     | _ -> fail "appended message window has the wrong shape")
;;

let test_persist_skips_when_no_checkpoint_exists () =
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let session_dir =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "reject-persist-empty-%06x" (Random.bits ()))
  in
  Fs_compat.mkdir_p session_dir;
  match
    Host.persist_pre_tool_rejects
      ~session_dir
      ~session_id:"trace-absent"
      [ reject ~call_id:"call-x" ~detail:"lost" ]
  with
  | Ok persisted ->
    check int "no replay exists to correct, so nothing persists" 0 persisted
  | Error detail -> fail ("missing checkpoint must not be an error: " ^ detail)
;;

let () =
  run
    "keeper official-client host"
    [ ( "native posture admission (RFC-0390)"
      , [ test_case
            "full requires yolo"
            `Quick
            test_native_full_requires_yolo
        ; test_case
            "none needs client support"
            `Quick
            test_native_none_needs_client_support
        ; test_case
            "read is admitted under Auto"
            `Quick
            test_native_read_is_effect_free_and_admitted
        ; test_case
            "resolve degrades instead of failing the turn"
            `Quick
            test_resolve_degrades_instead_of_failing_the_turn
        ; test_case
            "static contradiction reports once until re-armed"
            `Quick
            test_static_contradiction_reports_once_until_rearmed
        ] )
    ; ( "reasoning effort"
      , [ test_case
            "absent controls are omitted"
            `Quick
            test_absent_controls_are_omitted
        ; test_case
            "explicit efforts are preserved"
            `Quick
            test_explicit_efforts_are_preserved
        ; test_case
            "generic toggle is rejected"
            `Quick
            test_generic_toggle_is_rejected
        ; test_case
            "RAW start failure does not block tool"
            `Quick
            test_raw_start_failure_does_not_block_tool
        ; test_case
            "handoff observer failure preserves tool result"
            `Quick
            test_throwing_handoff_observer_preserves_result
        ; test_case
            "RAW observation preserves reserved exceptions"
            `Quick
            test_raw_observation_preserves_reserved_exceptions
        ; test_case
            "RAW finish failure preserves tool success"
            `Quick
            test_raw_finish_failure_does_not_reverse_tool_success
        ; test_case
            "cancellation records terminal RAW observation"
            `Quick
            test_cancellation_records_terminal_raw_observation
        ; test_case
            "repeated exact dynamic tool call aborts the turn"
            `Quick
            test_repeated_exact_dynamic_tool_call_aborts_the_turn
        ; test_case
            "dynamic tool progress does not trip repeat guard"
            `Quick
            test_dynamic_tool_progress_does_not_trip_the_repeat_guard
        ; test_case
            "repeated host stop is a checkpoint yield"
            `Quick
            test_repeated_tool_host_stop_is_a_checkpoint_yield
        ; test_case
            "host stop carries measured usage into the response"
            `Quick
            test_host_stop_carries_measured_usage_into_the_response
        ; test_case
            "terminal post-effect failure aborts official-client turn"
            `Quick
            test_terminal_post_effect_failure_aborts_the_official_client_turn
        ; test_case
            "ordinary post-effect failure aborts official-client turn"
            `Quick
            test_ordinary_post_effect_failure_aborts_the_official_client_turn
        ; test_case
            "terminal pre-effect failure stays correction-capable"
            `Quick
            test_terminal_pre_effect_failure_remains_correction_capable
        ; test_case
            "terminal external deferral keeps the turn going"
            `Quick
            test_terminal_external_deferral_keeps_the_turn_going
        ; test_case
            "terminal generic deferral keeps durable-stimulus stop"
            `Quick
            test_terminal_generic_deferral_keeps_durable_stimulus_stop
        ; test_case
            "terminal host stop preserves exact outcome"
            `Quick
            test_terminal_host_stop_preserves_completed_deferred_and_failed
        ; test_case
            "terminal host stop runs completion hooks in order"
            `Quick
            test_terminal_host_stop_runs_completion_hooks_in_order
        ] )
    ; ( "history encoding"
      , [ test_case
            "text history uses the single envelope"
            `Quick
            test_text_history_uses_the_single_envelope
        ; test_case
            "tool messages preserve canonical JSON"
            `Quick
            test_tool_message_is_preserved_as_canonical_json
        ; test_case
            "typed blocks preserve canonical JSON"
            `Quick
            test_typed_blocks_are_preserved_as_canonical_json
        ; test_case
            "ToolResult preserves structured content and failure provenance"
            `Quick
            test_tool_result_preserves_structured_content_and_failure_provenance
        ; test_case
            "reasoning and media blocks are strictly preserved"
            `Quick
            test_reasoning_and_media_blocks_are_strictly_preserved
        ; test_case
            "user content cannot spoof an adapter envelope"
            `Quick
            test_user_cannot_spoof_an_adapter_envelope
        ] )
    ; ( "start-turn seed budget"
      , [ test_case
            "extra context keeps typed provenance"
            `Quick
            test_extra_system_context_keeps_typed_provenance
        ; test_case
            "seed reaches the provider whole"
            `Quick
            test_seed_reaches_the_provider_whole
        ] )
    ; ( "pre_tool_use settles through one gate"
      , [ test_case
            "an approved call runs"
            `Quick
            test_approved_tool_runs
        ; test_case
            "a denied call fails without killing the turn"
            `Quick
            test_denied_tool_is_a_repairable_failure_not_a_dead_turn
        ; test_case
            "approval with no callback is rejected, not admitted"
            `Quick
            test_approval_without_a_callback_is_rejected_not_admitted
        ; test_case
            "a failed hook stops the turn"
            `Quick
            test_a_failed_hook_is_a_turn_level_reject
        ] )
    ; ( "reject round-trip persistence (masc#28885)"
      , [ test_case
            "pre_tool_use Block is recorded with its call identity"
            `Quick
            test_pre_tool_reject_is_recorded
        ; test_case
            "dead-turn rejects append to the checkpoint in call order"
            `Quick
            test_persist_appends_roundtrips_in_call_order
        ; test_case
            "missing checkpoint skips persistence"
            `Quick
            test_persist_skips_when_no_checkpoint_exists
        ] )
    ]
;;
