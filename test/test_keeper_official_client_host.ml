let frozen_librarian_position point : Masc.Keeper_turn_driver_try_provider.librarian_position =
  let snapshot=match point with
    | Masc.Keeper_turn_driver_try_provider.Librarian_snapshot snapshot -> snapshot.unread_messages
    | Masc.Keeper_turn_driver_try_provider.Librarian_progress _ | Masc.Keeper_turn_driver_try_provider.No_position -> [] in
  {point;unread=Masc.Keeper_librarian_request_unread.of_results ~snapshot:(Ok snapshot) ~memory:(Ok [])}
;;

open Alcotest
open Masc

module Effort = Llm_provider.Reasoning_effort
module Host = Keeper_official_client_host

(* A System with no amendments, as a turn without a basis issues it. *)
let system_of_text text =
  match
    Keeper_turn_system.issue ~held:None ~lane:Keeper_turn_system.Without_basis
      ~render:(fun (_ : World_constitution_types.t list) -> text) ~current:[]
      ~at:{ World_constitution_store.end_offset = 0; digest = "" }
      ~articles_at:(fun (_ : World_constitution_store.position) -> Ok None)
  with
  | Ok (system, (_ : Keeper_turn_system.held)) -> system
  | Error () -> Alcotest.fail "a turn without a basis reads no ledger"

(* What the operator's window currently says. The store takes the window as an
   argument -- it is reachable from a raw Domain, where reading a setting
   raises -- so every caller names it. These cases are not about the window and
   pass what production passes. *)
let history_retained () =
  Runtime_params.get Runtime_settings.keeper_checkpoint_history_retained

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
      ?base_path
      ?(terminal_effect_state = fun () ->
        Masc.Keeper_tools_agent_core.Terminal_effect_open)
      ?(hooks = Agent_core.Hooks.empty)
      ?(pre_tool_rejects = ref [])
      ?tool_approval
      ?on_result_handoff
      ?on_tool_boundary
      ?(runtime_label = "test")
      ?(name = "effect")
      (* Vision-capable unless a case says otherwise: these fixtures exercise
         delivery and settlement, and only the capability cases care. *)
      ?(accepts_image_input = true)
      ~active
      handler
  =
  let tool =
    Agent_core.Tool.create
      ?descriptor
      ~name
      ~description:"test effect"
      ~parameters:[]
      handler
  in
  let terminal_error = ref None in
  let projected =
    Host.dynamic_tools ~result_scope:None ?base_path
        ~accepts_image_input
        ~content_transport:Runtime_official_client_tool.Codex
      ~tool_approval
      ~runtime_label
      ~keeper_name:"keeper-raw-authority"
      ~turn_count:1
      ~tools:[ tool ]
      ~loading_plan:Host.All_on_demand
      ~hooks
      ~event_bus:None
      ~context_injector:None
      ~context:(Some (Agent_core.Context.create_sync ()))
      ~terminal_effect_state
      ~terminal_error
      ~pre_tool_rejects
      ?on_result_handoff
      ?on_tool_boundary
      ~raw_trace_run:(Some active)
      ()
  in
  match projected with
  | Ok ([ tool ], _) -> tool, terminal_error
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
          Ok { Agent_core.Types.content = "effect-complete"; content_blocks = None; _meta = None })
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
        Ok { Agent_core.Types.content = "effect-complete"; content_blocks = None; _meta = None })
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
  check bool "Sys.Break propagates" true raises_sys_break;
  List.iter (fun control ->
    let keeper_name = "raw-observer-driver-control" in
    let labels = ["keeper",keeper_name;"source","official_client_raw";"stage","context_submission"] in
    let failures () = Otel_metric_store.metric_value_or_zero
      Keeper_metrics.(to_string TraceEmitFailures) ~labels () in
    let before = failures () in
    let propagated =
      try
        ignore (Host.observe_raw_trace ~keeper_name ~stage:Host.Context_submission
          (fun () -> raise control));
        false
      with exn -> exn == control
    in
    check bool "driver control propagates unchanged through the real trace observer" true propagated;
    check bool "driver cancellation/deadline is not counted as a degraded trace sink" true
      (failures () = before))
    [Keeper_operator_interrupt.Operator_interrupt; Eio.Time.Timeout]
;;

let test_raw_finish_failure_does_not_reverse_tool_success () =
  with_active_raw_trace (fun ~path ~active ->
    let executions = ref 0 in
    let tool, terminal_error =
      one_dynamic_tool ~active (fun _input ->
        incr executions;
        break_trace_path path;
        Ok { Agent_core.Types.content = "effect-committed"; content_blocks = None; _meta = None })
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


let scoped_observation : Masc.Keeper_agent_result.tool_call_detail =
  let hash text = Agent_core_sha256.(digest_string text |> to_hex) in
  { tool_name = "effect"; provider = "fixture"; execution_outcome = Tool_result.Ok
  ; typed_outcome = None; latency_ms = 1.; task_id = None; route_evidence = None
  ; input_fingerprint = Some (hash "same-input")
  ; output_fingerprint = Some (hash "same-output") }
;;

let prepare_direct_execution () =
  let module Scope = Masc.Keeper_repetition_scope in
  let operation =
    match Keeper_chat_operation.Operation_id.of_string "host-scope-operation" with
    | Ok operation -> operation
    | Error _ -> fail "fixture operation ID rejected"
  in
  let execution = Scope.Execution.direct_operation operation in
  let source = Agent_core.Context.create_sync () in
  let target = Agent_core.Context.create_sync () in
  (match Scope.Execution.prepare execution ~source ~target with
   | Ok _ -> () | Error _ -> fail "first attempt admission failed");
  execution, source, target
;;

(* Stateful input can have an identical URL receipt after every action. *)
let test_repeated_browser_input_remains_deliverable () =
  let shift_enter = `Assoc ["action", `String "press_key"; "key", `String "Enter";
    "modifiers", `List [`String "Shift"]] in
  let text value = `Assoc ["action", `String "type_text"; "text", `String value] in
  let editing = [text "line one"; shift_enter; text "line two"; shift_enter;
    text "line three"; shift_enter; text "line four"] in
  let movement = List.init 6 (fun _ -> `Assoc ["action", `String "press_key";
    "key", `String "ArrowDown"]) in
  List.iter (fun runtime_label ->
    List.iter (fun with_boundary ->
      List.iter (fun inputs -> with_active_raw_trace (fun ~path:_ ~active ->
        let executed = ref [] and handed_off = ref 0 in
        let scope, _, target = prepare_direct_execution () in
        let on_tool_boundary = if with_boundary then
            Some (fun ~tool_name -> Masc.Keeper_agent_run.For_testing.official_client_tool_boundary
              ~repetition_execution:(Some scope) ~tool_name) else None in
        let tool, terminal_error = one_dynamic_tool ~active ~runtime_label ~name:"BrowserInteract"
          ?on_tool_boundary
          ~on_result_handoff:(fun ~invocation:_ ~content:_ ->
            incr handed_off;
            Masc.Keeper_repetition_scope.Execution.observe scope ~target scoped_observation)
          (fun input -> executed := input :: !executed;
            Ok {Agent_core.Types.content = "{\"tabId\":4,\"url\":\"https://example.test/editor\"}";
                content_blocks = None; _meta = None}) in
        List.iteri (fun i input ->
          let result = tool.call ~call_id:(Printf.sprintf "editor-%d" i) input in
          check bool "each input succeeds" true result.success;
          check bool "repeated receipt never invents a stop" true (Option.is_none result.abort_turn)) inputs;
        check bool "all intended inputs executed in order" true (List.rev !executed = inputs);
        check int "all results handed off" (List.length inputs) !handed_off;
        check (option string) "no fabricated terminal error" None !terminal_error)) [editing; movement])
      [false; true]) ["Codex"; "Claude Code"; "Antigravity"]
;;

let test_scoped_boundary_spans_official_attempts () =
  List.iter (fun runtime_label ->
    with_active_raw_trace (fun ~path:_ ~active ->
      let module Scope = Masc.Keeper_repetition_scope in
      let execution, source, previous_target = prepare_direct_execution () in
      Scope.Execution.observe execution ~target:previous_target scoped_observation;
      Scope.Execution.observe execution ~target:previous_target scoped_observation;
      let target = Agent_core.Context.create_sync () in
      (match Scope.Execution.prepare execution ~source ~target with
       | Ok () -> () | Error _ -> fail "next attempt lost scope");
      let executions = ref 0 in
      let boundary_calls = ref 0 in
      let tool, terminal_error = one_dynamic_tool ~active ~runtime_label
        ~on_result_handoff:(fun ~invocation:_ ~content:_ ->
          Scope.Execution.observe execution ~target scoped_observation)
        ~on_tool_boundary:(fun ~tool_name ->
          incr boundary_calls;
          Masc.Keeper_agent_run.For_testing.official_client_tool_boundary
            ~repetition_execution:(Some execution) ~tool_name)
        (fun _ -> incr executions;
          Ok { Agent_core.Types.content = "same-output"; content_blocks = None; _meta = None })
      in
      let result = tool.call ~call_id:"new-provider-first-call" (`Assoc []) in
      check int (runtime_label ^ " executes once") 1 !executions;
      check int "boundary follows handoff once" 1 !boundary_calls;
      check bool "prior observations do not synthesize a host stop" true (Option.is_none result.abort_turn);
      check (option string) "observation is not failure" None !terminal_error))
    [ "Codex"; "Claude Code"; "Antigravity" ]
;;

(* A malformed scope observation remains a real boundary error. *)
let test_scoped_boundary_error_stops_immediately () =
  List.iter (fun runtime_label ->
    with_active_raw_trace (fun ~path:_ ~active ->
      let module Scope = Masc.Keeper_repetition_scope in
      let execution, _source, target = prepare_direct_execution () in
      let tool, terminal_error = one_dynamic_tool ~active ~runtime_label
        ~on_result_handoff:(fun ~invocation:_ ~content:_ ->
          Scope.Execution.observe execution ~target
            { scoped_observation with input_fingerprint = Some "invalid-hash" })
        ~on_tool_boundary:(fun ~tool_name ->
          Masc.Keeper_agent_run.For_testing.official_client_tool_boundary
            ~repetition_execution:(Some execution) ~tool_name)
        (fun _ -> Ok { Agent_core.Types.content = "effect returned"; content_blocks = None; _meta = None })
      in
      let result = tool.call ~call_id:"invalid-scope-observation" (`Assoc []) in
      check bool "boundary error is latched" true (Option.is_some !terminal_error);
      check bool "boundary failure is not reported as success" false result.success;
      (match result.abort_turn with
       | Some (Terminal_tool_boundary { tool_name = "effect";
           outcome = Terminal_failed { failure_class = Tool_result.Runtime_failure;
             effect_disposition = Tool_result.Effect_outcome_unknown;
             detail =
               Keeper_terminal_effect_detail.Boundary_observation_failed
                 { model_tool_name = "effect"; cause } as detail } } as stop) ->
         (* The latch keeps agent-core's rendering; the typed cause keeps the
            payload, because [category] already says "internal". Same failure
            text, one without the family prefix. *)
         check bool "exact failure retained" true
           (String.ends_with
              ~suffix:cause.Keeper_request_failure_core.message
              (Option.value ~default:"" !terminal_error));
         (match Host.host_stop_result ~provider_turn_ordinal:23 ~runtime_id:runtime_label ~model:"fixture"
             ~session_id:"session" ~turn_id:"turn" ~turns_used:1
             ~latency_ms:None ~request_context:None stop with
          | Error error ->
            (match Keeper_internal_error.classify_masc_internal_error error with
             | Some (Terminal_effect_failed
                 { failure_class = Tool_result.Runtime_failure;
                   effect_disposition = Tool_result.Effect_outcome_unknown;
                   detail = projected }) ->
               check bool "typed outward detail" true (projected = detail)
             | _ -> fail "scope failure lost its typed effect disposition")
          | Ok _ -> fail "scope failure projected a completed result")
       | _ -> fail (runtime_label ^ " continued after scope observation failure"))))
    [ "Codex"; "Claude Code"; "Antigravity" ]
;;

(* RFC-0454 P1b: [Keeper_request_failure_core.message] is a sentence for
   people. A boundary observation that hands back a carried MASC error renders
   as prefixed JSON, which is the escaping this RFC removes, so the host keeps
   that error's one-line summary instead. *)
let test_a_carried_masc_boundary_error_keeps_no_json () =
  with_active_raw_trace (fun ~path:_ ~active ->
    let carried =
      Keeper_internal_error.core_error_of_masc_internal_error
        (Keeper_internal_error.Terminal_effect_failed
           { failure_class = Tool_result.Runtime_failure
           ; effect_disposition = Tool_result.Effect_outcome_unknown
           ; detail =
               Keeper_terminal_effect_detail.Composition_failed
                 { composition_tool = "keeper_compose_plan"
                 ; cause =
                     Keeper_terminal_effect_detail.Node_failed
                       { node_id = "press"
                       ; model_tool_name = "masc_msx_press"
                       ; message = "no MSX machine is loaded"
                       }
                 ; payload = `Assoc [ "settled", `List [ `String "press" ] ]
                 }
           })
    in
    let tool, _ = one_dynamic_tool ~active
      ~on_tool_boundary:(fun ~tool_name:_ -> Error carried)
      (fun _ -> Ok { Agent_core.Types.content = "effect returned"; content_blocks = None; _meta = None })
    in
    let result = tool.call ~call_id:"carried-masc-boundary" (`Assoc []) in
    match result.abort_turn with
    | Some (Terminal_tool_boundary
        { outcome = Terminal_failed
            { detail = Keeper_terminal_effect_detail.Boundary_observation_failed
                { cause; _ }
            ; _ }
        ; _ }) ->
      let message = cause.Keeper_request_failure_core.message in
      let contains needle =
        let n = String.length needle and t = String.length message in
        let rec loop i = i + n <= t && (String.sub message i n = needle || loop (i + 1)) in
        n = 0 || loop 0
      in
      check bool "no envelope prefix reached the message" false
        (contains "[masc_agent_core_error]");
      check bool "no escaped JSON document reached the message" false (contains "\\\"");
      check bool "the summary says what failed" true
        (contains "no MSX machine is loaded")
    | _ -> fail "a carried MASC boundary error did not stop the turn")
;;

let test_scoped_boundary_preserves_terminal_priority () =
  with_active_raw_trace (fun ~path:_ ~active ->
    let checks = ref 0 in
    let tool, _ = one_dynamic_tool ~active
      ~terminal_effect_state:(fun () ->
        Masc.Keeper_tools_agent_core.Terminal_effect_failed
          { failure_class = Tool_result.Runtime_failure
          ; effect_disposition = Tool_result.Proven_post_effect
          ; detail =
              Keeper_terminal_effect_detail.Tool_failed
                { internal_tool_name = "effect"; message = "exact committed effect failure" } })
      ~on_tool_boundary:(fun ~tool_name:_ -> incr checks;
        Ok (Some (Host.Terminal_tool_boundary
          { tool_name = "effect"; outcome = Durable_stimulus_deferred })))
      (fun _ -> Ok { Agent_core.Types.content = "effect returned"; content_blocks = None; _meta = None })
    in
    let result = tool.call ~call_id:"terminal-priority" (`Assoc []) in
    check int "terminal boundary still observes scope" 1 !checks;
    match result.abort_turn with
    | Some (Terminal_tool_boundary { outcome = Terminal_failed
        { effect_disposition = Tool_result.Proven_post_effect;
          detail =
            Keeper_terminal_effect_detail.Tool_failed
              { message = "exact committed effect failure"; _ }; _ }; _ }) -> ()
    | _ -> fail "a deferral stop replaced stronger terminal evidence")
;;

let test_explicit_boundary_observes_each_settled_call () =
  with_active_raw_trace (fun ~path:_ ~active ->
    let checks = ref 0 in
    let tool, _ = one_dynamic_tool ~active
      ~on_tool_boundary:(fun ~tool_name:_ -> incr checks; Ok None)
      (fun _ -> Ok { Agent_core.Types.content = "same"; content_blocks = None; _meta = None })
    in
    List.iter (fun index ->
      let result = tool.call ~call_id:(string_of_int index) (`Assoc []) in
      check bool "scope authority permits call" true (Option.is_none result.abort_turn))
      [ 1; 2; 3 ];
    check int "scope callback owns every decision" 3 !checks)
;;

let test_dynamic_tool_failures_do_not_invent_a_host_stop () =
  with_active_raw_trace (fun ~path:_ ~active ->
    let executions = ref 0 in
    let tool, terminal_error =
      one_dynamic_tool ~active (fun _input ->
        incr executions;
        (* Tool failures remain visible results for the provider. *)
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
    check int "all calls execute" 10 !executions;
    check (option string) "tool result does not synthesize a terminal stop" None !terminal_error)
;;

let test_boundary_preserves_explicit_terminal_outcomes () =
  let module Tools = Keeper_tools_agent_core in
  List.iter (fun terminal -> with_active_raw_trace (fun ~path:_ ~active ->
    let tool, _ = one_dynamic_tool ~active
      ~descriptor:(Agent_core.Tool.terminal_descriptor Agent_core.Tool_contract.Effect_outcome_unknown)
      ~terminal_effect_state:(fun () -> terminal)
      ~on_tool_boundary:(fun ~tool_name ->
        Keeper_agent_run.For_testing.official_client_tool_boundary
          ~repetition_execution:None ~tool_name)
      (fun _ -> Ok {Agent_core.Types.content = "settled"; content_blocks = None; _meta = None}) in
    let result = tool.call ~call_id:"terminal-effect" (`Assoc []) in
    match terminal, result.abort_turn with
    | Tools.Terminal_effect_completed _, Some (Terminal_tool_boundary {outcome = Terminal_completed; _})
    | Tools.Deferred_tool_result, Some (Terminal_tool_boundary {outcome = Durable_stimulus_deferred; _}) -> ()
    | Tools.External_effect_deferred, None -> ()
    | Tools.Terminal_effect_failed _, Some (Terminal_tool_boundary {outcome = Terminal_failed _; _}) -> ()
    | _ -> fail "the boundary replaced an explicit terminal outcome"))
    [ Tools.Terminal_effect_completed
        (Keeper_tool_execution.Surface_post_completed
          (Keeper_surface_post.To_discord {channel_id = "fixture-destination"}))
    ; Tools.Deferred_tool_result
    ; Tools.External_effect_deferred
    ; Tools.Terminal_effect_failed {failure_class = Tool_result.Runtime_failure;
        effect_disposition = Tool_result.Proven_post_effect;
        detail = Keeper_terminal_effect_detail.Tool_failed
          {internal_tool_name = "effect"; message = "committed effect failed"}}
    ]
;;

let test_settled_official_tool_keeps_turn_running () =
  with_active_raw_trace (fun ~path:_ ~active ->
    let handed_off = ref false in
    let boundary_calls = ref 0 in
    let tool, terminal_error =
      one_dynamic_tool ~active
        ~on_result_handoff:(fun ~invocation:_ ~content:_ -> handed_off := true)
        ~on_tool_boundary:(fun ~tool_name ->
          incr boundary_calls;
          check bool "tool result handed off before boundary decision" true !handed_off;
          Keeper_agent_run.For_testing.official_client_tool_boundary
            ~repetition_execution:None ~tool_name)
        (fun _ ->
          Ok { Agent_core.Types.content = "settled result"; content_blocks = None; _meta = None })
    in
    let result = tool.call ~call_id:"queued-after-tool" (`Assoc []) in
    check bool "tool succeeded" true result.success;
    check string "settled content remains intact" "settled result" result.content;
    check int "one boundary decision" 1 !boundary_calls;
    check (option string) "no terminal failure" None !terminal_error;
    match result.abort_turn with
    | None -> ()
    | Some (Terminal_tool_boundary _) ->
      fail "the official-client turn stopped after its tool result")
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
               ; detail =
                   Keeper_terminal_effect_detail.Tool_failed
                     { internal_tool_name = "effect"
                     ; message = "prior composition action committed"
                     }
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
    | None ->
      fail "post-effect terminal failure did not close the official-client loop")
;;

let test_terminal_media_delivery_failure_keeps_applied_effect () =
  with_active_raw_trace (fun ~path:_ ~active ->
    let state = ref Masc.Keeper_tools_agent_core.Terminal_effect_open in
    let handoff = ref None in
    let tool, _terminal_error = one_dynamic_tool
      ~descriptor:(Agent_core.Tool.terminal_descriptor Agent_core.Tool_contract.Effect_outcome_unknown)
      ~terminal_effect_state:(fun () -> !state)
      ~on_result_handoff:(fun ~invocation:_ ~content -> handoff := Some content)
      ~active (fun _ ->
        state := Masc.Keeper_tools_agent_core.Terminal_effect_completed
          (Masc.Keeper_tool_execution.Surface_post_completed
            (Masc.Keeper_surface_post.To_discord {channel_id="fixture-destination"}));
        Ok { Agent_core.Types.content="already-applied receipt"
           ; content_blocks=Some [Llm_provider.Types.Document
               {media_type="application/pdf";source=Base64 "Zml4dHVyZQ=="}]
           ; _meta=None }) in
    let result = tool.call ~call_id:"terminal-media" (`Assoc []) in
    check bool "failed delivery is settled as failure" false result.success;
    check (option string) "handoff retains delivery error and original receipt"
      (Some "official-client tool result cannot deliver document content\nalready-applied receipt") !handoff;
    match result.abort_turn with
    | Some (Terminal_tool_boundary
        {outcome=Terminal_failed
           {effect_disposition=Tool_result.Proven_post_effect
           ; detail=Keeper_terminal_effect_detail.Result_delivery_failed
               {message="official-client tool result cannot deliver document content"; _}
           ; _}; _} as stop) ->
      (match Host.host_stop_result ~provider_turn_ordinal:23 ~runtime_id:"official-fixture" ~model:"fixture"
        ~session_id:"session-media" ~turn_id:"turn-media" ~turns_used:1
        ~latency_ms:None ~request_context:None stop with
       | Error _ -> () | Ok _ -> fail "failed media delivery completed the runtime")
    | _ -> fail "completed producer effect hid failed media delivery")
;;

let image_result ~receipt ~media_type ~data _ =
  Ok { Agent_core.Types.content = receipt
     ; content_blocks =
         Some [ Llm_provider.Types.Image { media_type; source = Base64 data } ]
     ; _meta = None }
;;

let test_image_result_is_refused_when_the_model_takes_no_image () =
  with_active_raw_trace (fun ~path:_ ~active ->
    let handoff = ref None in
    let tool, _terminal_error = one_dynamic_tool
      ~accepts_image_input:false
      ~on_result_handoff:(fun ~invocation:_ ~content -> handoff := Some content)
      ~active
      (image_result ~receipt:"screenshot receipt" ~media_type:"image/png" ~data:"aW1n")
    in
    let result = tool.call ~call_id:"vision-denied" (`Assoc []) in
    check bool "an image a text-only model cannot read is not a success"
      false result.success;
    check (option string) "the refusal names the cause and keeps the receipt"
      (Some
         ("official-client tool result cannot deliver image content to a runtime \
           whose model does not accept image input\nscreenshot receipt"))
      !handoff)
;;

let test_image_result_reaches_a_model_that_accepts_images () =
  with_active_raw_trace (fun ~path:_ ~active ->
    let handoff = ref None in
    let tool, _terminal_error = one_dynamic_tool
      ~accepts_image_input:true
      ~on_result_handoff:(fun ~invocation:_ ~content -> handoff := Some content)
      ~active
      (image_result ~receipt:"screenshot receipt" ~media_type:"image/png" ~data:"aW1n")
    in
    let result = tool.call ~call_id:"vision-allowed" (`Assoc []) in
    check bool "a vision model still receives the image" true result.success;
    check (option string) "the receipt is untouched" (Some "screenshot receipt") !handoff)
;;

let test_dispatched_image_capability_survives_runtime_replacement () =
  List.iter (fun enabled -> with_active_raw_trace (fun ~path:_ ~active ->
    let saved = Runtime.For_testing.snapshot () in
    let config_path = Filename.temp_file "official-image-capability-" ".toml" in
    Fun.protect ~finally:(fun () -> Runtime.For_testing.restore saved; Unix.unlink config_path) (fun () ->
      let load enabled =
        Out_channel.with_open_bin config_path (fun out -> Printf.fprintf out {|[providers.official]
protocol = "claude-code"
command = "/bin/true"
is-non-interactive = true
[models.image]
api-name = "image-capability-fixture"
max-context = 400000
tools-support = true
[models.image.capabilities]
supports-image-input = %b
[official.image]
[runtime]
default = "official.image"
|} enabled);
        (match Runtime.init_default ~config_path with Ok () -> () | Error detail -> fail detail);
        match Runtime.get_runtime_by_id "official.image" with Some runtime -> runtime | None -> fail "image fixture not materialized" in
      let dispatched = load enabled in
        let replacement = load (not enabled) in
        check bool "replacement independently changes capability" (not enabled)
          (Runtime_agent.runtime_accepts_image_input ~runtime:replacement);
        let tool, _ = one_dynamic_tool
          ~accepts_image_input:(Runtime_agent.runtime_accepts_image_input ~runtime:dispatched)
          ~active (image_result ~receipt:"original runtime receipt" ~media_type:"image/png" ~data:"aW1n") in
        let result = tool.call ~call_id:"frozen-image-capability" (`Assoc []) in
        check bool "actual tool delivery follows dispatched runtime, not same-ID replacement" enabled result.success))) [true;false]
;;

let test_codex_tool_result_image_media_type_is_checked_before_settling () =
  with_active_raw_trace (fun ~path:_ ~active ->
    let handoff = ref None in
    let tool, _terminal_error = one_dynamic_tool
      ~on_result_handoff:(fun ~invocation:_ ~content -> handoff := Some content)
      ~active
      (image_result ~receipt:"diagram receipt" ~media_type:"image/svg+xml"
         ~data:"PHN2Zz48L3N2Zz4=")
    in
    let result = tool.call ~call_id:"svg" (`Assoc []) in
    check bool "a media type the app-server refuses is not a success"
      false result.success;
    check bool "the refusal names the media type and the accepted set" true
      (match !handoff with
       | None -> false
       | Some content ->
         let has needle =
           let n = String.length needle and h = String.length content in
           let rec scan i = i + n <= h && (String.sub content i n = needle || scan (i + 1)) in
           scan 0
         in
         has "image/svg+xml" && has "image/png" && has "diagram receipt"))
;;

let test_codex_tool_result_image_data_is_checked_before_settling () =
  with_active_raw_trace (fun ~path:_ ~active ->
    let tool, _terminal_error = one_dynamic_tool ~active
      (image_result ~receipt:"empty receipt" ~media_type:"image/png" ~data:"   ")
    in
    check bool "an image carrying no bytes is not a success" false
      (tool.call ~call_id:"empty-image" (`Assoc [])).success)
;;

(* The projector sends the blocks and never [content] when blocks are present,
   so a flat receipt that varies -- a timestamp, an elapsed duration -- used to
   change the fingerprint and let a model repeat an identical call forever. *)
let test_identical_structured_results_remain_deliverable () =
  with_active_raw_trace (fun ~path:_ ~active ->
    let calls = ref 0 in
    let tool, _terminal_error = one_dynamic_tool ~active (fun _ ->
      incr calls;
      Ok { Agent_core.Types.content = Printf.sprintf "elapsed %dms" !calls
         ; content_blocks = Some [ Llm_provider.Types.Text "the same structured answer" ]
         ; _meta = None })
    in
    let call index = tool.call ~call_id:(Printf.sprintf "repeat-%d" index) (`Assoc []) in
    check bool "the first call is not a repeat" true
      (Option.is_none (call 1).abort_turn);
    check bool "one exact retry may be deliberate" true
      (Option.is_none (call 2).abort_turn);
    let third = call 3 in
    check bool "identical structured answer remains deliverable" true (Option.is_none third.abort_turn);
    check bool "structured answer is preserved" true
      (third.content_blocks = Some [Llm_provider.Types.Text "the same structured answer"]))
;;

let test_text_only_results_remain_deliverable () =
  with_active_raw_trace (fun ~path:_ ~active ->
    let calls = ref 0 in
    let tool, _terminal_error = one_dynamic_tool ~active (fun _ ->
      incr calls;
      Ok { Agent_core.Types.content = Printf.sprintf "reading %d" !calls
         ; content_blocks = None
         ; _meta = None })
    in
    let call index = tool.call ~call_id:(Printf.sprintf "text-%d" index) (`Assoc []) in
    check bool "distinct text results remain deliverable" true
      (List.for_all (fun index -> Option.is_none (call index).abort_turn) [ 1; 2; 3 ]))
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
               ; detail =
                   Keeper_terminal_effect_detail.Tool_failed
                     { internal_tool_name = "effect"
                     ; message = "ordinary composition effect is indeterminate"
                     }
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
    | Some (Terminal_tool_boundary _) ->
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
    | None ->
      fail "generic deferral did not retain its durable-stimulus terminal stop")
;;

(* A host stop ends the turn before Claude Code's result frame, so the turn's
   spend is not observed. The newest assistant frame's output count is a
   streaming snapshot (2.1.280: 3 and 2 where the result frame said 270), so
   it must not stand in for the spend; only the input side that request
   occupied travels, apart from the response usage. *)
let test_host_stop_carries_request_context_not_spend () =
  let context : Runtime_observation.request_context =
    { input_tokens = 305
    ; cache = Some { cache_creation_input_tokens = 0; cache_read_input_tokens = 5 }
    ; output_tokens = None
    ; provenance = Turn_input_provenance.Measured_request }
  in
  let project request_context =
    match
      Host.host_stop_result ~provider_turn_ordinal:23
        ~runtime_id:"claude-code"
        ~model:"claude-fixture"
        ~session_id:"session-usage"
        ~turn_id:"turn-usage"
        ~turns_used:1
        ~latency_ms:(Some 900)
        ~request_context
        (Terminal_tool_boundary { tool_name = "terminal"; outcome = Terminal_completed })
    with
    | Ok result -> result
    | Error error -> fail (Agent_core.Error.to_string error)
  in
  let measured = project (Some context) in
  check bool "spend is not observed after a host stop" true
    (Option.is_none measured.response.usage);
  (match measured.runtime_observation with
   | None -> fail "host stop carried no runtime observation"
   | Some observation ->
     check bool "spend scope stays unavailable" true
       (observation.Runtime_observation.usage_scope
        = Runtime_usage_scope.Usage_scope_unavailable);
     check bool "request context reaches the observation" true
       (observation.Runtime_observation.request_context = Some context));
  let unmeasured = project None in
  (match unmeasured.runtime_observation with
   | None -> fail "host stop carried no runtime observation"
   | Some observation ->
     check bool "no request context stays absent" true
       (Option.is_none observation.Runtime_observation.request_context))
;;

let test_terminal_host_stop_preserves_completed_deferred_and_failed () =
  let project outcome =
    Host.host_stop_result ~provider_turn_ordinal:23
      ~runtime_id:"official-client-runtime"
      ~model:"official-client-model"
      ~session_id:"session-terminal"
      ~turn_id:"turn-terminal"
      ~turns_used:4
      ~latency_ms:(Some 250)
      ~request_context:None
      (Terminal_tool_boundary { tool_name = "terminal"; outcome })
  in
  (match project Terminal_completed with
   | Ok
       { Runtime_agent.stop_reason = Runtime_agent.Completed { provider_turn_ordinal = 23 }
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
           Runtime_agent.Yielded_to_durable_stimulus { turns_used = 4; provider_turn_ordinal = 23 }
       ; _
       } ->
     ()
   | Ok _ | Error _ -> fail "generic deferral changed outcome");
  match
    project
      (Terminal_failed
         { failure_class = Tool_result.Runtime_failure
         ; effect_disposition = Tool_result.Effect_outcome_unknown
         ; detail =
             Keeper_terminal_effect_detail.Tool_failed
               { internal_tool_name = "effect"; message = "terminal uncertainty" }
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
    Host.host_stop_result ~provider_turn_ordinal:23
      ~runtime_id:"official-client-runtime"
      ~model:"official-client-model"
      ~session_id:"session-terminal"
      ~turn_id:"turn-terminal"
      ~turns_used:4
      ~latency_ms:None
      ~request_context:None
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
  { origin = Llm_provider.Types.Conversation;  role; content; name = None; tool_call_id = None; metadata = [] }
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
      ; "origin", `String "conversation"
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

(* RFC-0468 §3.2: the input speaker is Librarian attribution. The official
   client reads this envelope as prompt text and its snapshot hashes cover it,
   so a stamped message encodes to the same bytes as an unstamped one. *)
let test_input_speaker_stays_out_of_the_envelope () =
  let plain =
    { (msg Agent_core.Types.User [ text "hello" ]) with
      metadata = [ "scope", `String "dashboard" ] }
  in
  let stamped =
    { plain with
      metadata =
        plain.metadata
        @ Keeper_input_speaker.metadata (Keeper_input_speaker.Person Keeper_input_speaker.Owner)
    }
  in
  check string "same envelope bytes"
    (Host.encode_history_message plain)
    (Host.encode_history_message stamped)
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
      ; "origin", `String "conversation"
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
      ; "origin", `String "conversation"
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
          { media_type = "image/png"; source = Url "image-data" }
      ; Document
          { media_type = "application/pdf"
          ; source = Stored (Agent_core.History.stored_of_raw "document-data")
          }
      ; Audio
          { media_type = "audio/wav"; source = File_id "audio-data" }
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
      ; "origin", `String "conversation"
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
                ; ( "source"
                  , `Assoc
                      [ "type", `String "stored"
                      ; "media_type", `String "application/pdf"
                      ; ( "sha256"
                        , `String
                            "90353ba2095e5b5d3251b5caea6b27df1e7e98b56b578ad09e296a6f34e38ed0" )
                      ; "bytes", `Int 13
                      ] )
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
    {|{"schema":"masc.official-client-context-message.v3","message":{"role":"tool"}}|}
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

(* A goal's stored images come back in the type every official-client runtime
   takes: the stored bytes as base64, in goal order, with the goal's texts
   joined by newlines. A source this process never read, and a block no
   transport projects, are refused rather than dropped. *)
let test_goal_images_are_read_back_as_the_runtimes_image_input () =
  let media_store = Agent_core.History.Memory_store.create () in
  let stored media_type raw =
    match media_store.Agent_core.History.put ~media_type ~raw with
    | Ok stored ->
      Agent_core.Types.Image { media_type; source = Agent_core.Types.Stored stored }
    | Error _ -> fail "the media store refused the image"
  in
  let project blocks =
    Host.text_and_images_of_blocks
      ~media_store ~runtime_label:"Codex" ~field:"goal_blocks" blocks
  in
  (match
     project
       [ text "first"
       ; stored "image/png" "png-bytes"
       ; text "second"
       ; stored "image/jpeg" "jpeg-bytes"
       ]
   with
   | Error _ -> fail "a goal of texts and stored images was refused"
   | Ok (prompt, images) ->
     check string "texts are joined in goal order" "first\nsecond" prompt;
     check
       (list (pair string string))
       "images keep goal order and carry the stored bytes as base64"
       [ "image/png", "cG5nLWJ5dGVz"; "image/jpeg", "anBlZy1ieXRlcw==" ]
       (List.map
          (fun (image : Runtime_official_client_tool.image_input) ->
            ( image.Runtime_official_client_tool.media_type
            , image.Runtime_official_client_tool.base64_data ))
          images);
     check
       (result unit string)
       "the shared turn image check accepts what the projection builds"
       (Ok ())
       (Runtime_official_client_tool.validate_image_inputs images));
  (match project [ text "only text" ] with
   | Error _ -> fail "a goal of text alone was refused"
   | Ok (prompt, images) ->
     check string "a goal of text alone is the text" "only text" prompt;
     check int "and carries no image" 0 (List.length images));
  let refusal blocks =
    match project blocks with
    | Ok _ -> fail "the goal was accepted"
    | Error error -> Agent_core.Error.category_label (Agent_core.Error.category error)
  in
  let configuration = Agent_core.Error.category_label Agent_core.Error.Config_category in
  let png source = Agent_core.Types.Image { media_type = "image/png"; source } in
  check string "an image that is a URL is a configuration error" configuration
    (refusal [ png (Agent_core.Types.Url "https://example.invalid/a.png") ]);
  check string "an image that is a provider file id is a configuration error"
    configuration
    (refusal [ png (Agent_core.Types.File_id "file-1") ]);
  check string "a block no transport projects is a configuration error" configuration
    (refusal [ text "kept"; Agent_core.Types.RedactedThinking "payload" ]);
  check string "an image the store does not hold is a media error"
    (Agent_core.Error.category_label Agent_core.Error.Media_category)
    (refusal
       [ png (Agent_core.Types.Stored (Agent_core.History.stored_of_raw "never put")) ])
;;


let msg role text : Agent_core.Types.message =
  { origin = Llm_provider.Types.Conversation;  role; content = [ Agent_core.Types.Text text ]; name = None
  ; tool_call_id = None; metadata = [] }
;;

let prepare messages =
  Host.prepare_turn ~composed_context:None
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

let prepare_prompt ?(hooks = None) ?(composed_context = None) system_prompt =
  Host.prepare_turn
    ~runtime_label:"Fixture"
    ~keeper_name:"prompt-fixture"
    ~turn_count:1
    ~system_prompt
    ~tools:[]
    ~initial_messages:[ msg Agent_core.Types.User "history" ]
    ~model_input_projection:None
    ~hooks
    ~composed_context
    ~configured_reasoning_effort:None
;;

(* The refusal is checked on the typed [InvalidConfig] field, not on a
   substring of the detail. *)
let check_refused_system_prompt what result =
  match result with
  | Error (Agent_core.Error.Config (Agent_core.Error.InvalidConfig { field; _ })) ->
    check string (what ^ " names the prompt field") "system_prompt" field
  | Error error ->
    fail (what ^ " failed elsewhere: " ^ Agent_core.Error.to_string error)
  | Ok _ -> fail (what ^ " was admitted")
;;

let test_blank_system_prompt_is_refused () =
  check_refused_system_prompt "a whitespace prompt" (prepare_prompt " \n\t ");
  check_refused_system_prompt "an empty prompt" (prepare_prompt "")
;;

(* The override is applied before the check, so a hook cannot blank the
   prompt past it either. *)
let test_hook_override_to_blank_system_prompt_is_refused () =
  let hooks =
    { Agent_core.Hooks.empty with
      before_turn_params =
        Some
          (fun _ ->
             Agent_core.Hooks.AdjustParams
               { Agent_core.Hooks.default_turn_params with
                 system_prompt_override = Some "   "
               })
    }
  in
  check_refused_system_prompt
    "a hook override to whitespace"
    (prepare_prompt ~hooks:(Some hooks) "SYS")
;;

(* A Goal is an observation, so its nonblank bytes cannot supply the Keeper
   instructions the official lane already requires. The assembly is published
   by the actual hook; reading it before that hook would miss this refusal. *)
let test_goal_observation_cannot_mask_blank_keeper_instructions () =
  let prepare_composed ~initial ~override () =
    let issued = ref None in
    let hooks = {Agent_core.Hooks.empty with before_turn_params=Some (function
      | Agent_core.Hooks.BeforeTurnParams {current_params;_} ->
        let current_params = {current_params with system_prompt_override=override} in
        let base_system_prompt = Option.value ~default:initial current_params.system_prompt_override in
        let partition = Keeper_context_layers.singleton Keeper_context_layers.Active_goals
            "Goal observation: current revision and reported measurement 1/3" in
        let assembly = Keeper_run_prompt.assemble_request_context ~checkpoint_owner:Runtime_execution.Official_client ~system:(system_of_text base_system_prompt)
            ~post_tool_round:false ~previous_assembly:None ~dynamic_context_partition:(Some partition)
            ~existing_extra_system_context:None
            ~blocks:[Prompt_block_id.Dynamic_context, Keeper_context_layers.text partition] in
        issued := Some assembly;
        Agent_core.Hooks.AdjustParams {current_params with
          extra_system_context=assembly.extra_system_context;
          system_prompt_override=Keeper_context_assembly.system_prompt_override
            ~previous:current_params.system_prompt_override assembly}
      | BeforeTurn _ | AfterTurn _ | PreToolUse _ | PostToolUse _ | PostToolUseFailure _
      | OnStop _ | OnError _ | OnToolError _ -> Agent_core.Hooks.Continue)} in
    let result = prepare_prompt ~hooks:(Some hooks)
        ~composed_context:(Some (fun () -> !issued)) initial in
    check bool "the actual hook issued an observation carrier" true
      (match !issued with
       | Some {system_prompt=Some {observations=_ :: _;_};_} -> true
       | Some _ | None -> false);
    result in
  List.iter (fun (initial, override) -> check_refused_system_prompt
      "observation over blank selected Keeper instructions"
      (prepare_composed ~initial ~override ()))
    ["",None; " \n\t ",None; "valid configured instructions",Some "";
     "valid configured instructions",Some " \n\t "];
  match prepare_composed ~initial:"" ~override:(Some "valid selected instructions") () with
  | Error error -> fail (Agent_core.Error.to_string error)
  | Ok prepared -> check bool "a valid selected override and its Goal remain admitted" true
      (String.starts_with ~prefix:"valid selected instructions\n\n" prepared.Host.system_prompt)
;;

let test_non_blank_system_prompt_reaches_the_lane_unchanged () =
  match prepare_prompt "  SYS with edges  " with
  | Error error -> fail (Agent_core.Error.to_string error)
  | Ok prepared ->
    check
      string
      "the prompt is passed through as given"
      "  SYS with edges  "
      prepared.Host.system_prompt
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
    Host.prepare_turn ~composed_context:None
      ~runtime_label:"Fixture"
      ~keeper_name:"provenance-fixture"
      ~turn_count:1
      ~system_prompt:"SYS"
      ~tools:[]
      ~initial_messages
      ~model_input_projection:
        (Some
           (fun ~tools:_ messages ->
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
      (carrier.origin = Agent_core.Types.System_context);
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

(* #36066 (audit F386): [resolve_native_posture] loads the keeper's
   declaration before it reads any posture, and refuses a keeper nothing
   declares. The posture cases below therefore run under a base path that
   declares every keeper they name. A declaration with no [tools.native]
   key leaves [native_tool_posture] unset, which is what lets the runtime
   default stand in the cases that rely on it. *)
let with_declared_keepers names body =
  let base_path = Filename.temp_file "official-client-posture-" "" in
  Sys.remove base_path;
  Unix.mkdir base_path 0o700;
  Fun.protect
    ~finally:(fun () -> Fs_compat.remove_tree base_path)
    (fun () ->
       List.iter
         (Masc_test_deps.declare_fixture_keeper ~base_path ~sandbox_profile:None)
         names;
       body ~base_path)
;;

(* A program-defined posture is a value, not a declaration: the base path
   does not exist and the host must not look there. *)
let test_required_native_none_never_degrades () =
  let resolve ~none_supported =
    Host.resolve_native_posture
      ~posture_source:(Runtime_native_tools.Program_defined Runtime_native_tools.Native_none)
      ~base_path:"/nonexistent-required-native-posture-base"
      ~keeper_name:"required-native-posture"
      ~client_label:"fixture"
      ~default:Runtime_native_tools.Native_read
      ~none_supported
  in
  (match resolve ~none_supported:true with
   | Ok Runtime_native_tools.Native_none -> ()
   | Ok _ -> fail "required none must override the normal runtime default"
   | Error error -> fail (Agent_core.Error.to_string error));
  match resolve ~none_supported:false with
  | Error (Agent_core.Error.Config
      (Agent_core.Error.InvalidConfig {field="required_native_posture"; _})) -> ()
  | Error error -> fail (Agent_core.Error.to_string error)
  | Ok _ -> fail "an unsupported required posture must never degrade to native reads"
;;

(* RFC-0390 admission review (P0): an admission refusal must not kill the
   turn. resolve_native_posture degrades to the safest weaker posture and
   records the downgrade as a typed event. The pure predicate above still
   refuses — the policy below keeps the runtime call alive. *)
let test_resolve_degrades_instead_of_failing_the_turn () =
  with_declared_keepers
    [ "rfc0390-default-posture"
    ; "rfc0390-full-auto"
    ; "rfc0390-none-codex"
    ; "rfc0390-read-codex"
    ]
  @@ fun ~base_path ->
  let run =
    Host.resolve_native_posture
      ~posture_source:Runtime_native_tools.Declared_on_disk
      ~base_path
  in
  let posture_of = function
    | Ok p -> Runtime_native_tools.to_string p
    | Error detail ->
      failf "runtime call must not die: %s"
        (Agent_core.Error.to_string detail)
  in
  (* A keeper nothing declares is refused on the profile field itself
     (#36066); this is the one outcome that is not a posture. *)
  (match
     run
       ~keeper_name:"rfc0390-undeclared"
       ~client_label:"Claude Code"
       ~default:Runtime_native_tools.claude_code_default
       ~none_supported:true
   with
   | Error (Agent_core.Error.Config
       (Agent_core.Error.InvalidConfig { field = "keeper.tools.native"; _ })) -> ()
   | Error error -> fail (Agent_core.Error.to_string error)
   | Ok posture ->
     failf "a keeper nothing declares resolved posture %s"
       (Runtime_native_tools.to_string posture));
  (* Declared with no [tools.native] key: the runtime default posture stands,
     admission is trivially satisfied, no degradation, no event. *)
  check string "declared without tools.native keeps the runtime default" "none"
    (posture_of
       (run
          ~keeper_name:"rfc0390-default-posture"
          ~client_label:"Claude Code"
          ~default:Runtime_native_tools.claude_code_default
          ~none_supported:true));
  (* full under the shared Auto default degrades to read, turn lives. *)
  check string "full under Auto degrades to read" "read"
    (posture_of
       (run
          ~keeper_name:"rfc0390-full-auto"
          ~client_label:"Claude Code"
          ~default:Runtime_native_tools.Native_full
          ~none_supported:true));
  (* none on a client without a disable switch degrades to read. *)
  check string "none on Codex degrades to read" "read"
    (posture_of
       (run
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
  with_declared_keepers
    [ "rfc0390-full-auto-per-turn"; "rfc0390-none-codex-static" ]
  @@ fun ~base_path ->
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
  with_declared_keepers
    [ "rfc0390-full-auto-per-turn"; "rfc0390-none-codex-static" ]
  @@ fun ~base_path ->
  (* [full] under Auto: per-turn publication, two turns -> two events. *)
  ignore
    (posture_of
       (Host.resolve_native_posture
          ~posture_source:Runtime_native_tools.Declared_on_disk
          ~base_path
          ~keeper_name:"rfc0390-full-auto-per-turn"
          ~client_label:"Claude Code"
          ~default:Runtime_native_tools.Native_full
          ~none_supported:true));
  ignore
    (posture_of
       (Host.resolve_native_posture
          ~posture_source:Runtime_native_tools.Declared_on_disk
          ~base_path
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
            ~posture_source:Runtime_native_tools.Declared_on_disk
            ~base_path
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
          ~posture_source:Runtime_native_tools.Declared_on_disk
          ~base_path
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
            ~posture_source:Runtime_native_tools.Declared_on_disk
            ~base_path
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
        Ok { Agent_core.Types.content = "never"; content_blocks = None; _meta = None })
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
          (fun event ->
            (match event with
             | Agent_core.Hooks.PreToolUse {usage; _} ->
               check bool "official host has no aggregate observation" true
                 (Option.is_none usage)
             | _ -> fail "expected pre-tool hook");
            Agent_core.Hooks.ElicitToolApproval
              { question = "run the effect?"; because = "policy: effectful tool" })
    }
  in
  one_dynamic_tool ~hooks ?tool_approval ~active (fun _input ->
    incr executions;
    Ok { Agent_core.Types.content = "ran"; content_blocks = None; _meta = None })

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
        Ok { Agent_core.Types.content = "never"; content_blocks = None; _meta = None })
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
    { provider_binding = None; version = checkpoint_version
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
    ; reasoning_effort = None
    ; cache_system_prompt = false
    ; context = Agent_core.Context.create_sync ()
    ; pending_input = None; mcp_sessions = []
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
     Keeper_checkpoint_store.save_agent_core_classified ~boundary:Agent_core.Checkpoint_objects.Turn_closes
       ~history_retained:(history_retained ())
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
  (match Host.persist_pre_tool_rejects ~keeper_name:"reject-keeper" ~session_dir ~session_id rejects with
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
      ~keeper_name:"reject-keeper"
      ~session_dir
      ~session_id:"trace-absent"
      [ reject ~call_id:"call-x" ~detail:"lost" ]
  with
  | Ok persisted ->
    check int "no replay exists to correct, so nothing persists" 0 persisted
  | Error detail -> fail ("missing checkpoint must not be an error: " ^ detail)
;;

(* {1 Where a start seed begins (창 RFC §7 (라), §10.4)} *)

module Snapshot = Librarian_continuity_snapshot
module Boundaries = Keeper_turn_boundaries
module Choice = Keeper_turn_driver_try_provider

let msg role text = Agent_core.Types.make_message ~role [ Agent_core.Types.Text text ]

let start_seed_trace = "official-front-trace"

(* Two atoms the Librarian absorbed, then one the keeper is still on. *)
let absorbed_messages =
  [ msg Agent_core.Types.User "Build the patch."
  ; msg Agent_core.Types.Assistant "The build passed."
  ]
;;

let start_seed_messages =
  absorbed_messages @ [ msg Agent_core.Types.User "Now review it." ]
;;

let working_state = "Build passed. Review is open."

let absorbed_boundary () : Boundaries.record =
  let position =
    match Boundaries.position_of_messages absorbed_messages with
    | Ok position -> position
    | Error detail -> fail detail
  in
  { recorded_at = 1.0
  ; event =
      Boundaries.Turn_ended
        { task_context = Masc.Keeper_turn_task_context.No_task; turn_ref = Ids.Turn_ref.make ~trace_id:start_seed_trace ~absolute_turn:1
        ; history_at_start = Boundaries.Fresh_history
        ; position
        }
  }
;;

let absorbed_snapshot () =
  match
    Snapshot.capture ~unread_messages:[]
      ~trace_id:start_seed_trace
      ~lines:[ 1, Ok (absorbed_boundary ()) ]
      ~messages:absorbed_messages
      ~working_state
  with
  | Ok snapshot -> snapshot
  | Error error -> fail (Snapshot.error_to_string error)
;;

let start_range_runtime = "claude_code.claude-sonnet-5"

let start_range
      ?(librarian_front = frozen_librarian_position Choice.No_position)
      ?(own_first_atom = 0)
      ?(turn_start = Keeper_carried_front.Turn_boundary { end_atom = 0 })
      ?carried_front_seed
      messages
  =
  Host.carried_start_range
    ~keeper_name:"alpha"
    ~runtime_id:start_range_runtime
    ~carried_front_seed
    ~librarian_front
    ~own_first_atom
    ~turn_start
    messages
;;

let texts messages =
  List.filter_map
    (fun (message : Agent_core.Types.message) ->
       match message.content with
       | [ Agent_core.Types.Text text ] -> Some text
       | _ -> None)
    messages
;;

(* The atoms the Librarian read are in the keeper's memory, so the seed starts
   after them and carries the working state in their place. *)
let test_a_start_seed_begins_at_the_librarian_position () =
  let snapshot = absorbed_snapshot () in
  let carried = start_range ~librarian_front:(frozen_librarian_position (Choice.Librarian_snapshot snapshot)) start_seed_messages in
  check int "the first atom is the one the Librarian did not read"
    snapshot.Snapshot.end_atom carried.Host.first_atom;
  check bool "the front says so" true
    (match carried.Host.front with
     | Host.Librarian_snapshot { absorbed_through; _ } ->
       absorbed_through = snapshot.Snapshot.end_atom
     | Host.Carried_seed _ | Host.Lane_cut | Host.Turn_start | Host.Turn_start_unknown _ | Host.Past_refused_start _
     | Host.Librarian_progress _ -> false);
  check string "and the log names it the same word the Agent Core lane logs"
    "librarian_snapshot"
    (Host.carried_start_front_to_string carried.Host.front);
  let carried_texts = texts carried.Host.messages in
  let ends_with ~suffix text =
    let extra = String.length text - String.length suffix in
    extra >= 0 && String.equal (String.sub text extra (String.length suffix)) suffix
  in
  check bool "the working state is carried" true
    (List.exists (ends_with ~suffix:working_state) carried_texts);
  check bool "the absorbed atoms are not" false
    (List.exists (String.equal "The build passed.") carried_texts);
  check bool "the atom the keeper is still on is" true
    (List.exists (String.equal "Now review it.") carried_texts)
;;

(* A reading that does not describe these messages leaves the lane's own
   front standing. *)
let test_a_seed_without_a_librarian_position_is_unchanged () =
  let carried = start_range start_seed_messages in
  check int "starts at the oldest atom" 0 carried.Host.first_atom;
  check bool "the turn start, which is 0 with no completed turn" true
    (match carried.Host.front with
     | Host.Turn_start -> true
     | Host.Carried_seed _ | Host.Lane_cut | Host.Turn_start_unknown _ | Host.Past_refused_start _ | Host.Librarian_snapshot _
     | Host.Librarian_progress _ -> false)
;;

(* RFC-librarian-lifecycle §4.10: a new session whose seed this runtime
   refused opens strictly after where that seed opened. The Librarian read
   two atoms; three more follow, and the last completed turn ended at 4. *)
let refused_seed_messages =
  absorbed_messages
  @ [ msg Agent_core.Types.User "Now review it."
    ; msg Agent_core.Types.Assistant "Reviewed."
    ; msg Agent_core.Types.User "Ship it."
    ]
;;

let refused_at ?(runtime_profile = start_range_runtime) first_atom =
  let front =
    match Runtime_model_input_tail_window.atom_opening_digest refused_seed_messages first_atom with
    | Some digest -> Model_input_front.At_atom digest
    | None -> fail "the fixture has no such atom"
  in
  { Keeper_carried_front.no_seed_read with
    refused_start = Some { runtime_profile; first_atom; front; turn = 7 }
  }
;;

let range_after_refusal ?(boundary = 4) refused =
  let snapshot = absorbed_snapshot () in
  ( snapshot.Snapshot.end_atom
  , start_range
      ~librarian_front:(frozen_librarian_position (Choice.Librarian_snapshot snapshot))
      ~turn_start:(Keeper_carried_front.Turn_boundary { end_atom = boundary })
      ~carried_front_seed:(fun () -> refused)
      refused_seed_messages )
;;

let is_past_refused_start (carried : Host.carried_start) =
  match carried.Host.front with
  | Host.Past_refused_start _ -> true
  | Host.Carried_seed _ | Host.Lane_cut | Host.Turn_start | Host.Turn_start_unknown _
  | Host.Librarian_snapshot _ | Host.Librarian_progress _ -> false
;;

let test_a_refused_seed_reopens_at_the_turn_boundary () =
  let librarian_end, carried = range_after_refusal (refused_at 2) in
  check int "the refused range opened at the Librarian point" 2 librarian_end;
  check int "the next range opens at this turn's boundary" 4 carried.Host.first_atom;
  check bool "and says why" true (is_past_refused_start carried);
  check bool "the refused atoms are not sent again" false
    (List.exists (String.equal "Now review it.") (texts carried.Host.messages))
;;

let test_a_refused_seed_without_a_later_boundary_keeps_the_newest_atom () =
  let _, carried = range_after_refusal ~boundary:2 (refused_at 2) in
  check int "the newest atom alone" 4 carried.Host.first_atom;
  check bool "past the refused start" true (is_past_refused_start carried);
  let _, at_the_end = range_after_refusal ~boundary:4 (refused_at 4) in
  check int "with no later atom the range does not widen back" 4 at_the_end.Host.first_atom
;;

let test_a_refusal_speaks_only_for_its_runtime_and_history () =
  let librarian_end, other_runtime =
    range_after_refusal (refused_at ~runtime_profile:"muse.other" 2)
  in
  check int "another runtime's refusal leaves the Librarian point" librarian_end
    other_runtime.Host.first_atom;
  let _, behind_the_librarian = range_after_refusal (refused_at 1) in
  check int "a refused start the Librarian passed is not read" librarian_end
    behind_the_librarian.Host.first_atom;
  let stale =
    let read = refused_at 2 in
    { read with
      Keeper_carried_front.refused_start =
        Option.map
          (fun (refused : Keeper_carried_front.refused_start) ->
             { refused with front = Model_input_front.At_atom (String.make 64 '0') })
          read.Keeper_carried_front.refused_start
    }
  in
  let _, other_history = range_after_refusal stale in
  check int "a refused start this history no longer opens is not read" librarian_end
    other_history.Host.first_atom
;;

let latest_log_seq () =
  match Log.Ring.recent ~limit:1 () with
  | [] -> -1
  | entry :: _ -> entry.Log.Ring.seq
;;

let warnings_for ~keeper_name ~since_seq =
  Log.Ring.recent ~since_seq ~min_level:(Log.level_to_int Log.Warn) ()
  |> List.filter (fun (entry : Log.Ring.entry) ->
    Option.equal String.equal entry.keeper_name (Some keeper_name))
  |> List.length
;;

(* An unknown turn start is reported by the range a lane sends, not by
   composing one: a Claude Code resume composes a range it never sends, and
   with a Librarian position in hand the unknown start decides nothing. *)
let test_an_unknown_turn_start_is_reported_by_the_range_sent () =
  let unknown = Keeper_carried_front.Turn_boundary_unknown { reason = "no end line matches" } in
  let before_opening = latest_log_seq () in
  let opened = start_range ~turn_start:unknown start_seed_messages in
  check bool "nothing else chose the start" true
    (match opened.Host.front with
     | Host.Turn_start_unknown _ -> true
     | Host.Carried_seed _ | Host.Lane_cut | Host.Turn_start | Host.Past_refused_start _
     | Host.Librarian_snapshot _ | Host.Librarian_progress _ -> false);
  check int "composing the range says nothing" 0
    (warnings_for ~keeper_name:"alpha" ~since_seq:before_opening);
  let before_sending = latest_log_seq () in
  Host.warn_if_sent_on_unknown_start ~keeper_name:"alpha" opened.Host.front;
  check int "sending it is reported once" 1
    (warnings_for ~keeper_name:"alpha" ~since_seq:before_sending);
  let decided =
    start_range
      ~librarian_front:(frozen_librarian_position (Choice.Librarian_snapshot (absorbed_snapshot ())))
      ~turn_start:unknown start_seed_messages
  in
  check bool "the Librarian position chose the start" true
    (match decided.Host.front with
     | Host.Librarian_snapshot _ -> true
     | Host.Carried_seed _ | Host.Lane_cut | Host.Turn_start | Host.Turn_start_unknown _ | Host.Past_refused_start _
     | Host.Librarian_progress _ -> false);
  let before_librarian = latest_log_seq () in
  Host.warn_if_sent_on_unknown_start ~keeper_name:"alpha" decided.Host.front;
  check int "a range the unknown start did not open is not reported" 0
    (warnings_for ~keeper_name:"alpha" ~since_seq:before_librarian)
;;

(* The Librarian read through the last completed turn, so the position names
   the atom this request has to answer. A range always carries the newest
   atom, so the position is clamped and that turn is sent again beside the
   summary — a request with a summary and nothing to answer is the view a
   provider refuses. *)
let test_a_fully_absorbed_history_still_carries_its_newest_atom () =
  let snapshot = absorbed_snapshot () in
  let carried = start_range ~librarian_front:(frozen_librarian_position (Choice.Librarian_snapshot snapshot)) absorbed_messages in
  check int "the range starts one atom before the position"
    (snapshot.Snapshot.end_atom - 1) carried.Host.first_atom;
  check bool "and still says the Librarian named the front" true
    (match carried.Host.front with
     | Host.Librarian_snapshot { absorbed_through; _ } ->
       absorbed_through = snapshot.Snapshot.end_atom
     | _ -> false);
  check bool "the newest atom is on the wire" true
    (List.exists (String.equal "The build passed.") (texts carried.Host.messages));
  check bool "and the absorbed atom before it is not" false
    (List.exists (String.equal "Build the patch.") (texts carried.Host.messages))
;;

(* The lane's own cut is later than what the Librarian read: the request must
   not widen back to the Librarian's position. *)
let test_a_later_lane_cut_wins () =
  let snapshot = absorbed_snapshot () in
  let carried =
    start_range
      ~librarian_front:(frozen_librarian_position (Choice.Librarian_snapshot snapshot))
      ~own_first_atom:(snapshot.Snapshot.end_atom + 1)
      start_seed_messages
  in
  check int "the later position stands" (snapshot.Snapshot.end_atom + 1) carried.Host.first_atom;
  check bool "and the front is the lane's" true
    (match carried.Host.front with
     | Host.Lane_cut -> true
     | _ -> false)
;;

(* The turn start is where a request with no absorbed point begins, so it is
   not weighed against the Librarian: a position behind the last completed
   turn still wins, and the atoms between the two go out instead of being
   neither carried nor summarised. *)
let test_a_librarian_position_behind_the_turn_start_still_wins () =
  let snapshot = absorbed_snapshot () in
  let carried =
    start_range
      ~librarian_front:(frozen_librarian_position (Choice.Librarian_snapshot snapshot))
      ~turn_start:(Keeper_carried_front.Turn_boundary { end_atom = snapshot.Snapshot.end_atom + 1 })
      start_seed_messages
  in
  check int "the range starts where the Librarian read" snapshot.Snapshot.end_atom
    carried.Host.first_atom;
  check bool "and the front is the Librarian's" true
    (match carried.Host.front with
     | Host.Librarian_snapshot { absorbed_through; _ } ->
       absorbed_through = snapshot.Snapshot.end_atom
     | Host.Carried_seed _ | Host.Lane_cut | Host.Turn_start | Host.Turn_start_unknown _ | Host.Past_refused_start _
     | Host.Librarian_progress _ -> false)
;;

(* The turn chose the Librarian's read position with no working state that
   fits (a purge, or a snapshot of another history): the range starts there
   and carries nothing for the atoms before it, which are in the keeper's
   memory -- the start the Agent Core lane takes for the same choice. *)
let test_a_read_position_alone_starts_the_range_without_a_working_state () =
  let end_atom = 2 in
  let carried =
    start_range
      ~librarian_front:(frozen_librarian_position (Choice.Librarian_progress { end_atom }))
      ~turn_start:(Keeper_carried_front.Turn_boundary { end_atom = 0 })
      start_seed_messages
  in
  check int "the range starts at the read position" end_atom carried.Host.first_atom;
  check bool "the front says so" true
    (match carried.Host.front with
     | Host.Librarian_progress { end_atom = at } -> at = end_atom
     | Host.Carried_seed _ | Host.Lane_cut | Host.Turn_start | Host.Turn_start_unknown _ | Host.Past_refused_start _
     | Host.Librarian_snapshot _ -> false);
  check string "and logs the Agent Core lane's word for it" "librarian_progress"
    (Host.carried_start_front_to_string carried.Host.front);
  let carried_texts = texts carried.Host.messages in
  check bool "the read atoms are not sent" false
    (List.exists (String.equal "The build passed.") carried_texts);
  check bool "the atom after the position is" true
    (List.exists (String.equal "Now review it.") carried_texts);
  check bool "no working state is invented" false
    (List.exists
       (String.starts_with ~prefix:"[Librarian working state:")
       carried_texts)
;;

(* A read position the lane's own cut has passed loses to the cut, like a
   snapshot's. *)
let test_a_read_position_behind_the_lane_cut_loses () =
  let carried =
    start_range
      ~librarian_front:(frozen_librarian_position (Choice.Librarian_progress { end_atom = 1 }))
      ~own_first_atom:2
      start_seed_messages
  in
  check int "the cut stands" 2 carried.Host.first_atom;
  check bool "and the front is the lane's" true
    (match carried.Host.front with
     | Host.Lane_cut -> true
     | Host.Carried_seed _ | Host.Turn_start | Host.Turn_start_unknown _ | Host.Past_refused_start _
     | Host.Librarian_snapshot _ | Host.Librarian_progress _ -> false)
;;

(* What the Memory screen records for a request this lane composed, in the
   Agent Core lane's words. A Librarian front records itself; any other front
   records the turn's choice, and a choice this request did not start from is
   [Not_applied], as a turn that made no choice is. *)
module Observation = Keeper_continuity_observation

let test_the_observation_records_the_front_or_why_the_choice_was_not_applied () =
  let snapshot = absorbed_snapshot () in
  let input ?continuity front =
    Host.continuity_observation_input ~trace_id:start_seed_trace ~continuity front
  in
  let chosen_snapshot =
    match Choice.prepare_continuity ~trace_id:start_seed_trace ~lines:[ 1, Ok (absorbed_boundary ()) ]
            ~messages:absorbed_messages snapshot with
    | Ok continuity -> continuity
    | Error error -> fail (Snapshot.error_to_string error)
  in
  (match
     input (Host.Librarian_snapshot { absorbed_through = snapshot.Snapshot.end_atom; boundary_line = 1 })
   with
   | Observation.Summarized { trace_id; end_atom; boundary_line } ->
     check string "the snapshot's trace" start_seed_trace trace_id;
     check int "the snapshot's end" snapshot.Snapshot.end_atom end_atom;
     check int "the boundary row the front names" 1 boundary_line
   | Observation.Absorbed _ | Observation.Without_snapshot | Observation.Not_applied ->
     fail "a working-state front was not recorded as summarized");
  (match input (Host.Librarian_progress { end_atom = 2 }) with
   | Observation.Absorbed { end_atom = 2; _ } -> ()
   | _ -> fail "a read-position front was not recorded as absorbed");
  (match input Host.Turn_start with
   | Observation.Not_applied -> ()
   | _ -> fail "a turn with no choice was not recorded as not applied");
  (match input ~continuity:Choice.without_snapshot Host.Turn_start with
   | Observation.Without_snapshot -> ()
   | _ -> fail "a turn whose choice was no absorbed point was not recorded so");
  match input ~continuity:chosen_snapshot Host.Lane_cut with
  | Observation.Not_applied -> ()
  | _ -> fail "a choice the lane cut passed was recorded as applied"
;;

(* #39445: the bundle's declaration decides each tool's loading; without one
   every tool keeps the on-demand shape the lanes had before. *)
let test_loading_plan_names_the_on_demand_tools () =
  let is_on_demand plan name =
    match Host.loading_of_plan plan name with
    | Runtime_official_client_tool.On_demand -> true
    | Runtime_official_client_tool.Upfront -> false
  in
  check bool "no declaration keeps a tool on demand" true
    (is_on_demand Host.All_on_demand "masc_board_post");
  let declared =
    Host.Declared { on_demand = [ "masc_board_post" ]; result_bounds = [] }
  in
  check bool "a named tool loads on demand" true
    (is_on_demand declared "masc_board_post");
  check bool "an unnamed tool loads upfront" false
    (is_on_demand declared "keeper_task_done")
;;

(* A result bound is declared only for a tool the bundle bounded, with that
   bound. A tool the bundle named no bound for declares nothing, so the
   client keeps its own threshold. *)
let test_result_bound_follows_the_bundle_bounds () =
  let bound plan name =
    match Host.result_bound_of_plan plan name with
    | Runtime_official_client_tool.Bounded_bytes bytes -> Some bytes
    | Runtime_official_client_tool.Unbounded -> None
  in
  let declared =
    Host.Declared
      { on_demand = [ "unbounded__search" ]
      ; result_bounds = [ "keeper_task_done", 16384 ]
      }
  in
  check (option int) "no declaration bounds nothing" None
    (bound Host.All_on_demand "keeper_task_done");
  check (option int) "a bounded tool declares its bound" (Some 16384)
    (bound declared "keeper_task_done");
  check (option int) "a tool with no bound in the plan declares none" None
    (bound declared "unbounded__search")
;;

let carrier_message text : Agent_core.Types.message =
  { origin = Llm_provider.Types.System_context;  role = System
  ; content = [ Text text ]
  ; name = None
  ; tool_call_id = None
  ; metadata = []
  }
;;

let carried_composed ~dynamic_text ~operator_text =
  let assembly = Keeper_context_assembly.assemble ~dynamic_context_partition:None ~existing_extra_system_context:None
    ~blocks:[Prompt_block_id.Dynamic_context,dynamic_text;Prompt_block_id.Operator_note,operator_text] in
  carrier_message (Option.get assembly.extra_system_context),assembly
;;

let test_issued_prefix_delivery_preserves_held_semantics () =
  let blocks = [Prompt_block_id.Memory_os_recall,"stable recall"] in
  let issued prefix = Keeper_run_prompt.assemble_extra_system_context ~dynamic_context_partition:None
    ~existing_extra_system_context:prefix ~blocks in
  let message assembly = carrier_message (Option.get assembly.Keeper_context_assembly.extra_system_context) in
  let rendered assembly = "SYSTEM:\n" ^ Host.encode_history_message (message assembly) ^ "\n\nGOAL" in
  List.iter (fun prefix ->
    let first = issued prefix in
    let initial = Host.resume_prompt ~turn_observation:None ~goal:"GOAL" ~held:[] ~composed_context:first [message first] in
    check string "unattributed prefix is delivered with whole carrier" (rendered first) initial.prompt;
    let repeated = Host.resume_prompt ~turn_observation:None ~goal:"GOAL" ~held:initial.held_context
      ~composed_context:first [message first] in
    check string "unchanged whole carrier follows existing held policy" "GOAL" repeated.prompt;
    let changed = issued (Some "changed prefix") in
    let replacement = Host.resume_prompt ~turn_observation:None ~goal:"GOAL" ~held:initial.held_context
      ~composed_context:changed [message changed] in
    check string "changed prefix with unchanged blocks is not lost" (rendered changed) replacement.prompt;
    let stale = Host.resume_prompt ~turn_observation:None ~goal:"GOAL" ~held:initial.held_context
      ~composed_context:first [message changed] in
    check string "stale issuer receipt falls back to complete carrier" (rendered changed) stale.prompt)
    [Some "prefix";Some ""];
  let first = issued None in
  let initial = Host.resume_prompt ~turn_observation:None ~goal:"GOAL" ~held:[] ~composed_context:first [message first] in
  let changed = Keeper_run_prompt.assemble_extra_system_context ~dynamic_context_partition:None ~existing_extra_system_context:None
    ~blocks:[Prompt_block_id.Memory_os_recall,"updated recall"] in
  check string "blocks-only change retains typed resend"
    (rendered changed)
    (Host.resume_prompt ~turn_observation:None ~goal:"GOAL" ~held:initial.held_context
       ~composed_context:changed [message changed]).prompt;
  let duplicate = Keeper_run_prompt.assemble_extra_system_context ~dynamic_context_partition:None ~existing_extra_system_context:None
    ~blocks:[Prompt_block_id.Memory_os_recall,"first";Prompt_block_id.Memory_os_recall,"second"] in
  let held = Host.start_held_context ~turn_observation:None ~composed_context:duplicate [message duplicate] in
  check int "duplicate block identities retain a single whole carrier" 1 (List.length held);
  check string "duplicate identities preserve every source byte"
    (rendered duplicate)
    (Host.resume_prompt ~turn_observation:None ~goal:"GOAL" ~held:[] ~composed_context:duplicate [message duplicate]).prompt
;;

(* The two recall blocks resume by their classes: the session holds the body
   it was sent, so the same bytes are not sent again, and the status line names
   its turn, so it goes on every resume. *)
let test_the_recall_blocks_resume_by_their_resend_classes () =
  let issued ~body ~status =
    Keeper_run_prompt.assemble_extra_system_context ~dynamic_context_partition:None
      ~existing_extra_system_context:None
      ~blocks:
        [ Prompt_block_id.Recalled_memory, body
        ; Prompt_block_id.Recalled_memory_status, status
        ]
  in
  let message assembly =
    carrier_message (Option.get assembly.Keeper_context_assembly.extra_system_context)
  in
  let has prompt fragment = String_util.contains_substring prompt fragment in
  let first = issued ~body:"BODY-ONE" ~status:"STATUS-ONE" in
  let initial = Host.resume_prompt ~turn_observation:None ~goal:"GOAL" ~held:[] ~composed_context:first [message first] in
  check bool "the first delivery carries both" true
    (has initial.prompt "BODY-ONE" && has initial.prompt "STATUS-ONE");
  let repeated = Host.resume_prompt ~turn_observation:None ~goal:"GOAL" ~held:initial.held_context
    ~composed_context:first [message first] in
  check bool "the same status line is sent again" true (has repeated.prompt "STATUS-ONE");
  check bool "the same body is not" false (has repeated.prompt "BODY-ONE");
  let next = issued ~body:"BODY-TWO" ~status:"STATUS-ONE" in
  let replaced = Host.resume_prompt ~turn_observation:None ~goal:"GOAL" ~held:initial.held_context
    ~composed_context:next [message next] in
  check bool "a changed body is sent" true (has replaced.prompt "BODY-TWO")
;;

(* A turn that chose nothing sends its status line alone. The session still
   holds the body it was last sent, so a later turn that chooses the same
   memories is not sent that body again, and its status line is. *)
let test_a_status_only_turn_between_two_identical_selections_keeps_the_held_body () =
  let issued blocks =
    Keeper_run_prompt.assemble_extra_system_context ~dynamic_context_partition:None
      ~existing_extra_system_context:None ~blocks
  in
  let message assembly =
    carrier_message (Option.get assembly.Keeper_context_assembly.extra_system_context)
  in
  let has prompt fragment = String_util.contains_substring prompt fragment in
  let chosen =
    issued
      [ Prompt_block_id.Recalled_memory, "BODY-ONE"
      ; Prompt_block_id.Recalled_memory_status, "STATUS-ONE"
      ]
  in
  let initial = Host.resume_prompt ~turn_observation:None ~goal:"GOAL" ~held:[] ~composed_context:chosen [message chosen] in
  let quiet = issued [ Prompt_block_id.Recalled_memory_status, "STATUS-NONE" ] in
  let between = Host.resume_prompt ~turn_observation:None ~goal:"GOAL" ~held:initial.held_context
    ~composed_context:quiet [message quiet] in
  check bool "the quiet turn sends its status line" true (has between.prompt "STATUS-NONE");
  check bool "and no body" false (has between.prompt "BODY-ONE");
  let again = Host.resume_prompt ~turn_observation:None ~goal:"GOAL" ~held:between.held_context
    ~composed_context:chosen [message chosen] in
  check bool "the same status line is sent again" true (has again.prompt "STATUS-ONE");
  check bool "the body the session still holds is not" false (has again.prompt "BODY-ONE")
;;

(* The log line a lane without a held set relies on to decide what a held set
   could skip: one entry per typed block, the digest changes with the bytes,
   and only the operator note is marked as sent on every resume. *)
let test_carried_summaries_name_blocks_and_digests () =
  let message, composed =
    carried_composed ~dynamic_text:"world state one" ~operator_text:"note"
  in
  let summaries = Host.carried_summaries ~turn_observation:None ~composed_context:composed [ message ] in
  check (list string) "one entry per block"
    [ "block:" ^ Prompt_block_id.to_string Prompt_block_id.Dynamic_context
    ; "block:" ^ Prompt_block_id.to_string Prompt_block_id.Operator_note
    ]
    (List.map (fun (item : Host.carried_summary) -> item.label) summaries);
  check (list bool) "only the operator note is always resent" [ false; true ]
    (List.map (fun (item : Host.carried_summary) -> item.resent_every_resume) summaries);
  List.iter
    (fun (item : Host.carried_summary) ->
       check int "digest prefix length" 12 (String.length item.sha256_prefix);
       check bool "rendered bytes are counted" true (item.bytes > 0))
    summaries;
  let again = Host.carried_summaries ~turn_observation:None ~composed_context:composed [ message ] in
  check bool "same input gives the same summaries" true (summaries = again);
  let changed_message, changed_composed =
    carried_composed ~dynamic_text:"world state two" ~operator_text:"note"
  in
  let changed =
    Host.carried_summaries ~turn_observation:None ~composed_context:changed_composed [ changed_message ]
  in
  let sha_of items =
    List.map (fun (item : Host.carried_summary) -> item.sha256_prefix) items
  in
  (match sha_of summaries, sha_of changed with
   | [ dynamic_before; operator_before ], [ dynamic_after; operator_after ] ->
     check bool "a changed block changes its digest" true
       (not (String.equal dynamic_before dynamic_after));
     check string "an unchanged block keeps its digest" operator_before operator_after
   | _ -> fail "both turns must split into two blocks")
;;

let test_carried_summaries_without_a_witness_name_one_carrier () =
  let message, _ = carried_composed ~dynamic_text:"world state" ~operator_text:"note" in
  check (list string) "an unwitnessed carrier is one entry" [ "carrier" ]
    (List.map
       (fun (item : Host.carried_summary) -> item.label)
       (Host.carried_summaries ~turn_observation:None [ message ]));
  check int "a conversation without carried contexts has none" 0
    (List.length (Host.carried_summaries ~turn_observation:None [ Agent_core.Types.user_msg "hi" ]))
;;

(* World State sections: a fixture whose standing sections (memory ledger,
   wiki, own Board posts, fleet messages) and inbox section (pending messages)
   can each be held fixed or changed between turns. *)
module Layers = Keeper_context_layers

let world_state ?(wiki = "WIKI-ONE") ?(fleet = "FLEET-ONE") ?board_posts ?mentions () =
  Layers.assemble ~content_of:(function
    | Layers.Workspace_memory -> Some "## Shared workspace memory ledger\nMEMORY-LEDGER\n\n"
    | Layers.Wiki -> Some ("## Workspace wiki\n" ^ wiki ^ "\n\n")
    | Layers.Own_board_posts ->
      Option.map (fun posts -> "### Your Recent Board Posts (1)\n" ^ posts ^ "\n\n") board_posts
    | Layers.Pending_mentions ->
      Option.map (fun mention -> "### Pending Messages (1)\n" ^ mention ^ "\n\n") mentions
    | Layers.Fleet_messages -> Some ("### Fleet Messages (1)\n" ^ fleet ^ "\n\n")
    | _ -> None)
  |> Layers.prepend_unattributed World_frame "## Current World State\nWORLD-FRAME\n\n"
;;

let world_state_turn ?partition_known world =
  let partition_known = Option.value partition_known ~default:true in
  let assembly =
    Keeper_context_assembly.assemble
      ~dynamic_context_partition:(if partition_known then Some world else None)
      ~existing_extra_system_context:None
      ~blocks:
        [ Prompt_block_id.Dynamic_context, Layers.text world
        ; Prompt_block_id.Temporal_summary, "CLOCK"
        ]
  in
  carrier_message (Option.get assembly.extra_system_context), assembly
;;

let resume ~held (message, assembly) =
  Host.resume_prompt ~turn_observation:None ~goal:"GOAL" ~held ~composed_context:assembly [ message ]
;;

let start_holding (message, assembly) =
  Host.start_held_context ~turn_observation:None ~composed_context:assembly [ message ]
;;

let section_names sources = List.map Layers.source_name sources

let contains text fragment = String_util.contains_substring text fragment

let use_markdown_prompts () =
  Prompt_registry.set_markdown_dir (Masc_test_deps.source_path "config/prompts")
;;

(* The vendor retains its first System prompt. A newly issued Goal snapshot
   therefore has to reach its Resume User prompt, independently of the extra
   carrier that the session already holds. This exercises the actual host
   preparation, held projection, codec and write-slot binding, not a vendor
   session or remote model. *)
let test_a_changed_system_goal_reaches_a_held_official_session () =
  let module A = Keeper_context_assembly in
  let owner = "Continue with the remaining work." in
  let prepare observation =
    let partition = match observation with
      | None -> Layers.unattributed Direct_turn "TASK GATE LANE"
      | Some text -> Layers.singleton Layers.Active_goals text
          |> fun goals -> Layers.append_unattributed goals Direct_turn "TASK GATE LANE" in
    let assembly = Keeper_run_prompt.assemble_request_context ~checkpoint_owner:Runtime_execution.Official_client
        ~system:(system_of_text "BASE_INSTRUCTIONS") ~post_tool_round:false ~previous_assembly:None
        ~dynamic_context_partition:(Some partition) ~existing_extra_system_context:None
        ~blocks:[Prompt_block_id.Dynamic_context, Layers.text partition] in
    let hooks = {Agent_core.Hooks.empty with before_turn_params=Some (function
      | Agent_core.Hooks.BeforeTurnParams {current_params;_} ->
        Agent_core.Hooks.AdjustParams {current_params with
          extra_system_context=assembly.extra_system_context;
          system_prompt_override=A.system_prompt_override ~previous:current_params.system_prompt_override assembly}
      | BeforeTurn _ | AfterTurn _ | PreToolUse _ | PostToolUse _ | PostToolUseFailure _
      | OnStop _ | OnError _ | OnToolError _ -> Agent_core.Hooks.Continue)} in
    let prepared = match Host.prepare_turn ~runtime_label:"held-goal-fixture"
        ~composed_context:(Some (fun () -> Some assembly))
        ~keeper_name:"held-goal" ~turn_count:1 ~system_prompt:"BASE_INSTRUCTIONS"
        ~tools:[] ~initial_messages:[Agent_core.Types.user_msg owner]
        ~model_input_projection:None ~hooks:(Some hooks) ~configured_reasoning_effort:None with
      | Ok prepared -> prepared | Error error -> fail (Agent_core.Error.to_string error) in
    assembly, prepared in
  let first_text = "Goal goal-observed; revision one; measurement initial=0/3" in
  let new_text = "Goal goal-observed; revision two; measurement new=1/4\n관측 \"reported_only\"" in
  let first, first_prepared = prepare (Some first_text) in
  check bool "Start actually issues its Goal in the System prompt" true
    (contains first_prepared.system_prompt first_text);
  let held = Host.start_held_context ~turn_observation:None ~composed_context:first first_prepared.messages in
  let resume assembly (prepared : Host.prepared_turn) held =
    Host.resume_prompt ~turn_observation:None ~goal:owner ~held ~composed_context:assembly prepared.messages in
  let same = resume first first_prepared held in
  check string "the first System observation is held without a duplicate Resume" owner same.prompt;
  let second, second_prepared = prepare (Some new_text) in
  check bool "the Goal stays out of the extra carrier's source blocks" false
    (List.mem_assoc Prompt_block_id.Active_goals second.blocks);
  let delivery = resume second second_prepared held in
  check string "changed Goal is a distinct User observation before the owner request"
    ("USER:\n" ^ Host.encode_history_message (Agent_core.Types.user_msg new_text) ^ "\n\n" ^ owner)
    delivery.prompt;
  List.iter (fun marker -> check bool "held non-Goal world state is not rebroadcast" false
    (contains delivery.prompt marker)) ["TASK";"GATE";"LANE";"BASE_INSTRUCTIONS";first_text];
  let repeated = resume second second_prepared delivery.held_context in
  check string "the updated revision is subsequently held" owner repeated.prompt;
  let absent, absent_prepared = prepare None in
  let added = resume second second_prepared
      (Host.start_held_context ~turn_observation:None ~composed_context:absent absent_prepared.messages) in
  check string "a Goal introduced after Start reaches Resume too" delivery.prompt added.prompt;
  let open Yojson.Safe.Util in
  let binding projected prompt = Keeper_context_submission_link.binding_to_json
      ~slot:Runtime_official_client_write.Whole_write projected
      (Runtime_official_client_write.raw prompt) in
  let issued = binding delivery.context_projection delivery.prompt in
  check string "the actual Resume slot matches" "matched_completed_slot"
    (issued |> member "status" |> to_string);
  let source = match issued |> member "occurrences" |> to_list with
    | [occurrence] -> occurrence |> member "source"
    | _ -> fail "exactly the changed Goal must be attributed" in
  check string "source is the System partition, not extra context" "system_prompt"
    (source |> member "source_carrier" |> to_string);
  check string "projection names the actual Resume User carrier" "official_resume_user_prompt"
    (source |> member "target_carrier" |> to_string);
  let physical = match second.system_prompt with Some value -> value | None -> fail "issued System missing" in
  check string "source receipt hashes the issued System bytes" physical.partition.sha256
    (source |> member "assembly" |> member "sha256" |> to_string);
  let span_index = match source |> member "source_span_indices" |> to_list with
    | [index] -> to_int index | _ -> fail "one typed Goal source span required" in
  let span = List.nth physical.partition.spans span_index in
  check string "the selected source span is exactly the new observation" new_text
    (String.sub physical.text span.offset span.bytes);
  let omitted = binding repeated.context_projection repeated.prompt in
  check bool "held omission retains explicit System source proof" true
    (List.exists (fun proof -> member "source_carrier" proof = `String "system_prompt")
      (omitted |> member "omitted_held" |> to_list));
  let stale = Keeper_context_submission_link.encoded_system_observation ~block:Prompt_block_id.Active_goals ~assembly:(Some first)
      (Agent_core.Types.user_msg new_text) in
  check string "an observation cannot borrow an older System receipt" "unavailable"
    (binding stale (Keeper_context_submission_link.text stale)
      |> member "issuer_attribution" |> member "status" |> to_string)
;;

(* Source is issued outside the User body and its Librarian-only metadata.
   Exercise the common assembler and actual official host preparation, then
   the held-session projection and its physical source receipt. *)
let test_direct_operation_source_reaches_official_start_and_resume () =
  use_markdown_prompts ();
  let module A = Keeper_context_assembly in
  let module Source = Keeper_direct_input_source in
  let module Speaker = Keeper_input_speaker in
  let module Session = Keeper_official_client_session_store in
  let operation raw = match Keeper_chat_operation.Operation_id.of_string raw with
    | Ok id -> id | Error detail -> fail detail in
  let peer_id = match Keeper_identity.Keeper_id.of_string "peer-source-sender" with
    | Some id -> id | None -> fail "valid fixture Keeper id" in
  let peer = Speaker.Person (Speaker.Keeper peer_id) in
  let local = Speaker.Person Speaker.Owner in
  let host = Speaker.Host_prompt Speaker.Official_client_resume in
  let peer_operation = operation "peer-source-operation" in
  let local_operation = operation "local-source-operation" in
  let body = "Inspect the queued task and report what you find." in
  let goal = "Goal source-observation-fixture; criterion unchanged\n\n" in
  let source_for operation_id speaker = Source.of_admitted_input ~operation_id ~speaker in
  let prepare ?(partition_known = true) source speaker user_message =
    let source_text = Option.map Source.render source in
    let partition = Layers.assemble ~content_of:(function
      | Layers.Active_goals -> Some goal
      | Layers.Direct_input_source -> source_text
      | Layers.Goal_observations | Layers.Goals_awaiting_proof | Layers.Current_task
      | Layers.Approval_authority | Layers.Connected_surfaces | Layers.Namespace_state
      | Layers.Workspace_memory | Layers.Wiki | Layers.Lane_updates | Layers.Autonomous_trigger
      | Layers.Scheduled_automation | Layers.Completion_authority | Layers.Task_cancellations
      | Layers.Pending_mentions | Layers.Scope_messages | Layers.Own_board_posts
      | Layers.Board_activity | Layers.Own_recent_actions | Layers.Recent_work
      | Layers.Fleet_messages -> None)
      |> fun partition -> Layers.append_unattributed partition Direct_turn "TASK GATE LANE" in
    let assembly = Keeper_run_prompt.assemble_request_context ~checkpoint_owner:Runtime_execution.Official_client
        ~system:(system_of_text "BASE_INSTRUCTIONS") ~post_tool_round:false ~previous_assembly:None
        ~dynamic_context_partition:(if partition_known then Some partition else None) ~existing_extra_system_context:None
        ~blocks:[Prompt_block_id.Dynamic_context, Layers.text partition] in
    let request = Agent_core.Types.make_message ~metadata:(Speaker.metadata speaker)
        ~role:Agent_core.Types.User [Agent_core.Types.Text user_message] in
    let hooks = {Agent_core.Hooks.empty with before_turn_params=Some (function
      | Agent_core.Hooks.BeforeTurnParams {current_params;_} ->
        Agent_core.Hooks.AdjustParams {current_params with
          extra_system_context=assembly.extra_system_context;
          system_prompt_override=A.system_prompt_override ~previous:current_params.system_prompt_override assembly}
      | BeforeTurn _ | AfterTurn _ | PreToolUse _ | PostToolUse _ | PostToolUseFailure _
      | OnStop _ | OnError _ | OnToolError _ -> Agent_core.Hooks.Continue)} in
    let prepared = match Host.prepare_turn ~runtime_label:"direct-input-source-fixture"
        ~composed_context:(Some (fun () -> Some assembly)) ~keeper_name:"source-recipient"
        ~turn_count:1 ~system_prompt:"BASE_INSTRUCTIONS" ~tools:[] ~initial_messages:[request]
        ~model_input_projection:None ~hooks:(Some hooks) ~configured_reasoning_effort:None with
      | Ok prepared -> prepared | Error error -> fail (Agent_core.Error.to_string error) in
    check bool "host preparation preserves the original User body and metadata" true
      (List.exists ((=) request) prepared.messages);
    assembly, prepared in
  let source = source_for peer_operation peer in
  let peer_text = Source.render source in
  let first, first_prepared = prepare (Some source) peer body in
  check bool "Start carries the exact admitted peer source in its System" true
    (contains first_prepared.system_prompt peer_text);
  check bool "the source carries the original operation id" true
    (contains peer_text "\"operation_id\":\"peer-source-operation\"");
  check bool "the source carries the typed registered Keeper identity" true
    (contains peer_text "\"speaker\":{\"kind\":\"keeper\",\"keeper_id\":\"peer-source-sender\"}");
  let issued = match first.system_prompt with
    | Some issued -> issued | None -> fail "issued System required" in
  check (list string) "Goal then operation source are independent System observations"
    ["active_goals"; "direct_input_source"]
    (List.map (fun observation -> A.observation_block observation |> fst |> Prompt_block_id.to_string)
       issued.observations);
  check bool "source is removed from the extra context carrier" false
    (contains (Option.value ~default:"" first.extra_system_context) peer_text);
  let after_tool = Keeper_run_prompt.assemble_request_context ~checkpoint_owner:Runtime_execution.Official_client
      ~system:(system_of_text "BASE_INSTRUCTIONS") ~post_tool_round:true ~previous_assembly:(Some first)
      ~dynamic_context_partition:None ~existing_extra_system_context:None
      ~blocks:[Prompt_block_id.Dynamic_context, "TRANSIENT-WORLD"] in
  check string "tool rounds retain the same Goal and original operation source"
    issued.text (A.effective_system_prompt ~base_text:"BASE_INSTRUCTIONS" after_tool);
  check bool "a tool round does not rebroadcast the transient world" false
    (contains (Option.value ~default:"" after_tool.extra_system_context) "TRANSIENT-WORLD");
  let held = Host.start_held_context ~turn_observation:None ~composed_context:first first_prepared.messages in
  let resume assembly (prepared : Host.prepared_turn) ~goal ~held =
    Host.resume_prompt ~turn_observation:None ~goal ~held ~composed_context:assembly prepared.messages in
  let cue = "Resume the original admitted operation without repeating completed effects." in
  let resumed, resumed_prepared = prepare (Some source) host cue in
  check bool "a host resume cue keeps the admitted operation's original peer source" true
    (contains resumed_prepared.system_prompt peer_text);
  let same = resume resumed resumed_prepared ~goal:cue ~held in
  check string "the same operation source is held without resending it" cue same.prompt;
  let local_source = source_for local_operation local in
  let local_text = Source.render local_source in
  let second, second_prepared = prepare (Some local_source) local body in
  let changed = resume second second_prepared ~goal:body ~held:same.held_context in
  check bool "a local request is explicitly a local request, without an operator claim" true
    (contains local_text "\"speaker\":{\"kind\":\"local_request\"}");
  check bool "peer to local transition delivers the new operation's source" true
    (contains changed.prompt (Host.encode_history_message (Agent_core.Types.user_msg local_text)));
  check bool "the old peer is not carried as the new operation's source" false
    (contains changed.prompt "peer-source-sender");
  let open Yojson.Safe.Util in
  let binding = Keeper_context_submission_link.binding_to_json
      ~slot:Runtime_official_client_write.Whole_write changed.context_projection
      (Runtime_official_client_write.raw changed.prompt) in
  check string "the delivered resume bytes bind to their actual write slot" "matched_completed_slot"
    (binding |> member "status" |> to_string);
  let proof = match binding |> member "occurrences" |> to_list with
    | [occurrence] -> member "source" occurrence
    | _ -> fail "only the changed operation source is delivered" in
  check string "resume delivery is attributed to the separate System carrier" "system_prompt"
    (proof |> member "source_carrier" |> to_string);
  let physical = match second.system_prompt with
    | Some issued -> issued | None -> fail "new operation System required" in
  let span_index = match proof |> member "source_span_indices" |> to_list with
    | [index] -> to_int index | _ -> fail "one operation-source span required" in
  let span = List.nth physical.partition.spans span_index in
  check bool "the proof names the operation source, independently of the Goal" true
    (span.kind = A.Block Prompt_block_id.Direct_input_source);
  check string "the exact proved source bytes are the new local operation source" local_text
    (String.sub physical.text span.offset span.bytes);
  let later_peer = source_for (operation "later-peer-operation") peer in
  let later, later_prepared = prepare (Some later_peer) peer body in
  let later_delivery = resume later later_prepared ~goal:body ~held:held in
  check bool "identical peer and User body still distinguish a new operation" true
    (contains later_delivery.prompt
       (Host.encode_history_message (Agent_core.Types.user_msg (Source.render later_peer))));
  let autonomous, autonomous_prepared = prepare None
      (Speaker.Host_prompt (Speaker.Autonomous_wake {answered_asks=[]})) "AUTONOMOUS-CUE" in
  let autonomous_delivery = resume autonomous autonomous_prepared ~goal:"AUTONOMOUS-CUE"
      ~held:changed.held_context in
  check bool "an autonomous turn issues no source for a prior direct operation" false
    (contains autonomous_prepared.system_prompt local_text);
  check bool "an autonomous turn does not deliver a prior direct source as current" false
    (contains autonomous_delivery.prompt "local-source-operation");
  let holds_source held = List.exists (fun (item : Session.held_context) ->
      item.context = Session.Context_block Prompt_block_id.Direct_input_source) held in
  check bool "a known autonomous partition retires the prior direct source's held receipt" false
    (holds_source autonomous_delivery.held_context);
  let reappeared = resume second second_prepared ~goal:body ~held:autonomous_delivery.held_context in
  check bool "a retired operation source is delivered again when it returns" true
    (contains reappeared.prompt (Host.encode_history_message (Agent_core.Types.user_msg local_text)));
  let unknown, unknown_prepared = prepare ~partition_known:false None
      (Speaker.Host_prompt (Speaker.Autonomous_wake {answered_asks=[]})) "UNKNOWN-PARTITION-CUE" in
  let unknown_delivery = resume unknown unknown_prepared ~goal:"UNKNOWN-PARTITION-CUE"
      ~held:changed.held_context in
  check bool "an unavailable renderer partition cannot retire a known source receipt" true
    (holds_source unknown_delivery.held_context);
  let host_observation = Source.render (source_for (operation "host-source-operation")
      (Speaker.Host_prompt (Speaker.Autonomous_wake {answered_asks=[Speaker.Keeper peer_id]}))) in
  check bool "a Host input projects its cue kind" true
    (contains host_observation "\"host_prompt\":\"autonomous_wake\"");
  check bool "a Host source does not forward embedded Ask speakers" false
    (contains host_observation "peer-source-sender");
  let external_speaker = Speaker.Person
      (Speaker.External {channel="chat";user_id=Some "external-7";user_name=Some "A \"quoted\" name"}) in
  let external_source = source_for (operation "external-source-operation") external_speaker in
  let external_assembly, external_prepared = prepare (Some external_source) external_speaker body in
  check bool "an external source keeps its known identity as structured data" true
    (contains external_prepared.system_prompt (Source.render external_source));
  check bool "an external source remains external" true
    (contains (Source.render external_source) "\"kind\":\"external\"");
  check bool "the new operation source has a distinct held identity" true
    (holds_source changed.held_context);
  check bool "the external source is also separate from the extra context" false
    (List.mem_assoc Prompt_block_id.Direct_input_source external_assembly.blocks)
;;

(* RFC-0491 §3.1: the issuer carries Completion Authority as a block of its
   context carrier, so the Agent Core System holds standing instructions only.
   An official client keeps the System-role carrier in the vendor's persistent
   System, so its turn takes the block out and delivers it as current-turn
   input on Start and on every Resume, proved by the issuer's carrier span. *)
let test_carrier_authority_is_current_turn_input_on_official_start_and_resume () =
  let module A = Keeper_context_assembly in
  let open Yojson.Safe.Util in
  let block = Prompt_block_id.Completion_authority in
  let text = "Approved task-approved; verification vrf-approved; authority operator-fixture" in
  let issue ?goal authority =
    let partition = Layers.assemble ~content_of:(function
      | Layers.Active_goals -> goal
      | Layers.Completion_authority -> authority
      | Layers.Fleet_messages -> Some "FLEET-WORLD"
      | _ -> None) in
    Keeper_run_prompt.assemble_request_context ~checkpoint_owner:Runtime_execution.Official_client ~system:(system_of_text "BASE")
      ~post_tool_round:false ~previous_assembly:None ~dynamic_context_partition:(Some partition)
      ~existing_extra_system_context:None
      ~blocks:[Prompt_block_id.Dynamic_context, Layers.text partition] in
  let prepare ?(goal = "OWNER") ?(issuer = Option.some) assembly =
    let reads = ref 0 in
    let hooks = {Agent_core.Hooks.empty with before_turn_params=Some (function
      | Agent_core.Hooks.BeforeTurnParams {current_params;_} ->
        Agent_core.Hooks.AdjustParams {current_params with
          extra_system_context=assembly.A.extra_system_context;
          system_prompt_override=A.system_prompt_override
            ~previous:current_params.system_prompt_override assembly}
      | BeforeTurn _ | AfterTurn _ | PreToolUse _ | PostToolUse _ | PostToolUseFailure _
      | OnStop _ | OnError _ | OnToolError _ -> Agent_core.Hooks.Continue)} in
    let prepared = match Host.prepare_turn ~runtime_label:"carrier-authority-fixture"
        ~composed_context:(Some (fun () -> incr reads; issuer assembly))
        ~keeper_name:"carrier-authority" ~turn_count:1 ~system_prompt:"BASE" ~tools:[]
        ~initial_messages:[Agent_core.Types.user_msg goal] ~model_input_projection:None
        ~hooks:(Some hooks) ~configured_reasoning_effort:None with
      | Ok prepared -> prepared | Error error -> fail (Agent_core.Error.to_string error) in
    check int "issuer acquired once per prepared turn" 1 !reads;
    prepared in
  let binding piece = Keeper_context_submission_link.binding_to_json
      ~slot:Runtime_official_client_write.Whole_write piece
      (Runtime_official_client_write.raw (Keeper_context_submission_link.text piece)) in
  let only_source piece = match binding piece |> member "occurrences" |> to_list with
    | [occurrence] -> member "source" occurrence
    | _ -> fail "exactly one authority source occurrence required" in
  let check_carrier_source label (issuer : A.t) source =
    let receipt = match issuer.receipt with Some receipt -> receipt | None -> fail "carrier receipt missing" in
    check string (label ^ ": the proof hashes the issuer's carrier") receipt.sha256
      (source |> member "assembly" |> member "sha256" |> to_string);
    let span = match source |> member "source_span_indices" |> to_list with
      | [index] -> List.nth receipt.spans (to_int index)
      | _ -> fail "one authority span required" in
    check bool (label ^ ": the proof names the authority span") true (span.kind = A.Block block);
    check string (label ^ ": the span bytes are the delivered authority") text
      (String.sub (Option.get issuer.extra_system_context) span.offset span.bytes) in
  let assembly = issue (Some text) in
  check string "the Agent Core System carries no authority" "BASE"
    (A.effective_system_prompt ~base_text:"BASE" assembly);
  check (option string) "the Agent Core carrier holds the authority block" (Some text)
    (List.assoc_opt block assembly.blocks);
  let prepared = prepare assembly in
  check string "the fixed Start System contains only standing instructions" "BASE"
    prepared.system_prompt;
  check bool "the System-role carrier no longer holds the authority" false
    (List.exists (fun message -> contains (Host.encode_history_message message) text)
       prepared.messages);
  check bool "the rest of the carrier stays" true
    (List.exists (fun message -> contains (Host.encode_history_message message) "FLEET-WORLD")
       prepared.messages);
  let start = Host.start_prompt prepared "OWNER" in
  let start_text = Keeper_context_submission_link.text start in
  check bool "the initial event is delivered once in front of the Start prompt" true
    (String.starts_with ~prefix:"SYSTEM:\n" start_text
     && String.ends_with ~suffix:"\n\nOWNER" start_text && contains start_text text);
  check_carrier_source "Start" assembly (only_source start);
  let turn_observation = prepared.turn_observation in
  let composed_context = prepared.composed_context in
  let held = Host.start_held_context ~turn_observation ?composed_context prepared.messages in
  check bool "the session never holds the authority" false
    (List.exists (fun (held : Keeper_official_client_session_store.held_context) ->
       held.context = Context_block block) held);
  let deliver held =
    Host.resume_prompt ~goal:"OWNER" ~held ~turn_observation ?composed_context prepared.messages in
  let first = deliver held in
  let second = deliver first.held_context in
  check bool "authority keeps its Sent_every_resume semantics" true
    (Prompt_block_id.resent_when_held block);
  check string "the authority is sent again with identical bytes" first.prompt second.prompt;
  check bool "Resume actually contains the authority" true (contains second.prompt text);
  check bool "held world state is not rebroadcast" false (contains second.prompt "FLEET-WORLD");
  check_carrier_source "Resume" assembly (only_source second.context_projection);
  let next = prepare ~goal:"NEXT" (issue None) in
  check string "a turn without an event has no Start observation" "NEXT"
    (Host.start_prompt next "NEXT" |> Keeper_context_submission_link.text);
  check bool "a turn without an event carries no turn observation" true
    (Option.is_none next.turn_observation);
  let next_resume = Host.resume_prompt ~turn_observation:None ~goal:"NEXT" ~held:second.held_context
      ?composed_context:next.composed_context next.messages in
  check bool "the next turn cannot replay the old approval" false (contains next_resume.prompt text);
  let changed_text = "Rejected task-other verification vrf-new authority operator-second" in
  let changed = prepare ~goal:"NEXT" (issue ~goal:"GOAL revision2" (Some changed_text)) in
  check string "the Goal keeps its Start System surface" "BASE\n\nGOAL revision2"
    changed.system_prompt;
  let changed_start = Host.start_prompt changed "NEXT" |> Keeper_context_submission_link.text in
  check bool "new correlation keys reach the Start prompt" true (contains changed_start changed_text);
  check bool "old correlation keys are not borrowed" false (contains changed_start text);
  let changed_resume = Host.resume_prompt ~goal:"NEXT" ~held:next_resume.held_context
      ~turn_observation:changed.turn_observation ?composed_context:changed.composed_context
      changed.messages in
  check bool "new correlation keys reach Resume" true (contains changed_resume.prompt changed_text);
  List.iter (fun (label, issuer) ->
    let unknown = prepare ~goal:"NEXT" ~issuer (issue (Some changed_text)) in
    check string (label ^ ": no Start observation is invented") "NEXT"
      (Host.start_prompt unknown "NEXT" |> Keeper_context_submission_link.text);
    check bool (label ^ ": the carrier is kept whole") true
      (List.exists (fun message -> contains (Host.encode_history_message message) changed_text)
         unknown.messages);
    check bool (label ^ ": an old event is not borrowed on Resume") false
      (contains (Host.resume_prompt ~turn_observation:None ~goal:"NEXT" ~held:[] ?composed_context:unknown.composed_context
                   unknown.messages).prompt text))
    ["missing issuer", (fun _ -> None); "stale issuer", (fun _ -> Some assembly)]
;;

(* The authority leaves the carrier on the carrier's own evidence. A turn
   whose sent System is not the issued one (no Goal observation, so nothing
   overrides the configured System) still keeps the authority out of the
   vendor's persistent System. *)
let prepare_authority_turn ~system_prompt assembly =
  let module A = Keeper_context_assembly in
  let hooks = {Agent_core.Hooks.empty with before_turn_params=Some (function
    | Agent_core.Hooks.BeforeTurnParams {current_params;_} ->
      Agent_core.Hooks.AdjustParams {current_params with
        extra_system_context=assembly.A.extra_system_context;
        system_prompt_override=A.system_prompt_override
          ~previous:current_params.system_prompt_override assembly}
    | BeforeTurn _ | AfterTurn _ | PreToolUse _ | PostToolUse _ | PostToolUseFailure _
    | OnStop _ | OnError _ | OnToolError _ -> Agent_core.Hooks.Continue)} in
  match Host.prepare_turn ~runtime_label:"carrier-authority-fixture"
      ~composed_context:(Some (fun () -> Some assembly))
      ~keeper_name:"carrier-authority" ~turn_count:1 ~system_prompt ~tools:[]
      ~initial_messages:[Agent_core.Types.user_msg "OWNER"] ~model_input_projection:None
      ~hooks:(Some hooks) ~configured_reasoning_effort:None with
  | Ok prepared -> prepared
  | Error error -> fail (Agent_core.Error.to_string error)
;;

let authority_text = "Approved task-approved; verification vrf-approved; authority operator-fixture"

(* Before RFC-0491 the authority text reached the System through
   [sanitize_text_utf8]; as a carrier block it keeps that. An official client
   JSON-encodes the carrier, and Yojson writes bytes from 0x80 up as given. *)
let test_carrier_authority_block_is_valid_utf8 () =
  let module A = Keeper_context_assembly in
  let truncated_dash = "\xE2\x80" in
  let partition = Layers.assemble ~content_of:(function
    | Layers.Completion_authority ->
      Some ("Approved task-cut " ^ truncated_dash ^ "; verification vrf-cut")
    | _ -> None) in
  let assembly = Keeper_run_prompt.assemble_request_context ~checkpoint_owner:Runtime_execution.Official_client ~system:(system_of_text "BASE")
      ~post_tool_round:false ~previous_assembly:None ~dynamic_context_partition:(Some partition)
      ~existing_extra_system_context:None
      ~blocks:[Prompt_block_id.Dynamic_context, Layers.text partition] in
  let authority = match List.filter (fun (id, _) ->
      Prompt_block_id.equal id Prompt_block_id.Completion_authority) assembly.A.blocks with
    | [(_, text)] -> text
    | _ -> fail "one authority block required" in
  check bool "the authority block is valid UTF-8" true (String.is_valid_utf_8 authority);
  check bool "the authority block keeps its text" true
    (contains authority "verification vrf-cut");
  match assembly.A.extra_system_context with
  | Some carrier -> check bool "the carrier is valid UTF-8" true (String.is_valid_utf_8 carrier)
  | None -> fail "carrier missing"
;;

let test_authority_leaves_the_carrier_when_the_sent_system_is_not_the_issued_one () =
  let partition = Layers.assemble ~content_of:(function
    | Layers.Completion_authority -> Some authority_text
    | Layers.Fleet_messages -> Some "FLEET-WORLD"
    | _ -> None) in
  let assembly = Keeper_run_prompt.assemble_request_context ~checkpoint_owner:Runtime_execution.Official_client ~system:(system_of_text "ISSUED BASE")
      ~post_tool_round:false ~previous_assembly:None ~dynamic_context_partition:(Some partition)
      ~existing_extra_system_context:None
      ~blocks:[Prompt_block_id.Dynamic_context, Layers.text partition] in
  let prepared = prepare_authority_turn ~system_prompt:"SENT BASE" assembly in
  check string "the sent System is the configured one" "SENT BASE" prepared.system_prompt;
  check bool "the System evidence does not borrow the issuer" true
    (Option.is_none prepared.composed_context);
  check bool "the System-role carrier no longer holds the authority" false
    (List.exists (fun message -> contains (Host.encode_history_message message) authority_text)
       prepared.messages);
  check bool "the rest of the carrier stays" true
    (List.exists (fun message -> contains (Host.encode_history_message message) "FLEET-WORLD")
       prepared.messages);
  check bool "the authority goes out with the Start prompt" true
    (contains (Host.start_prompt prepared "NEXT" |> Keeper_context_submission_link.text)
       authority_text)
;;

(* RFC-0491 §3.2 (f): a System kept with older articles sends the articles
   changed since it was rendered in the end context, on the turn's first
   round and again on every later round. *)
let amended_system () =
  use_markdown_prompts ();
  let article text =
    match
      World_constitution_types.make ~id:(World_constitution_types.Article_id.generate ()) ~text
        ~author:"lane-smith" ~at:1.0 ~evidence:[]
    with
    | Ok article -> article
    | Error invalid -> fail (World_constitution_types.invalid_to_string invalid) in
  let kept = article "open before you record" in
  let written = article "cite the ledger row, not the frame" in
  (* The first turn reads the ledger with [kept] alone; that position reads
     back the same list. *)
  let at_of articles : World_constitution_store.position =
    { end_offset = List.length articles; digest = "official-host-amendments" } in
  let articles_at (position : World_constitution_store.position) =
    Ok (if position.end_offset = 1 then Some [kept] else None) in
  let issue ~held front current =
    match
      Keeper_turn_system.issue ~held
        ~lane:(Keeper_turn_system.Agent_core { runtime_id = "official-host-amendments"; front })
        ~render:(fun articles -> "BASE\n" ^ World_constitution_render.articles articles) ~current
        ~at:(at_of current) ~articles_at
    with
    | Ok issued -> issued
    | Error () -> fail "the in-memory ledger does not fail" in
  let (_ : Keeper_turn_system.t), held =
    issue ~held:None Keeper_turn_system.No_previous_request [kept] in
  fst (issue ~held:(Some held) Keeper_turn_system.Same_front [kept; written]), written

let amendments_blocks (assembly : Keeper_context_assembly.t) =
  List.filter_map (fun (id, text) ->
      if Prompt_block_id.equal id Prompt_block_id.Constitution_amendments then Some text else None)
    assembly.blocks

let assemble_world_round ~system ~post_tool_round previous_assembly =
  let partition = Layers.assemble ~content_of:(function
    | Layers.Fleet_messages -> Some "FLEET-WORLD"
    | _ -> None) in
  Keeper_run_prompt.assemble_request_context ~checkpoint_owner:Runtime_execution.Official_client ~system ~post_tool_round ~previous_assembly
    ~dynamic_context_partition:(Some partition) ~existing_extra_system_context:None
    ~blocks:[Prompt_block_id.Dynamic_context, Layers.text partition]

let test_the_amendments_ride_every_round_of_the_turn () =
  let system, written = amended_system () in
  let amendments = match system.Keeper_turn_system.amendments with
    | Some text -> text
    | None -> fail "the written article is an amendment" in
  let first = assemble_world_round ~system ~post_tool_round:false None in
  check (list string) "the first round carries the block" [amendments] (amendments_blocks first);
  check bool "the block reaches the end context" true
    (match first.extra_system_context with
     | Some carrier -> contains carrier amendments
     | None -> false);
  check bool "the block names the written article" true
    (contains amendments (World_constitution_types.Article_id.to_string written.id));
  let later = assemble_world_round ~system ~post_tool_round:true (Some first) in
  check (list string) "a later round carries it again" [amendments] (amendments_blocks later)
;;

let test_a_system_without_amendments_carries_no_block () =
  let first = assemble_world_round ~system:(system_of_text "BASE") ~post_tool_round:false None in
  check int "no amendments, no block" 0 (List.length (amendments_blocks first));
  let later = assemble_world_round ~system:(system_of_text "BASE") ~post_tool_round:true (Some first) in
  check int "on no round" 0 (List.length (amendments_blocks later))
;;

(* A carrier whose only block is the authority leaves the messages whole; the
   carrier presence the turn expects agrees with what it hands the client. *)
let test_an_authority_only_carrier_is_not_expected_among_the_messages () =
  let module A = Keeper_context_assembly in
  let assembly =
    A.assemble ~dynamic_context_partition:None ~existing_extra_system_context:None
      ~blocks:[Prompt_block_id.Completion_authority, authority_text]
    |> A.with_system_observations ~base_text:"BASE" ~observations:[] in
  check bool "the issuer has a carrier" true (Option.is_some assembly.receipt);
  let prepared = prepare_authority_turn ~system_prompt:"BASE" assembly in
  check bool "no System-role carrier is handed to the client" false
    (List.exists (fun (message : Agent_core.Types.message) ->
         message.origin = Agent_core.Types.System_context) prepared.messages);
  let expected = Option.is_some (Host.transmitted_carrier_receipt assembly) in
  check bool "the turn expects no carrier" false expected;
  match Keeper_agent_prompt_metrics.provider_content_of_transmitted
      ~prompt_context_present:expected ~messages:prepared.messages with
  | Ok _ -> ()
  | Error failure ->
    fail ("transmitted input provenance: "
          ^ Keeper_agent_prompt_metrics.provenance_failure_reason failure)
;;

(* RFC-0491 §3.3: the Goals awaiting proof leave the official carrier with the
   authority, so the vendor's persistent System never keeps a Goal's phase
   past its turn. Both go out as current-turn input on Start, in carrier
   order, each proved by its own span of the issuer's carrier, and again on
   every Resume. *)
let test_goals_awaiting_proof_are_current_turn_input_on_official_start_and_resume () =
  let module A = Keeper_context_assembly in
  let open Yojson.Safe.Util in
  let awaiting_text = "### Goals Awaiting Proof (1)\n- goal-under-proof [proof pending]" in
  (* An official client JSON-encodes each message, so a containment check
     looks for a line of the block, not the block with its newline. *)
  let awaiting_line = "- goal-under-proof [proof pending]" in
  let issue ~awaiting =
    let partition = Layers.assemble ~content_of:(function
      | Layers.Goals_awaiting_proof -> awaiting
      | Layers.Completion_authority -> Some authority_text
      | Layers.Fleet_messages -> Some "FLEET-WORLD"
      | _ -> None) in
    Keeper_run_prompt.assemble_request_context ~checkpoint_owner:Runtime_execution.Official_client ~system:(system_of_text "BASE")
      ~post_tool_round:false ~previous_assembly:None ~dynamic_context_partition:(Some partition)
      ~existing_extra_system_context:None
      ~blocks:[Prompt_block_id.Dynamic_context, Layers.text partition] in
  let assembly = issue ~awaiting:(Some awaiting_text) in
  check string "the official issuer System carries no Goal phase" "BASE"
    (A.effective_system_prompt ~base_text:"BASE" assembly);
  check (option string) "the official issuer carrier holds the block" (Some awaiting_text)
    (List.assoc_opt Prompt_block_id.Goals_awaiting_proof assembly.blocks);
  let prepared = prepare_authority_turn ~system_prompt:"BASE" assembly in
  let carried needle = List.exists (fun message ->
      contains (Host.encode_history_message message) needle) prepared.messages in
  check bool "the System-role carrier no longer holds the Goals under proof" false
    (carried awaiting_line);
  check bool "nor the authority" false (carried authority_text);
  check bool "the rest of the carrier stays" true (carried "FLEET-WORLD");
  let start = Host.start_prompt prepared "OWNER" in
  let start_text = Keeper_context_submission_link.text start in
  check bool "the Start prompt carries both, the Goals under proof first" true
    (match String_util.find_substring start_text "goal-under-proof",
           String_util.find_substring start_text "vrf-approved" with
     | Some awaiting, Some authority -> awaiting < authority
     | None, _ | _, None -> false);
  check bool "and ends with the owner's prompt" true
    (String.starts_with ~prefix:"SYSTEM:\n" start_text
     && String.ends_with ~suffix:"\n\nOWNER" start_text);
  let receipt = match assembly.receipt with Some receipt -> receipt | None -> fail "carrier receipt missing" in
  let binding piece = Keeper_context_submission_link.binding_to_json
      ~slot:Runtime_official_client_write.Whole_write piece
      (Runtime_official_client_write.raw (Keeper_context_submission_link.text piece)) in
  let sourced_blocks piece = List.map (fun occurrence ->
      let source = member "source" occurrence in
      check string "the proof hashes the issuer's carrier" receipt.sha256
        (source |> member "assembly" |> member "sha256" |> to_string);
      match source |> member "source_span_indices" |> to_list with
      | [index] ->
        (match (List.nth receipt.spans (to_int index)).kind with
         | A.Block block -> Prompt_block_id.to_string block
         | A.Unattributed _ -> fail "a turn block proof names an unattributed span")
      | _ -> fail "one span per turn block")
      (binding piece |> member "occurrences" |> to_list) in
  check (list string) "each block is proved by its own carrier span"
    [ "goals_awaiting_proof"; "completion_authority" ] (sourced_blocks start);
  let turn_observation = prepared.turn_observation in
  let composed_context = prepared.composed_context in
  let held = Host.start_held_context ~turn_observation ?composed_context prepared.messages in
  check bool "the session never holds the Goals under proof" false
    (List.exists (fun (held : Keeper_official_client_session_store.held_context) ->
       held.context = Context_block Prompt_block_id.Goals_awaiting_proof) held);
  let deliver held =
    Host.resume_prompt ~goal:"OWNER" ~held ~turn_observation ?composed_context prepared.messages in
  let first = deliver held in
  let second = deliver first.held_context in
  check bool "every Resume carries the Goals under proof" true
    (contains first.prompt awaiting_line && contains second.prompt awaiting_line);
  check string "with the same bytes" first.prompt second.prompt;
  check (list string) "the Resume proofs name both spans"
    [ "goals_awaiting_proof"; "completion_authority" ] (sourced_blocks second.context_projection);
  let next = prepare_authority_turn ~system_prompt:"BASE" (issue ~awaiting:None) in
  check bool "a turn without a Goal under proof starts without the block" false
    (contains (Host.start_prompt next "NEXT" |> Keeper_context_submission_link.text) awaiting_line);
  check bool "and resumes without the old one" false
    (contains (Host.resume_prompt ~goal:"NEXT" ~held:second.held_context
                 ~turn_observation:next.turn_observation ?composed_context:next.composed_context
                 next.messages).prompt awaiting_line);
  let only_turn_blocks =
    A.assemble ~dynamic_context_partition:None ~existing_extra_system_context:None
      ~blocks:[Prompt_block_id.Goals_awaiting_proof, awaiting_text;
               Prompt_block_id.Completion_authority, authority_text]
    |> A.with_system_observations ~base_text:"BASE" ~observations:[] in
  check bool "a carrier holding only turn blocks is not expected among the messages" false
    (Option.is_some (Host.transmitted_carrier_receipt only_turn_blocks))
;;

(* One session: the wiki, the memory ledger and the Board posts stay the same
   from turn to turn while the fleet messages change. Only the changed section
   goes out, under the frame, and one line names the sections left out. *)
let test_a_resume_sends_only_the_changed_world_state_sections () =
  use_markdown_prompts ();
  let first = world_state_turn (world_state ~board_posts:"POSTS-ONE" ()) in
  let second = world_state_turn (world_state ~fleet:"FLEET-TWO" ~board_posts:"POSTS-ONE" ()) in
  let delivery = resume ~held:(start_holding first) second in
  check (list string) "the unchanged standing sections are left out"
    [ "workspace_memory"; "wiki"; "own_board_posts" ]
    (section_names delivery.unchanged_sections);
  check bool "the unchanged wiki is not sent again" false (contains delivery.prompt "WIKI-ONE");
  check bool "the unchanged memory ledger is not sent again" false
    (contains delivery.prompt "MEMORY-LEDGER");
  check bool "the unchanged Board posts are not sent again" false
    (contains delivery.prompt "POSTS-ONE");
  check bool "the changed fleet messages are sent" true (contains delivery.prompt "FLEET-TWO");
  check bool "the frame heads the sections that are sent" true
    (contains delivery.prompt "WORLD-FRAME");
  let notice =
    Host.unchanged_sections_notice delivery.unchanged_sections |> Result.get_ok
  in
  check bool "the prompt carries the line naming the left-out sections" true
    (contains delivery.prompt notice);
  let wiki_changed =
    world_state_turn (world_state ~wiki:"WIKI-TWO" ~fleet:"FLEET-TWO" ~board_posts:"POSTS-ONE" ())
  in
  let after = resume ~held:delivery.held_context wiki_changed in
  check (list string) "a changed wiki is no longer named as unchanged"
    [ "workspace_memory"; "own_board_posts"; "fleet_messages" ]
    (section_names after.unchanged_sections);
  check bool "the changed wiki is sent" true (contains after.prompt "WIKI-TWO");
  let same = resume ~held:after.held_context wiki_changed in
  check string "a World State the session holds whole sends the goal alone" "GOAL" same.prompt;
  check (list string) "nothing is named when nothing is sent" []
    (section_names same.unchanged_sections)
;;

(* The partial World State is still the issuer's bytes: the sections it sends,
   in order. Its attribution names the sections left out. *)
let test_a_partial_world_state_keeps_its_issuer_attribution () =
  use_markdown_prompts ();
  let open Yojson.Safe.Util in
  let first = world_state_turn (world_state ()) in
  let second = world_state_turn (world_state ~fleet:"FLEET-TWO" ()) in
  let delivery = resume ~held:(start_holding first) second in
  let notice = Host.unchanged_sections_notice delivery.unchanged_sections |> Result.get_ok in
  check bool "the host notice remains in the encoded prompt" true
    (contains delivery.prompt ("SYSTEM:\n" ^ Host.encode_history_message (carrier_message notice)));
  let binding =
    Keeper_context_submission_link.binding_to_json
      ~slot:Runtime_official_client_write.Whole_write
      delivery.context_projection
      (Runtime_official_client_write.raw delivery.prompt)
  in
  check string "the carrier attributes to its issuer" "verified"
    (binding |> member "issuer_attribution" |> member "status" |> to_string);
  match binding |> member "occurrences" |> to_list with
  | [ occurrence ] ->
    check string "the rendering names only left-out sections"
      "ordered_blocks_joined_by_two_newlines_without_held_world_state_sections"
      (occurrence |> member "source" |> member "rendering" |> to_string);
    check (list string) "the attribution names the sections left out"
      [ "workspace_memory"; "wiki" ]
      (occurrence |> member "source" |> member "omitted_world_state_sections"
       |> to_option to_list |> Option.value ~default:[] |> List.map to_string)
  | _ -> fail "the World State carrier must be one attributed occurrence"
;;

(* What arrived for this turn is sent again even when its bytes repeat: the
   same words from someone are a new message, not a copy the session holds. *)
let test_an_inbox_section_is_sent_on_every_resume () =
  use_markdown_prompts ();
  let turn = world_state_turn (world_state ~mentions:"MENTION" ()) in
  let delivery = resume ~held:(start_holding turn) turn in
  check bool "the repeated pending message is sent" true (contains delivery.prompt "MENTION");
  check (list string) "every standing section is left out"
    [ "workspace_memory"; "wiki"; "fleet_messages" ]
    (section_names delivery.unchanged_sections)
;;

(* A session that holds nothing -- a new session, a reset, a compaction --
   gets every section. A whole World State sent without its partition, and a
   section that left and came back, also make the session's earlier section
   copies stale, so those go out again too. *)
let test_every_world_state_section_goes_out_when_the_session_may_not_hold_it () =
  use_markdown_prompts ();
  let with_posts = world_state_turn (world_state ~board_posts:"POSTS-ONE" ()) in
  let fresh = resume ~held:[] with_posts in
  check (list string) "a session holding nothing is sent every section" []
    (section_names fresh.unchanged_sections);
  List.iter
    (fun body -> check bool (body ^ " is sent to a session holding nothing") true
        (contains fresh.prompt body))
    [ "WORLD-FRAME"; "MEMORY-LEDGER"; "WIKI-ONE"; "POSTS-ONE"; "FLEET-ONE" ];
  let without_posts = world_state_turn (world_state ()) in
  let gone = resume ~held:fresh.held_context without_posts in
  let back = resume ~held:gone.held_context with_posts in
  check bool "a section that came back is sent again" true (contains back.prompt "POSTS-ONE");
  check (list string) "a returning section is not named as unchanged"
    [ "workspace_memory"; "wiki"; "fleet_messages" ]
    (section_names back.unchanged_sections);
  let whole = resume ~held:back.held_context (world_state_turn ~partition_known:false (world_state ())) in
  check bool "the whole World State replaces the held sections" true
    (List.for_all
       (fun (held : Keeper_official_client_session_store.held_context) ->
          match held.context with
          | Keeper_official_client_session_store.(Context_section _ | Context_section_row _) -> false
          | Keeper_official_client_session_store.(
              Context_block _ | Context_carrier | Librarian_working_state | Librarian_unread
              | Historical_task_reference | Tool_result_receipts | Codex_system_prompt) -> true)
       whole.held_context);
  let after_whole = resume ~held:whole.held_context (world_state_turn (world_state ())) in
  check (list string) "after a whole World State every section is sent again" []
    (section_names after_whole.unchanged_sections);
  check bool "the wiki is sent again after a whole World State" true
    (contains after_whole.prompt "WIKI-ONE")
;;

(* Recent actions: one row per recorded turn under a head that counts them, as
   [Keeper_unified_prompt] renders it. The window moves one turn at a time. *)
let action_row turn = Printf.sprintf "- [turn %d] Execute -> ok\n" turn

let world_state_with_actions ?(head_note = "") ?(row = action_row) turns =
  let rows = List.map row turns in
  Layers.assemble_prepared ~content_of:(function
    | Layers.Workspace_memory ->
      Some (Layers.prepare_content "## Shared workspace memory ledger\nMEMORY-LEDGER\n\n")
    | Layers.Own_recent_actions ->
      Some
        (Layers.prepare_rows
           ~head:(Printf.sprintf "### Your Recent Actions (%d turns)\n%s" (List.length rows) head_note)
           ~rows ~tail:"\n")
    | Layers.Fleet_messages -> Some (Layers.prepare_content "### Fleet Messages (1)\nFLEET-ONE\n\n")
    | _ -> None)
  |> Layers.prepend_unattributed World_frame "## Current World State\nWORLD-FRAME\n\n"
;;

let sends delivery turn = contains delivery.Host.prompt (Printf.sprintf "[turn %d]" turn)

let held_row_count (delivery : Host.resume_delivery) =
  List.length
    (List.filter
       (fun (held : Keeper_official_client_session_store.held_context) ->
          match held.context with
          | Keeper_official_client_session_store.Context_section_row _ -> true
          | Keeper_official_client_session_store.(
              Context_block _ | Context_section _ | Context_carrier | Librarian_working_state
              | Librarian_unread | Historical_task_reference | Tool_result_receipts
              | Codex_system_prompt) -> false)
       delivery.held_context)
;;

(* #45131: the window of recent actions changes on every turn, so compared as
   one text it went out whole on every resume and piled up in the session.
   Compared row by row, a resume sends the head, the rows the session lacks
   and the tail, and one line says the earlier rows still hold. *)
let test_a_resume_sends_only_the_recent_action_rows_the_session_lacks () =
  use_markdown_prompts ();
  let first = world_state_turn (world_state_with_actions [ 1; 2; 3 ]) in
  let second = world_state_turn (world_state_with_actions [ 2; 3; 4 ]) in
  let delivery = resume ~held:(start_holding first) second in
  check bool "the new row is sent" true (sends delivery 4);
  List.iter
    (fun turn ->
       check bool (Printf.sprintf "held row %d is not sent again" turn) false (sends delivery turn))
    [ 2; 3 ];
  check bool "the head goes out with the new row" true
    (contains delivery.prompt "### Your Recent Actions (3 turns)");
  check (list string) "recent actions is named as sent in part" [ "own_recent_actions" ]
    (section_names delivery.partly_held_sections);
  check (list string) "the unchanged standing sections are left out"
    [ "workspace_memory"; "fleet_messages" ]
    (section_names delivery.unchanged_sections);
  let notice = Host.held_rows_notice delivery.partly_held_sections |> Result.get_ok in
  check bool "the prompt carries the line naming the section sent in part" true
    (contains delivery.prompt notice);
  let same = resume ~held:delivery.held_context second in
  check string "a session holding the head and every row is sent the goal alone" "GOAL"
    same.prompt;
  (* Turn 5 ran outside this session, so the session lacks two rows. *)
  let later = resume ~held:delivery.held_context (world_state_turn (world_state_with_actions [ 4; 5; 6 ])) in
  check bool "every row the session lacks is sent" true (sends later 5 && sends later 6);
  check bool "the row the session holds is not sent" false (sends later 4);
  check int "the session names only the rows of the current window" 3 (held_row_count later)
;;

(* A head that changed while the rows did not -- a new rejected-call digest --
   goes out alone with its tail. *)
let test_a_changed_head_goes_out_without_the_rows_the_session_holds () =
  use_markdown_prompts ();
  let first = world_state_turn (world_state_with_actions [ 1; 2 ]) in
  let noted = world_state_turn (world_state_with_actions ~head_note:"REJECTED-DIGEST\n" [ 1; 2 ]) in
  let delivery = resume ~held:(start_holding first) noted in
  check bool "the changed head is sent" true (contains delivery.prompt "REJECTED-DIGEST");
  check bool "no held row is sent" false (sends delivery 1 || sends delivery 2);
  check (list string) "recent actions is named as sent in part" [ "own_recent_actions" ]
    (section_names delivery.partly_held_sections)
;;

(* A session that holds none of the rows -- a new session, a compaction, or a
   copy held as one text before rows were named -- gets the section whole. *)
let test_recent_actions_go_out_whole_when_the_session_holds_no_row () =
  use_markdown_prompts ();
  let turn = world_state_with_actions [ 1; 2; 3 ] in
  let fresh = resume ~held:[] (world_state_turn turn) in
  check bool "every row is sent to a session holding nothing" true
    (List.for_all (sends fresh) [ 1; 2; 3 ]);
  check (list string) "nothing is named as sent in part" []
    (section_names fresh.partly_held_sections);
  let as_one_text =
    [ { Keeper_official_client_session_store.context =
          Keeper_official_client_session_store.Context_section
            (Layers.Layer Layers.Own_recent_actions)
      ; sha256 = Agent_core_sha256.(digest_string (Layers.text turn) |> to_hex)
      } ]
  in
  let old_copy = resume ~held:as_one_text (world_state_turn (world_state_with_actions [ 2; 3; 4 ])) in
  check bool "a copy held as one text names no row, so every row is sent" true
    (List.for_all (sends old_copy) [ 2; 3; 4 ])
;;

(* The section sent in part is still the issuer's bytes: its head, its other
   rows and its tail. Its attribution names the rows left out by digest. *)
let test_recent_action_rows_sent_in_part_keep_their_issuer_attribution () =
  use_markdown_prompts ();
  let open Yojson.Safe.Util in
  let first = world_state_turn (world_state_with_actions [ 1; 2; 3 ]) in
  let second = world_state_turn (world_state_with_actions [ 2; 3; 4 ]) in
  let delivery = resume ~held:(start_holding first) second in
  let binding =
    Keeper_context_submission_link.binding_to_json
      ~slot:Runtime_official_client_write.Whole_write
      delivery.context_projection
      (Runtime_official_client_write.raw delivery.prompt)
  in
  check string "the carrier attributes to its issuer" "verified"
    (binding |> member "issuer_attribution" |> member "status" |> to_string);
  match binding |> member "occurrences" |> to_list with
  | [ occurrence ] ->
    check string "the rendering names both kinds of omission"
      "ordered_blocks_joined_by_two_newlines_without_held_world_state_sections_and_rows"
      (occurrence |> member "source" |> member "rendering" |> to_string);
    (match occurrence |> member "source" |> member "omitted_world_state_rows" |> to_list with
     | [ entry ] ->
       check string "the rows left out are recent actions" "own_recent_actions"
         (entry |> member "section" |> to_string);
       check (list string) "the attribution names the rows left out by digest"
         (List.map
            (fun turn -> Agent_core_sha256.(digest_string (action_row turn) |> to_hex))
            [ 2; 3 ])
         (entry |> member "row_sha256" |> to_list |> List.map to_string)
     | _ -> fail "one section was sent in part")
  | _ -> fail "the World State carrier must be one attributed occurrence"
;;

(* A session that holds only the recent-action rows and head sends every other
   section whole, so its evidence names omitted rows and no omitted section. *)
let test_a_rows_only_omission_is_named_as_rows () =
  use_markdown_prompts ();
  let open Yojson.Safe.Util in
  let first = world_state_turn (world_state_with_actions [ 1; 2; 3 ]) in
  let only_recent_actions =
    List.filter
      (fun (held : Keeper_official_client_session_store.held_context) ->
         match held.context with
         | Keeper_official_client_session_store.Context_section_row _ -> true
         | Keeper_official_client_session_store.Context_section section ->
           section = Layers.Layer Layers.Own_recent_actions
         | Keeper_official_client_session_store.(
             Context_block _ | Context_carrier | Librarian_working_state | Librarian_unread
             | Historical_task_reference | Tool_result_receipts | Codex_system_prompt) -> false)
      (start_holding first)
  in
  let delivery =
    resume ~held:only_recent_actions (world_state_turn (world_state_with_actions [ 2; 3; 4 ]))
  in
  check (list string) "no section is left out whole" [] (section_names delivery.unchanged_sections);
  let binding =
    Keeper_context_submission_link.binding_to_json
      ~slot:Runtime_official_client_write.Whole_write
      delivery.context_projection
      (Runtime_official_client_write.raw delivery.prompt)
  in
  match binding |> member "occurrences" |> to_list with
  | [ occurrence ] ->
    check string "the rendering names only left-out rows"
      "ordered_blocks_joined_by_two_newlines_without_held_world_state_rows"
      (occurrence |> member "source" |> member "rendering" |> to_string)
  | _ -> fail "the World State carrier must be one attributed occurrence"
;;

(* A turn's row is written again when the keeper selects another task: the
   row's task relation is relative to this turn's task. A session that holds
   the old version of that row must not be told its copy still holds, so the
   section goes out whole even though an unchanged row is still held. *)
let test_a_row_written_again_in_place_sends_the_section_whole () =
  use_markdown_prompts ();
  let other_task turn =
    if turn = 1 then action_row turn
    else Printf.sprintf "- [turn %d] Execute -> ok OTHER-TASK\n" turn
  in
  let first = world_state_turn (world_state_with_actions [ 1; 2; 3 ]) in
  let reselected = world_state_turn (world_state_with_actions ~row:other_task [ 1; 2; 3; 4 ]) in
  let delivery = resume ~held:(start_holding first) reselected in
  check (list string) "nothing is named as sent in part" []
    (section_names delivery.partly_held_sections);
  check bool "every row goes out, the unchanged one included" true
    (List.for_all (sends delivery) [ 1; 2; 3; 4 ]);
  check bool "the rewritten rows go out in their new form" true
    (contains delivery.prompt "[turn 2] Execute -> ok OTHER-TASK")
;;

(* Rows that repeat one text cannot be named apart, so the section is compared
   as one text and goes out whole, still attributed to its issuer. *)
let test_repeated_rows_are_compared_as_one_text () =
  use_markdown_prompts ();
  let open Yojson.Safe.Util in
  let first = world_state_turn (world_state_with_actions [ 1; 1; 2 ]) in
  let second = world_state_turn (world_state_with_actions [ 1; 1; 2; 3 ]) in
  let delivery = resume ~held:(start_holding first) second in
  check (list string) "nothing is named as sent in part" []
    (section_names delivery.partly_held_sections);
  check bool "every row goes out" true (List.for_all (sends delivery) [ 1; 2; 3 ]);
  check int "no row is held by name" 0 (held_row_count delivery);
  let binding =
    Keeper_context_submission_link.binding_to_json
      ~slot:Runtime_official_client_write.Whole_write
      delivery.context_projection
      (Runtime_official_client_write.raw delivery.prompt)
  in
  check string "the carrier attributes to its issuer" "verified"
    (binding |> member "issuer_attribution" |> member "status" |> to_string)
;;

(* The window moves one turn per resume for several resumes in a row; each
   resume sends that turn's row alone. *)
let test_partial_resumes_in_a_row_send_one_row_each () =
  use_markdown_prompts ();
  let windows = [ [ 2; 3; 4 ]; [ 3; 4; 5 ]; [ 4; 5; 6 ] ] in
  let _ =
    List.fold_left
      (fun held window ->
         let newest = List.nth window 2 in
         let delivery = resume ~held (world_state_turn (world_state_with_actions window)) in
         check bool (Printf.sprintf "row %d is sent" newest) true (sends delivery newest);
         check bool (Printf.sprintf "the rows before %d are not sent again" newest) false
           (List.exists (sends delivery) (List.filter (fun turn -> turn <> newest) window));
         check int "the session names the rows of the current window" 3
           (held_row_count delivery);
         delivery.held_context)
      (start_holding (world_state_turn (world_state_with_actions [ 1; 2; 3 ])))
      windows
  in
  ()
;;

let test_unsupported_choice_refuses_before_projection () =
  let projected = ref false in
  let hooks = {Agent_core.Hooks.empty with before_turn_params=Some (function
    | Agent_core.Hooks.BeforeTurnParams {current_params;_} ->
      Agent_core.Hooks.AdjustParams {current_params with tool_choice=Some Agent_core.Types.Any}
    | _ -> Agent_core.Hooks.Continue)} in
  let result = Host.prepare_turn ~composed_context:None ~runtime_label:"Fixture" ~keeper_name:"choice-fixture"
    ~turn_count:1 ~system_prompt:"SYS" ~tools:[] ~initial_messages:[]
    ~model_input_projection:(Some (fun ~tools:_ messages -> projected:=true;Ok messages))
    ~hooks:(Some hooks) ~configured_reasoning_effort:None in
  (match result with
   | Error (Agent_core.Error.Config (Agent_core.Error.InvalidConfig {field="tool_choice";_})) -> ()
   | Error error -> fail (Agent_core.Error.to_string error)
   | Ok _ -> fail "forced choice was admitted");
  check bool "refused tool choice cannot enter a materializing projection" false !projected
;;

let () =
  run
    "keeper official-client host"
    [ ( "prepared tool authority"
      , [test_case "unsupported choice refuses before projection" `Quick
           test_unsupported_choice_refuses_before_projection] )
    ; ( "carried context summaries"
      , [ test_case "issued prefix and held delivery" `Quick
            test_issued_prefix_delivery_preserves_held_semantics
        ; test_case "recall blocks resume by their resend classes" `Quick
            test_the_recall_blocks_resume_by_their_resend_classes
        ; test_case "a status-only turn between two identical selections keeps the held body" `Quick
            test_a_status_only_turn_between_two_identical_selections_keeps_the_held_body
        ; test_case
            "names blocks and digests"
            `Quick
            test_carried_summaries_name_blocks_and_digests
        ; test_case
            "an unwitnessed carrier is one entry"
            `Quick
            test_carried_summaries_without_a_witness_name_one_carrier
        ] )
    ; ( "World State sections on resume"
      , [ test_case "changed System Goal reaches a held session" `Quick
            test_a_changed_system_goal_reaches_a_held_official_session
        ; test_case "direct operation source reaches official Start and Resume" `Quick
            test_direct_operation_source_reaches_official_start_and_resume
        ; test_case "carrier authority is current-turn input on official Start and Resume" `Quick
            test_carrier_authority_is_current_turn_input_on_official_start_and_resume
        ; test_case "the carrier authority block is valid UTF-8" `Quick
            test_carrier_authority_block_is_valid_utf8
        ; test_case "authority leaves the carrier when the sent System is not the issued one" `Quick
            test_authority_leaves_the_carrier_when_the_sent_system_is_not_the_issued_one
        ; test_case "(f) the constitution amendments ride every round of the turn" `Quick
            test_the_amendments_ride_every_round_of_the_turn
        ; test_case "a System without amendments carries no block" `Quick
            test_a_system_without_amendments_carries_no_block
        ; test_case "an authority-only carrier is not expected among the messages" `Quick
            test_an_authority_only_carrier_is_not_expected_among_the_messages
        ; test_case "Goals awaiting proof are current-turn input on official Start and Resume" `Quick
            test_goals_awaiting_proof_are_current_turn_input_on_official_start_and_resume
        ; test_case
            "a resume sends only the changed sections"
            `Quick
            test_a_resume_sends_only_the_changed_world_state_sections
        ; test_case
            "a partial World State keeps its issuer attribution"
            `Quick
            test_a_partial_world_state_keeps_its_issuer_attribution
        ; test_case
            "an inbox section is sent on every resume"
            `Quick
            test_an_inbox_section_is_sent_on_every_resume
        ; test_case
            "every section goes out when the session may not hold it"
            `Quick
            test_every_world_state_section_goes_out_when_the_session_may_not_hold_it
        ; test_case
            "a resume sends only the recent action rows the session lacks"
            `Quick
            test_a_resume_sends_only_the_recent_action_rows_the_session_lacks
        ; test_case
            "a changed head goes out without the rows the session holds"
            `Quick
            test_a_changed_head_goes_out_without_the_rows_the_session_holds
        ; test_case
            "recent actions go out whole when the session holds no row"
            `Quick
            test_recent_actions_go_out_whole_when_the_session_holds_no_row
        ; test_case
            "recent action rows sent in part keep their issuer attribution"
            `Quick
            test_recent_action_rows_sent_in_part_keep_their_issuer_attribution
        ; test_case
            "a rows-only omission is named as rows"
            `Quick
            test_a_rows_only_omission_is_named_as_rows
        ; test_case
            "a row written again in place sends the section whole"
            `Quick
            test_a_row_written_again_in_place_sends_the_section_whole
        ; test_case
            "repeated rows are compared as one text"
            `Quick
            test_repeated_rows_are_compared_as_one_text
        ; test_case
            "partial resumes in a row send one row each"
            `Quick
            test_partial_resumes_in_a_row_send_one_row_each
        ] )
    ; ( "native posture admission (RFC-0390)"
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
            "required none never degrades"
            `Quick
            test_required_native_none_never_degrades
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



        ; test_case "scope observations survive a shared-host attempt replacement" `Quick
            test_scoped_boundary_spans_official_attempts


        ; test_case "scope observation failure stops official tool call" `Quick
            test_scoped_boundary_error_stops_immediately
        ; test_case "a carried MASC boundary error keeps no JSON in its message"
            `Quick test_a_carried_masc_boundary_error_keeps_no_json
        ; test_case "scope stop preserves exact terminal priority" `Quick
            test_scoped_boundary_preserves_terminal_priority
        ; test_case "explicit boundary observes every settled call" `Quick
            test_explicit_boundary_observes_each_settled_call
        ; test_case
            "dynamic tool failures do not invent a host stop"
            `Quick
            test_dynamic_tool_failures_do_not_invent_a_host_stop
        ; test_case "the boundary preserves explicit terminal outcomes" `Quick
            test_boundary_preserves_explicit_terminal_outcomes
        ; test_case
            "settled official tool keeps turn running"
            `Quick
            test_settled_official_tool_keeps_turn_running
        ; test_case
            "host stop carries request context, not spend"
            `Quick
            test_host_stop_carries_request_context_not_spend
        ; test_case
            "terminal post-effect failure aborts official-client turn"
            `Quick
            test_terminal_post_effect_failure_aborts_the_official_client_turn
        ; test_case "terminal media delivery failure retains applied effect" `Quick
            test_terminal_media_delivery_failure_keeps_applied_effect
        ; test_case "image result refused when the model takes no image" `Quick
            test_image_result_is_refused_when_the_model_takes_no_image
        ; test_case "image result reaches a model that accepts images" `Quick
            test_image_result_reaches_a_model_that_accepts_images
        ; test_case "dispatched image capability survives same-ID runtime replacement" `Quick
            test_dispatched_image_capability_survives_runtime_replacement
        ; test_case "codex tool-result image media type checked before settling" `Quick
            test_codex_tool_result_image_media_type_is_checked_before_settling
        ; test_case "codex tool-result image data checked before settling" `Quick
            test_codex_tool_result_image_data_is_checked_before_settling
        ; test_case "identical structured results remain deliverable" `Quick
            test_identical_structured_results_remain_deliverable
        ; test_case "text-only results remain deliverable" `Quick
            test_text_only_results_remain_deliverable
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
            "input speaker stays out of the envelope"
            `Quick
            test_input_speaker_stays_out_of_the_envelope
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
    ; ( "goal projection"
      , [ test_case
            "stored goal images come back as the runtimes' image input"
            `Quick
            test_goal_images_are_read_back_as_the_runtimes_image_input
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
    ; ( "system prompt refusal (masc#33165)"
      , [ test_case "a blank prompt is refused" `Quick test_blank_system_prompt_is_refused
        ; test_case "Goal observations cannot mask blank Keeper instructions" `Quick
            test_goal_observation_cannot_mask_blank_keeper_instructions
        ; test_case
            "a hook override to blank is refused"
            `Quick
            test_hook_override_to_blank_system_prompt_is_refused
        ; test_case
            "a non-blank prompt reaches the lane unchanged"
            `Quick
            test_non_blank_system_prompt_reaches_the_lane_unchanged
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
    ; ( "where a start seed begins"
      , [ test_case
            "it begins at the Librarian position"
            `Quick
            test_a_start_seed_begins_at_the_librarian_position
        ; test_case
            "without one the lane's own front stands"
            `Quick
            test_a_seed_without_a_librarian_position_is_unchanged
        ; test_case
            "a refused seed reopens at the turn boundary"
            `Quick
            test_a_refused_seed_reopens_at_the_turn_boundary
        ; test_case
            "a refused seed without a later boundary keeps the newest atom"
            `Quick
            test_a_refused_seed_without_a_later_boundary_keeps_the_newest_atom
        ; test_case
            "a refusal speaks only for its runtime and history"
            `Quick
            test_a_refusal_speaks_only_for_its_runtime_and_history
        ; test_case
            "an unknown turn start is reported by the range sent"
            `Quick
            test_an_unknown_turn_start_is_reported_by_the_range_sent
        ; test_case
            "a later lane cut wins"
            `Quick
            test_a_later_lane_cut_wins
        ; test_case
            "a Librarian position behind the turn start still wins"
            `Quick
            test_a_librarian_position_behind_the_turn_start_still_wins
        ; test_case
            "a read position alone starts the range without a working state"
            `Quick
            test_a_read_position_alone_starts_the_range_without_a_working_state
        ; test_case
            "a read position behind the lane cut loses"
            `Quick
            test_a_read_position_behind_the_lane_cut_loses
        ; test_case
            "a fully absorbed history still carries its newest atom"
            `Quick
            test_a_fully_absorbed_history_still_carries_its_newest_atom
        ; test_case
            "the observation records the front or why the choice was not applied"
            `Quick
            test_the_observation_records_the_front_or_why_the_choice_was_not_applied
        ; test_case
            "the loading plan names the on-demand tools"
            `Quick
            test_loading_plan_names_the_on_demand_tools
        ; test_case "repeated editor input settles through the shared host" `Quick
            test_repeated_browser_input_remains_deliverable
        ; test_case
            "the result bound follows the bundle bounds"
            `Quick
            test_result_bound_follows_the_bundle_bounds
        ] )
    ]
;;
