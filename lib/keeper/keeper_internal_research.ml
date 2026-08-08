type owner =
  | Librarian
  | Hitl_auto_judge
  | Board_attention
  | Compaction
  | Completion_authority

module Execution_id = struct
  type t = string

  let generate () = Random_id.prefixed ~prefix:"internal-research-" ~bytes:16

  let to_string value = value
end

type raw_trace_sink_outcome =
  | Raw_trace_ready of Agent_sdk.Raw_trace.t
  | Raw_trace_degraded of Agent_sdk.Error.sdk_error

let create_raw_trace_sink
      ~before_create
      ~(config : Workspace.config)
      ~(meta : Keeper_meta_contract.keeper_meta)
      ~execution_id
  =
  let path_result =
    try Ok (Keeper_types_support.keeper_raw_trace_turn_path config meta.name) with
    | Eio.Cancel.Cancelled _ as exn -> raise exn
    | exn -> Error (Agent_sdk.Error.Internal (Printexc.to_string exn))
  in
  match path_result with
  | Error error -> Raw_trace_degraded error
  | Ok path ->
    before_create path;
    (match
       Agent_sdk.Raw_trace.create
         ~session_id:(Execution_id.to_string execution_id)
         ~path
         ()
     with
     | Ok sink -> Raw_trace_ready sink
     | Error error -> Raw_trace_degraded error)
;;

type request =
  { owner : owner
  ; execution_id : Execution_id.t
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
  | Research_failed of Agent_sdk.Error.sdk_error

type cleanup_outcome =
  | Cleanup_succeeded
  | Cleanup_failed of string

type receipt =
  { owner : owner
  ; execution_id : Execution_id.t
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

let owner_label = function
  | Librarian -> "librarian"
  | Hitl_auto_judge -> "hitl_auto_judge"
  | Board_attention -> "board_attention"
  | Compaction -> "compaction"
  | Completion_authority -> "completion_authority"
;;

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

let tool_call_result_to_yojson = function
  | Executed (Ok { content; _meta }) ->
    `Assoc
      [ "kind", `String "executed"
      ; "outcome", `String "succeeded"
      ; "content", `String content
      ; "metadata", Option.value ~default:`Null _meta
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
      [ "kind", `String "rejected_before_execution"
      ; "detail", `String detail
      ]
;;

let tool_call_to_yojson call =
  `Assoc
    [ "invocation", invocation_to_yojson call.invocation
    ; "tool_name", `String call.tool_name
    ; "input", call.input
    ; "started_at", `Float call.started_at
    ; "finished_at", `Float call.finished_at
    ; "duration_ms", `Float call.duration_ms
    ; "result", tool_call_result_to_yojson call.result
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
  | Research_failed error ->
    `Assoc
      [ "kind", `String "failed"
      ; "category", `String (Agent_sdk.Error.category_label (Agent_sdk.Error.category error))
      ; "detail", `String (Agent_sdk.Error.to_string error)
      ; "retryable", `Bool (Agent_sdk.Error.is_retryable error)
      ]
;;

let trace_ref_to_yojson = function
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

let receipt_to_yojson receipt =
  `Assoc
    [ "owner", `String (owner_label receipt.owner)
    ; "execution_id", `String (Execution_id.to_string receipt.execution_id)
    ; "runtime_id", `String receipt.runtime_id
    ; "frozen_system_prompt", `String receipt.frozen_system_prompt
    ; "frozen_prompt", `String receipt.frozen_prompt
    ; "frozen_input", receipt.frozen_input
    ; "started_at", `Float receipt.started_at
    ; "finished_at", `Float receipt.finished_at
    ; "duration_ms", `Float receipt.duration_ms
    ; "tool_names", Json_util.json_string_list receipt.tool_names
    ; "tool_calls", `List (List.map tool_call_to_yojson receipt.tool_calls)
    ; "terminal_effect", terminal_effect_to_yojson receipt.terminal_effect
    ; "cleanup", cleanup_to_yojson receipt.cleanup
    ; "outcome", execution_outcome_to_yojson receipt.outcome
    ; "trace_ref", trace_ref_to_yojson receipt.trace_ref
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
    | Research_failed error -> execution_outcome_to_yojson (Research_failed error)
  in
  `Assoc
    [ "owner", `String (owner_label receipt.owner)
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
  ; by_tool_use_id : (string, observed_call) Hashtbl.t
  }

let create_recorder () =
  { mutex = Eio.Mutex.create ()
  ; next_ordinal = 0
  ; calls = []
  ; by_tool_use_id = Hashtbl.create 16
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
    Hashtbl.replace
      recorder.by_tool_use_id
      (Agent_sdk.Tool_contract.Invocation.tool_use_id invocation)
      call)
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
    let tool_use_id = Agent_sdk.Tool_contract.Invocation.tool_use_id invocation in
    let call =
      match Hashtbl.find_opt recorder.by_tool_use_id tool_use_id with
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
        Hashtbl.replace recorder.by_tool_use_id tool_use_id call;
        call
    in
    match call.terminal with
    | Some _ -> ()
    | None -> call.terminal <- Some (now, duration_ms, result))
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
    | Agent_sdk.Hooks.PostToolUseFailure { invocation; tool_name; input; error } ->
      observe_terminal
        recorder
        ~now:(Time_compat.now ())
        ~invocation
        ~tool_name
        ~input
        ~duration_ms:0.0
        ~result:(Rejected_before_execution error);
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
        ; result = Rejected_before_execution "tool invocation did not reach a terminal hook"
        }))
;;

let make_bundle (request : request) =
  let gate_context =
    Keeper_gate_causal_context.create
      ~turn_id:None
      ~initial:
        (`Assoc
           [ "internal_research_execution_id"
           , `String (Execution_id.to_string request.execution_id)
           ; "owner", `String (owner_label request.owner)
           ; "frozen_input", request.frozen_input
           ])
  in
  Keeper_tools_oas_bundle.make_tool_bundle
    ~config:request.config
    ~meta:request.meta
    ~publication_recovery:request.publication_recovery
    ~ctx_snapshot:request.ctx_snapshot
    ~clock:request.clock
    ?continuation_channel:request.continuation_channel
    ~gate_context
    ()
;;

let protect_with_cleanup ~cleanup ~on_cleanup body =
  Eio_guard.protect
    ~finally:(fun () ->
      let outcome =
        try
          cleanup ();
          Cleanup_succeeded
        with
        | Eio.Cancel.Cancelled _ as exn -> raise exn
        | exn -> Cleanup_failed (Printexc.to_string exn)
      in
      on_cleanup outcome)
    body
;;

let bounded_evidence ~max_bytes text =
  if max_bytes < 0
  then invalid_arg "internal research evidence budget must be non-negative";
  let original_bytes = String.length text in
  let text, truncated = Keeper_text_processing.truncate_utf8_prefix ~max_bytes text in
  { text
  ; original_bytes
  ; retained_bytes = String.length text
  ; truncated
  }
;;

let run (request : request) =
  let started_at = Time_compat.now () in
  let bundle = make_bundle request in
  let recorder = create_recorder () in
  let hooks = recorder_hooks recorder in
  let tool_names =
    List.map (fun (tool : Agent_sdk.Tool.t) -> tool.schema.name) bundle.tools
  in
  let cleanup_outcome = ref None in
  let run_result =
    protect_with_cleanup
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
         | Eio.Cancel.Cancelled _ as exn -> raise exn
         | exn -> Error (Agent_sdk.Error.Internal (Printexc.to_string exn)))
  in
  let cleanup =
    match !cleanup_outcome with
    | Some outcome -> outcome
    | None -> failwith "internal research cleanup invariant violated"
  in
  let outcome, trace_ref =
    match run_result with
    | Ok result ->
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
    | Error error -> Research_failed error, None
  in
  let finished_at = Time_compat.now () in
  { owner = request.owner
  ; execution_id = request.execution_id
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
    | None -> failwith "internal research cleanup invariant violated"
  ;;
end
