module Execution_id = struct
  type t = string

  let generate () = Random_id.prefixed ~prefix:"librarian-research-" ~bytes:16

  let to_string value = value
end

type raw_trace_sink_outcome =
  | Raw_trace_ready of Agent_sdk.Raw_trace.t
  | Raw_trace_degraded of Agent_sdk.Error.sdk_error

let internal_error_of_exception exn =
  Llm_provider.Reserved_exn.reraise_if_reserved exn;
  Agent_sdk.Error.Internal (Printexc.to_string exn)
;;

let research_descriptors = Keeper_tool_descriptor.model_visible_descriptors

let create_raw_trace_sink
      ~before_create
      ~(config : Workspace.config)
      ~(meta : Keeper_meta_contract.keeper_meta)
      ~execution_id
  =
  let path_result =
    try Ok (Keeper_types_support.keeper_raw_trace_turn_path config meta.name) with
    | exn -> Error (internal_error_of_exception exn)
  in
  match path_result with
  | Error error -> Raw_trace_degraded error
  | Ok path ->
    (try
       before_create path;
       match
         Agent_sdk.Raw_trace.create
           ~session_id:(Execution_id.to_string execution_id)
           ~path
           ()
       with
       | Ok sink -> Raw_trace_ready sink
       | Error error -> Raw_trace_degraded error
     with
     | exn -> Raw_trace_degraded (internal_error_of_exception exn))
;;

type request =
  { execution_id : Execution_id.t
  ; runtime_id : string
  ; frozen_system_prompt : string
  ; frozen_prompt : string
  ; frozen_input : Yojson.Safe.t
  ; evidence_budget_bytes : int
  ; config : Workspace.config
  ; meta : Keeper_meta_contract.keeper_meta
  ; publication_recovery :
      Keeper_publication_recovery_availability.turn_context
  ; ctx_snapshot : Keeper_types.working_context
  ; clock : float Eio.Time.clock_ty Eio.Resource.t
  ; net : Eio_context.eio_net
  ; continuation_channel : Keeper_continuation_channel.t option
  ; raw_trace : Agent_sdk.Raw_trace.t option
  }

type tool_call_result =
  | Executed of Agent_sdk.Types.tool_result
  | Rejected_before_execution of string
  | Execution_failure_observed of string
  | Terminal_observation_missing

type tool_call =
  { invocation : Agent_sdk.Tool_contract.Invocation.t
  ; tool_name : string
  ; input : Yojson.Safe.t
  ; started_at : float
  ; finished_at : float
  ; duration_ms : float
  ; result : tool_call_result
  }

type bounded_evidence =
  { text : string
  ; original_bytes : int
  ; retained_bytes : int
  ; truncated : bool
  }

type execution_outcome =
  | Research_completed of
      { evidence : bounded_evidence
      ; session_id : string
      ; turns : int
      ; stop_reason : Runtime_agent.stop_reason
      }
  | Research_deferred of
      { session_id : string
      ; turns : int
      }
  | Research_failed of Agent_sdk.Error.sdk_error
  | Research_cancelled

let finalizer_may_run = function
  | Research_deferred _ -> false
  | Research_completed _ | Research_failed _ | Research_cancelled -> true
;;

type cleanup_outcome =
  | Cleanup_succeeded
  | Cleanup_failed of string
  | Cleanup_cancelled

type receipt =
  { execution_id : Execution_id.t
  ; runtime_id : string
  ; frozen_system_prompt : string
  ; frozen_prompt : string
  ; frozen_input : Yojson.Safe.t
  ; started_at : float
  ; finished_at : float
  ; duration_ms : float
  ; tool_names : string list
  ; tool_calls : tool_call list
  ; terminal_effect : Keeper_tools_oas.terminal_effect_state
  ; cleanup : cleanup_outcome
  ; outcome : execution_outcome
  ; trace_ref : Agent_sdk.Raw_trace.run_ref option
  }

let execution_mode_label = function
  | Agent_sdk.Tool_contract.Concurrent -> "concurrent"
  | Agent_sdk.Tool_contract.Serial -> "serial"
;;

let completion_to_yojson = function
  | Agent_sdk.Tool_contract.Continue_after_success ->
    `Assoc [ "kind", `String "continue_after_success" ]
  | Agent_sdk.Tool_contract.Terminal_after_success disposition ->
    `Assoc
      [ "kind", `String "terminal_after_success"
      ; ( "failure_effect_disposition"
        , `String
            (Agent_sdk.Tool_contract.show_failure_effect_disposition disposition) )
      ]
;;

let invocation_to_yojson invocation =
  let schedule = Agent_sdk.Tool_contract.Invocation.schedule invocation in
  `Assoc
    [ "tool_use_id"
    , `String (Agent_sdk.Tool_contract.Invocation.tool_use_id invocation)
    ; "turn", `Int (Agent_sdk.Tool_contract.Invocation.turn invocation)
    ; "planned_index", `Int schedule.planned_index
    ; "batch_index", `Int schedule.batch_index
    ; "batch_size", `Int schedule.batch_size
    ; "execution_mode", `String (execution_mode_label schedule.execution_mode)
    ; ( "completion"
      , completion_to_yojson
          (Agent_sdk.Tool_contract.Invocation.completion invocation) )
    ]
;;

let tool_error_class_to_yojson = function
  | None -> `Null
  | Some value -> `String (Agent_sdk.Types.show_tool_error_class value)
;;

let registry_tool_call_result_to_yojson = function
  | Executed (Ok { content; _meta }) ->
    `Assoc
      [ "kind", `String "executed"
      ; "outcome", `String "succeeded"
      ; "content", `String content
      ; ( "meta"
        , match _meta with
          | Some meta -> meta
          | None -> `Null )
      ]
  | Executed (Error { message; recoverable; error_class }) ->
    `Assoc
      [ "kind", `String "executed"
      ; "outcome", `String "failed"
      ; "message", `String message
      ; "recoverable", `Bool recoverable
      ; "error_class", tool_error_class_to_yojson error_class
      ]
  | Rejected_before_execution detail ->
    `Assoc
      [ "kind", `String "rejected_before_execution"; "detail", `String detail ]
  | Execution_failure_observed detail ->
    `Assoc
      [ "kind", `String "execution_failure_observed"; "detail", `String detail ]
  | Terminal_observation_missing ->
    `Assoc [ "kind", `String "terminal_observation_missing" ]
;;

let registry_tool_call_to_yojson call =
  `Assoc
    [ "invocation", invocation_to_yojson call.invocation
    ; "tool_name", `String call.tool_name
    ; "input", call.input
    ; "started_at", `Float call.started_at
    ; "finished_at", `Float call.finished_at
    ; "duration_ms", `Float call.duration_ms
    ; "result", registry_tool_call_result_to_yojson call.result
    ]
;;

let runtime_stop_reason_to_yojson = function
  | Runtime_agent.Completed -> `Assoc [ "kind", `String "completed" ]
  | Runtime_agent.Yielded_to_chat_waiting { turns_used } ->
    `Assoc
      [ "kind", `String "yielded_to_chat_waiting"
      ; "turns_used", `Int turns_used
      ]
  | Runtime_agent.Yielded_to_durable_stimulus { turns_used } ->
    `Assoc
      [ "kind", `String "yielded_to_durable_stimulus"
      ; "turns_used", `Int turns_used
      ]
  | Runtime_agent.Awaiting_external_effect { turns_used } ->
    `Assoc
      [ "kind", `String "awaiting_external_effect"
      ; "turns_used", `Int turns_used
      ]
  | Runtime_agent.Yielded_after_repeated_tool_call
      { turns_used; tool_name; repeated_count } ->
    `Assoc
      [ "kind", `String "yielded_after_repeated_tool_call"
      ; "turns_used", `Int turns_used
      ; "tool_name", `String tool_name
      ; "repeated_count", `Int repeated_count
      ]
  | Runtime_agent.InputRequired { turns_used; request } ->
    `Assoc
      [ "kind", `String "input_required"
      ; "turns_used", `Int turns_used
      ; "request_id", `String request.request_id
      ]
;;

let terminal_effect_to_yojson = function
  | Keeper_tools_oas.Terminal_effect_open ->
    `Assoc [ "kind", `String "open" ]
  | Keeper_tools_oas.Deferred_tool_result ->
    `Assoc [ "kind", `String "deferred_tool_result" ]
  | Keeper_tools_oas.External_effect_deferred ->
    `Assoc [ "kind", `String "external_effect_deferred" ]
  | Keeper_tools_oas.Terminal_effect_completed ->
    `Assoc [ "kind", `String "completed" ]
  | Keeper_tools_oas.Terminal_effect_failed
      { failure_class; effect_disposition; diagnostic } ->
    `Assoc
      [ "kind", `String "failed"
      ; "failure_class", Tool_result.tool_failure_class_to_yojson failure_class
      ; ( "effect_disposition"
        , `String
            (Tool_result.failure_effect_disposition_to_string effect_disposition) )
      ; "diagnostic", `String diagnostic
      ]
;;

let cleanup_to_yojson = function
  | Cleanup_succeeded -> `Assoc [ "kind", `String "succeeded" ]
  | Cleanup_failed detail ->
    `Assoc [ "kind", `String "failed"; "detail", `String detail ]
  | Cleanup_cancelled -> `Assoc [ "kind", `String "cancelled" ]
;;

let bounded_evidence_to_yojson evidence =
  `Assoc
    [ "text", `String evidence.text
    ; "original_bytes", `Int evidence.original_bytes
    ; "retained_bytes", `Int evidence.retained_bytes
    ; "truncated", `Bool evidence.truncated
    ]
;;

let execution_outcome_to_yojson = function
  | Research_completed { evidence; session_id; turns; stop_reason } ->
    `Assoc
      [ "kind", `String "completed"
      ; "evidence", bounded_evidence_to_yojson evidence
      ; "session_id", `String session_id
      ; "turns", `Int turns
      ; "stop_reason", runtime_stop_reason_to_yojson stop_reason
      ]
  | Research_deferred { session_id; turns } ->
    `Assoc
      [ "kind", `String "deferred"
      ; "session_id", `String session_id
      ; "turns", `Int turns
      ; "stop_reason"
      , runtime_stop_reason_to_yojson
          (Runtime_agent.Awaiting_external_effect { turns_used = turns })
      ]
  | Research_failed error ->
    `Assoc
      [ "kind", `String "failed"
      ; "category", `String (Agent_sdk.Error.category_label (Agent_sdk.Error.category error))
      ; "detail", `String (Agent_sdk.Error.to_string error)
      ; "retryable", `Bool (Agent_sdk.Error.is_retryable error)
      ]
  | Research_cancelled -> `Assoc [ "kind", `String "cancelled" ]
;;

let registry_trace_ref_to_yojson = function
  | None -> `Null
  | Some (trace : Agent_sdk.Raw_trace.run_ref) ->
    `Assoc
      [ "worker_run_id", `String trace.worker_run_id
      ; "path", `String trace.path
      ; "start_seq", `Int trace.start_seq
      ; "end_seq", `Int trace.end_seq
      ; "agent_name", `String trace.agent_name
      ; ( "session_id"
        , Option.fold ~none:`Null ~some:(fun value -> `String value) trace.session_id )
      ]
;;

let registry_receipt_to_yojson receipt =
  `Assoc
    [ "owner", `String "librarian"
    ; "execution_id", `String (Execution_id.to_string receipt.execution_id)
    ; "runtime_id", `String receipt.runtime_id
    ; "frozen_system_prompt", `String receipt.frozen_system_prompt
    ; "frozen_prompt", `String receipt.frozen_prompt
    ; "frozen_input", receipt.frozen_input
    ; "started_at", `Float receipt.started_at
    ; "finished_at", `Float receipt.finished_at
    ; "duration_ms", `Float receipt.duration_ms
    ; "tool_names", Json_util.json_string_list receipt.tool_names
    ; "tool_calls"
    , `List (List.map registry_tool_call_to_yojson receipt.tool_calls)
    ; "terminal_effect", terminal_effect_to_yojson receipt.terminal_effect
    ; "cleanup", cleanup_to_yojson receipt.cleanup
    ; "outcome", execution_outcome_to_yojson receipt.outcome
    ; "trace_ref", registry_trace_ref_to_yojson receipt.trace_ref
    ]
;;

let finalizer_evidence_to_yojson receipt =
  let outcome =
    match receipt.outcome with
    | Research_completed { evidence; session_id = _; turns; stop_reason } ->
      `Assoc
        [ "kind", `String "completed"
        ; "evidence", bounded_evidence_to_yojson evidence
        ; "turns", `Int turns
        ; "stop_reason", runtime_stop_reason_to_yojson stop_reason
        ]
    | Research_deferred _ as deferred -> execution_outcome_to_yojson deferred
    | Research_failed error -> execution_outcome_to_yojson (Research_failed error)
    | Research_cancelled -> execution_outcome_to_yojson Research_cancelled
  in
  `Assoc
    [ "owner", `String "librarian"
    ; "execution_id", `String (Execution_id.to_string receipt.execution_id)
    ; "runtime_id", `String receipt.runtime_id
    ; "started_at", `Float receipt.started_at
    ; "finished_at", `Float receipt.finished_at
    ; "duration_ms", `Float receipt.duration_ms
    ; "tool_calls"
    , `List
        (List.map
           (fun call ->
              `Assoc
                [ "invocation", invocation_to_yojson call.invocation
                ; "tool_name", `String call.tool_name
                ; "started_at", `Float call.started_at
                ; "finished_at", `Float call.finished_at
                ])
           receipt.tool_calls)
    ; "terminal_effect", terminal_effect_to_yojson receipt.terminal_effect
    ; "cleanup", cleanup_to_yojson receipt.cleanup
    ; "outcome", outcome
    ]
;;

type observed_call =
  { ordinal : int
  ; invocation : Agent_sdk.Tool_contract.Invocation.t
  ; tool_name : string
  ; input : Yojson.Safe.t
  ; started_at : float
  ; mutable terminal : (float * float * tool_call_result) option
  }

type recorder =
  { mutex : Eio.Mutex.t
  ; mutable next_ordinal : int
  ; mutable calls : observed_call list
  ; by_invocation : (Agent_sdk.Tool_contract.Invocation.t, observed_call) Hashtbl.t
  }

let create_recorder () =
  { mutex = Eio.Mutex.create ()
  ; next_ordinal = 0
  ; calls = []
  ; by_invocation = Hashtbl.create 16
  }
;;

let with_recorder recorder f = Eio_guard.with_mutex recorder.mutex f

let observe_started recorder ~now ~invocation ~tool_name ~input =
  with_recorder recorder (fun () ->
    let ordinal = recorder.next_ordinal in
    recorder.next_ordinal <- ordinal + 1;
    let call =
      { ordinal; invocation; tool_name; input; started_at = now; terminal = None }
    in
    recorder.calls <- call :: recorder.calls;
    Hashtbl.replace recorder.by_invocation invocation call)
;;

let observe_terminal
      recorder
      ~now
      ~invocation
      ~tool_name
      ~input
      ~duration_ms
      ~result
  =
  with_recorder recorder (fun () ->
    let call =
      match Hashtbl.find_opt recorder.by_invocation invocation with
      | Some call -> call
      | None ->
        let ordinal = recorder.next_ordinal in
        recorder.next_ordinal <- ordinal + 1;
        let call =
          { ordinal
          ; invocation
          ; tool_name
          ; input
          ; started_at = now -. (duration_ms /. 1000.0)
          ; terminal = None
          }
        in
        recorder.calls <- call :: recorder.calls;
        Hashtbl.replace recorder.by_invocation invocation call;
        call
    in
    match call.terminal, result with
    | None, _ -> call.terminal <- Some (now, duration_ms, result)
    | Some (_, _, Execution_failure_observed _), Executed _ ->
      (* [PostToolUse] is the authoritative handler result. The execution
         failure hook is a compact secondary observation and may be delivered
         first by a custom observer scheduler. *)
      call.terminal <- Some (now, duration_ms, result)
    | Some _, _ -> ())
;;

let recorder_hooks recorder =
  let pre_tool_use = function
    | Agent_sdk.Hooks.PreToolUse { invocation; tool_name; input; _ } ->
      observe_started recorder ~now:(Time_compat.now ()) ~invocation ~tool_name ~input;
      Agent_sdk.Hooks.Continue
    | _ -> Agent_sdk.Hooks.Continue
  in
  let post_tool_use = function
    | Agent_sdk.Hooks.PostToolUse
        { invocation; tool_name; input; output; duration_ms; _ } ->
      observe_terminal
        recorder
        ~now:(Time_compat.now ())
        ~invocation
        ~tool_name
        ~input
        ~duration_ms
        ~result:(Executed output);
      Agent_sdk.Hooks.Continue
    | _ -> Agent_sdk.Hooks.Continue
  in
  let post_tool_use_failure = function
    | Agent_sdk.Hooks.PostToolUseFailure
        { invocation; tool_name; input; stage; duration_ms; error } ->
      let result =
        match stage with
        | Agent_sdk.Hooks.Validation_before_execution ->
          Rejected_before_execution error
        | Agent_sdk.Hooks.Execution -> Execution_failure_observed error
      in
      observe_terminal
        recorder
        ~now:(Time_compat.now ())
        ~invocation
        ~tool_name
        ~input
        ~duration_ms
        ~result;
      Agent_sdk.Hooks.Continue
    | _ -> Agent_sdk.Hooks.Continue
  in
  { Agent_sdk.Hooks.empty with
    pre_tool_use = Some pre_tool_use
  ; post_tool_use = Some post_tool_use
  ; post_tool_use_failure = Some post_tool_use_failure
  }
;;

let freeze_calls recorder =
  with_recorder recorder (fun () ->
    recorder.calls
    |> List.sort (fun left right -> Int.compare left.ordinal right.ordinal)
    |> List.map (fun call ->
      match call.terminal with
      | Some (finished_at, duration_ms, result) ->
        { invocation = call.invocation
        ; tool_name = call.tool_name
        ; input = call.input
        ; started_at = call.started_at
        ; finished_at
        ; duration_ms
        ; result
        }
      | None ->
        let finished_at = Time_compat.now () in
        { invocation = call.invocation
        ; tool_name = call.tool_name
        ; input = call.input
        ; started_at = call.started_at
        ; finished_at
        ; duration_ms = (finished_at -. call.started_at) *. 1000.0
        ; result = Terminal_observation_missing
        }))
;;

let make_bundle_with_gate_context (request : request) =
  let gate_context =
    Keeper_gate_causal_context.create
      ~turn_id:None
      ~initial:
        (`Assoc
           [ "librarian_research_execution_id"
           , `String (Execution_id.to_string request.execution_id)
           ; "owner", `String "librarian"
           ])
  in
  ( Keeper_tools_oas_bundle.make_tool_bundle_for_descriptors
      ~config:request.config
      ~meta:request.meta
      ~publication_recovery:request.publication_recovery
      ~ctx_snapshot:request.ctx_snapshot
      ~clock:request.clock
      ?continuation_channel:request.continuation_channel
      ~gate_context
      ~descriptors:(research_descriptors ())
      ()
  , gate_context )
;;

let make_bundle request = make_bundle_with_gate_context request |> fst
;;

let protect_with_cleanup ~cleanup ~on_cleanup body =
  let body_outcome = ref None in
  let cleanup_reserved = ref None in
  Eio_guard.protect
    ~finally:(fun () ->
      match cleanup () with
      | () -> on_cleanup Cleanup_succeeded
      | exception (Eio.Cancel.Cancelled _ as exn) ->
        let backtrace = Printexc.get_raw_backtrace () in
        on_cleanup Cleanup_cancelled;
        cleanup_reserved := Some (exn, backtrace)
      | exception exn ->
        let backtrace = Printexc.get_raw_backtrace () in
        let reserved =
          try
            Llm_provider.Reserved_exn.reraise_if_reserved exn;
            None
          with
          | reserved -> Some reserved
        in
        (match reserved with
         | Some reserved -> cleanup_reserved := Some (reserved, backtrace)
         | None -> on_cleanup (Cleanup_failed (Printexc.to_string exn))))
    (fun () ->
      body_outcome :=
        Some
          (try Ok (body ()) with
           | exn -> Error (exn, Printexc.get_raw_backtrace ())));
  match !cleanup_reserved, !body_outcome with
  | Some (exn, backtrace), _
  | None, Some (Error (exn, backtrace)) ->
    Printexc.raise_with_backtrace exn backtrace
  | None, Some (Ok value) -> value
  | None, None -> failwith "librarian research body outcome missing"
;;

let bounded_evidence ~max_bytes text =
  if max_bytes < 0
  then invalid_arg "librarian research evidence budget must be non-negative";
  let original_bytes = String.length text in
  let text, truncated = Keeper_text_processing.truncate_utf8_prefix ~max_bytes text in
  { text
  ; original_bytes
  ; retained_bytes = String.length text
  ; truncated
  }
;;

let run ~on_receipt (request : request) =
  let started_at = Time_compat.now () in
  let bundle = make_bundle request in
  let recorder = create_recorder () in
  let hooks = recorder_hooks recorder in
  let tool_names =
    List.map (fun (tool : Agent_sdk.Tool.t) -> tool.schema.name) bundle.tools
  in
  let cleanup_outcome = ref None in
  let execution =
    try
      `Returned
        (protect_with_cleanup
           ~cleanup:bundle.cleanup
           ~on_cleanup:(fun outcome -> cleanup_outcome := Some outcome)
           (fun () ->
              try
                Keeper_turn_driver.run_named
                  ~runtime_id:request.runtime_id
                  ~keeper_name:request.meta.name
                  ~base_path:request.config.base_path
                  ~goal:request.frozen_prompt
                  ~system_prompt:request.frozen_system_prompt
                  ~tools:bundle.tools
                  ~hooks
                  ?raw_trace:request.raw_trace
                  ~cooperative_yield_probe:(fun _ ->
                    Keeper_tool_terminal_boundary.decision
                      (bundle.terminal_effect_state ()))
                  ~net:request.net
                  ()
              with
              | exn -> Error (internal_error_of_exception exn)))
    with
    | Eio.Cancel.Cancelled _ as exn ->
      `Cancelled (exn, Printexc.get_raw_backtrace ())
  in
  let cleanup =
    match !cleanup_outcome with
    | Some outcome -> outcome
    | None -> failwith "librarian research cleanup invariant violated"
  in
  let outcome, trace_ref =
    match execution with
    | `Returned (Ok ({ stop_reason = Runtime_agent.Awaiting_external_effect
                         { turns_used }; _ } as result)) ->
      Research_deferred { session_id = result.session_id; turns = turns_used }, result.trace_ref
    | `Returned (Ok result) ->
      let raw_evidence = Agent_sdk.Types.text_of_response result.response in
      let evidence =
        bounded_evidence ~max_bytes:request.evidence_budget_bytes raw_evidence
      in
      ( Research_completed
          { evidence
          ; session_id = result.session_id
          ; turns = result.turns
          ; stop_reason = result.stop_reason
          }
      , result.trace_ref )
    | `Returned (Error error) -> Research_failed error, None
    | `Cancelled _ -> Research_cancelled, None
  in
  let finished_at = Time_compat.now () in
  let receipt =
    { execution_id = request.execution_id
  ; runtime_id = request.runtime_id
  ; frozen_system_prompt = request.frozen_system_prompt
  ; frozen_prompt = request.frozen_prompt
  ; frozen_input = request.frozen_input
  ; started_at
  ; finished_at
  ; duration_ms = max 0.0 ((finished_at -. started_at) *. 1000.0)
  ; tool_names
  ; tool_calls = freeze_calls recorder
  ; terminal_effect = bundle.terminal_effect_state ()
  ; cleanup
  ; outcome
  ; trace_ref
    }
  in
  on_receipt receipt;
  match execution with
  | `Returned _ -> receipt
  | `Cancelled (exn, backtrace) -> Printexc.raise_with_backtrace exn backtrace
;;

module For_testing = struct
  let protect_with_cleanup = protect_with_cleanup

  let tool_names_for_request request =
    let bundle = make_bundle request in
    let names =
      List.map (fun (tool : Agent_sdk.Tool.t) -> tool.schema.name) bundle.tools
    in
    let cleanup = ref None in
    protect_with_cleanup
      ~cleanup:bundle.cleanup
      ~on_cleanup:(fun outcome -> cleanup := Some outcome)
      (fun () -> ());
    match !cleanup with
    | Some outcome -> names, outcome
    | None -> failwith "librarian research cleanup invariant violated"
  ;;

  let research_descriptor_contract () =
    research_descriptors ()
    |> List.map (fun (descriptor : Keeper_tool_descriptor.t) ->
      ( descriptor.public_name
      , descriptor.policy.readonly_hint
      , Keeper_tool_descriptor.runtime_handler_to_string
          descriptor.runtime_handler ))
  ;;

  let invalid_request_result_callback_count request =
    let bundle, gate_context = make_bundle_with_gate_context request in
    protect_with_cleanup
      ~cleanup:bundle.cleanup
      ~on_cleanup:(fun _ -> ())
      (fun () ->
         List.iter
           (fun (tool : Agent_sdk.Tool.t) ->
              let _result : Agent_sdk.Types.tool_result =
                Agent_sdk.Tool.execute tool `Null
              in
              ())
           bundle.tools;
         let snapshot = Keeper_gate_causal_context.snapshot gate_context in
         match snapshot.snapshot with
         | `Assoc fields ->
           (match List.assoc_opt "completed_tool_calls" fields with
            | Some (`List calls) -> List.length calls
            | Some _ | None -> failwith "missing causal result callback list")
         | _ -> failwith "invalid Librarian causal snapshot")
  ;;
  let internal_error_of_exception = internal_error_of_exception

  let freeze_completed_calls calls =
    let recorder = create_recorder () in
    List.iteri
      (fun index (invocation, tool_name, input, result) ->
         let started_at = Float.of_int index in
         observe_started recorder ~now:started_at ~invocation ~tool_name ~input;
         observe_terminal
           recorder
           ~now:(started_at +. 0.001)
           ~invocation
           ~tool_name
           ~input
           ~duration_ms:1.0
           ~result)
      calls;
    freeze_calls recorder
  ;;
end
