module A = Candle_appraisal
module Exact = Agent_core.Exact_output
module Runs = Exact_lane_run_registry
let ( let* ) = Result.bind
let lane_id = Standalone_lane.to_id Standalone_lane.Candle_appraiser
let resolve () =
  let* registry = Runtime_exact_output_registry.current ()
    |> Result.map_error Runtime_exact_output_registry.publication_error_to_string in
  Runtime_exact_output_registry.resolve_lane registry ~lane_id
  |> Result.map_error Runtime_exact_output_registry.lane_resolution_error_to_string
let available () = Result.map (fun _ -> ()) (resolve ())
let declaration_change_probe () =
  let declaration () =
    match Runtime_exact_output_registry.current () with
    | Error _ -> None
    | Ok registry -> Runtime_exact_output_registry.declared_lane registry ~lane_id in
  let previous = ref (declaration ()) in
  fun () ->
    match declaration () with
    | None -> false
    | Some current ->
      let changed = match !previous with
        | None -> false
        | Some prior -> not (Runtime_schema.equal_exact_output_lane_decl prior current) in
      previous := Some current;
      changed
let prompt_key = function
  | A.Grade _ -> Prompt_names.candle_appraiser_grade
  | A.Relation _ -> Prompt_names.candle_appraiser_relation
  | A.Weights _ -> Prompt_names.candle_appraiser_weights
let flow_failure = Exact.flow_execution_error_to_string ~callback_error_to_string:Fun.id
  ~raw_response_to_string:Keeper_exact_flow_detail.raw_response_excerpt
type observation =
  | Dispatch of string
  | Response of {slot : string; output : Yojson.Safe.t}
  | Raw_response of {slot : string; text : string}
  | Rejection of {slot : string; detail : string; output : Yojson.Safe.t}
  | Failure of {transport : string; detail : string}
  | Http_failure of {slot : string; error : Exact.execution_error}
(* [invalid_output] observes an unusable model output. A refusal that
   rejects the request itself is not an output problem -- it is observed
   through [request_refused] and reported as [A.Execution_rejected]; both
   keep the obligation off the maintenance pulse, but they answer different
   questions and no longer share one boolean. *)
let invalid_output = function
  | Exact.Incomplete_output | Exact.Missing_output | Exact.Ambiguous_output _
  | Exact.Unexpected_output_content | Exact.Invalid_json_output -> true
  | Exact.Provider_response_refused _ -> false
  | Exact.Completion_failed _ | Exact.Response_body_deadline_exceeded -> false
let observation_json = function
  | Dispatch slot -> `Assoc ["kind", `String "dispatch"; "slot", `String slot]
  | Response r -> `Assoc ["kind", `String "response"; "slot", `String r.slot; "output", r.output]
  | Raw_response r -> `Assoc ["kind", `String "response"; "slot", `String r.slot; "raw_text", `String r.text]
  | Rejection r -> `Assoc ["kind", `String "rejected"; "slot", `String r.slot; "detail", `String r.detail; "output", r.output]
  | Failure f -> `Assoc ["kind", `String "failure"; "transport", `String f.transport; "detail", `String f.detail]
  | Http_failure f -> `Assoc ["kind", `String "http_failure"; "slot", `String f.slot;
      "detail", `String (Exact.execution_error_to_string ~raw_response_to_string:Keeper_exact_flow_detail.raw_response_excerpt f.error);
      "invalid_output", `Bool (invalid_output f.error.cause);
      "raw_response", (match f.error.raw_response with None -> `Null | Some raw -> `String raw.body)]
type http_error = No_http_slot | Advanceable of A.error | Terminal of A.error
let retryable_execution = function
  | Exact.Provider_response_refused {refusal;_} ->
    (match refusal with
     | Exact.Rate_limited | Exact.Overloaded
     | Exact.Server_error | Exact.Network_error | Exact.Timeout
     | Exact.Refusal_body_not_received -> true
     | Exact.Payment_required | Exact.Request_body_refused | Exact.Auth_failed | Exact.Authorization_refused
     | Exact.Invalid_request | Exact.Not_found | Exact.Context_overflow | Exact.Input_capacity -> false)
  | Exact.Completion_failed {error;_} ->
    (match error with
     | Agent_core.Llm_provider.Http_client.ProviderFailure
         {kind=Agent_core.Llm_provider.Http_client.Hard_quota {retry_after};_} ->
       (match retry_after with Some seconds -> Float.is_finite seconds && seconds > 0. | None -> false)
     | Agent_core.Llm_provider.Http_client.ProviderFailure
         {kind=(Agent_core.Llm_provider.Http_client.Capacity_exhausted _
               | Agent_core.Llm_provider.Http_client.Provider_interrupted
               | Agent_core.Llm_provider.Http_client.Provider_reported_error _);_} -> true
     | (Agent_core.Llm_provider.Http_client.HttpError _
       | Agent_core.Llm_provider.Http_client.NetworkError _
       | Agent_core.Llm_provider.Http_client.TimeoutError _
       | Agent_core.Llm_provider.Http_client.AcceptRejected _
       | Agent_core.Llm_provider.Http_client.ProviderTerminal _
       | Agent_core.Llm_provider.Http_client.ProviderFailure _) ->
       Agent_core.Llm_provider.Error.is_retryable (Agent_core.Llm_provider.Error.of_http_error error))
  | Exact.Response_body_deadline_exceeded -> true
  | Exact.Incomplete_output | Exact.Missing_output | Exact.Ambiguous_output _
  | Exact.Unexpected_output_content | Exact.Invalid_json_output -> false
let retryable_candidate rejection =
  match Exact.candidate_rejection_disposition rejection with
  | Exact.Request_preparation_failed -> true
  | Exact.Runtime_slot_unavailable | Exact.Runtime_contract_rejected
  | Exact.Input_contract_rejected | Exact.Output_requirement_rejected
  | Exact.Input_capacity _ -> false
(* A refusal that rejects the request itself -- typed input, authentication,
   configuration -- is [A.Execution_rejected] by the variant's own contract:
   the obligation stays pending and awaits a change event. An unreadable or
   unusable model output stays [A.Invalid_response]. These used to share one
   flag, so an HTTP 400 refusal of the request reported as an invalid
   response. *)
let request_refused = function
  | Exact.Provider_response_refused { refusal; _ } ->
    (match refusal with
     | Exact.Request_body_refused | Exact.Auth_failed
     | Exact.Authorization_refused | Exact.Invalid_request
     | Exact.Not_found | Exact.Context_overflow | Exact.Input_capacity
     | Exact.Payment_required -> true
     | Exact.Refusal_body_not_received | Exact.Rate_limited
     | Exact.Overloaded
     | Exact.Server_error | Exact.Network_error | Exact.Timeout -> false)
  | Exact.Incomplete_output | Exact.Missing_output | Exact.Ambiguous_output _
  | Exact.Unexpected_output_content | Exact.Invalid_json_output
  | Exact.Completion_failed _ | Exact.Response_body_deadline_exceeded -> false
let terminal_error ~rejected ~refused ~retryable cause =
  let detail = flow_failure cause in
  match cause with
  | Exact.Flow_attempt_already_started _ | Exact.Flow_attempt_start_failed _
  | Exact.Flow_measurement_start_failed _ | Exact.Flow_before_measurement_dispatch_callback_failed _
  | Exact.Flow_measurement_terminal_callback_failed _ | Exact.Flow_before_dispatch_callback_failed _
  | Exact.Flow_before_advance_callback_failed _ ->
      (* Stopping this flow does not prove that a later payout attempt will
         fail. Do not turn bookkeeping failures into permanent refusals. *)
      A.Transport_unavailable detail
  | Exact.Flow_candidates_exhausted {rejection;_} ->
      if retryable || retryable_candidate rejection then A.Transport_unavailable detail
      else if refused then A.Execution_rejected detail
      else if rejected then A.Invalid_response detail
      else A.Execution_rejected detail
  | Exact.Flow_exact_execution_failed _ ->
      if retryable then A.Transport_unavailable detail
      else if refused then A.Execution_rejected detail
      else if rejected then A.Invalid_response detail
      else A.Execution_rejected detail
let execute_http ~observe ~resolved ~request ~prompt ~requirement =
  let rejected = ref false in
  let retryable = ref false in
  let refused = ref false in
  let failed (candidate : Exact.flow_attempt_receipt) (error : Exact.execution_error) =
    if invalid_output error.Exact.cause then rejected := true;
    if request_refused error.cause then refused := true;
    if retryable_execution error.cause then retryable := true;
    observe (Http_failure {slot=candidate.visit.identity.candidate_id;error}) in
  let rec candidates = function
    | [] -> Ok []
    | (slot : Runtime_exact_output_registry.selected_slot) :: rest ->
      let* candidate = Exact.make_flow_candidate ~id:slot.slot_id ~admitted_target:slot.admitted_target
        |> Result.map_error (function Exact.Blank_flow_candidate_id -> Terminal (A.Transport_unavailable "blank appraiser slot")) in
      let* rest = candidates rest in Ok (candidate :: rest) in
  let* candidates = candidates (Runtime_exact_lane_backpressure.order resolved).selected_slots in
  match candidates with
  | [] -> Error No_http_slot
  | first :: rest ->
    let messages = Agent_core.Types.[make_message ~role:User [Text prompt]] in
    let* snapshot = Exact.snapshot_flow ~first ~rest ~messages requirement
      |> Result.map_error (function Exact.Duplicate_flow_candidate_id {candidate_id;_} -> Terminal (A.Transport_unavailable ("duplicate slot: " ^ candidate_id))) in
    let* attempt =
      Exact.start_flow
        ~admission_class:(Standalone_lane.admission_class Candle_appraiser)
        snapshot
      |> Result.map_error (function Exact.Flow_id_generation_failed detail -> Terminal (A.Transport_unavailable detail)) in
    match Eio_context.get_net_opt (), Eio_context.get_clock_opt () with
    | Some net, Some clock ->
      let validate success =
        let raw = (Exact.flow_success_output success).output in
        let slot = (Exact.flow_success_candidate success).visit.identity.candidate_id in
        observe (Response {slot;output=raw});
        match A.decode request raw with Ok _ -> Exact.Accept raw | Error detail ->
          rejected := true;
          observe (Rejection {slot;detail;output=raw});
          Exact.Reject_and_advance detail in
      let flow = Exact.execute_flow_once ~net ~clock
        ~before_measurement_dispatch:(fun _ -> Ok ()) ~on_measurement_terminal:(fun _ -> Ok ())
        ~before_dispatch:(fun (attempt : Exact.flow_attempt_receipt) -> observe (Dispatch attempt.visit.identity.candidate_id); Ok ()) ~before_advance:(fun ~failed:failure ~next:_ ->
          (match failure with Exact.Flow_candidate_execution_failed f -> failed f.candidate f.cause
           | Exact.Flow_candidate_rejected rejection ->
             if retryable_candidate rejection then retryable := true); Ok ()) ~validate attempt in
      Runtime_exact_lane_backpressure.observe ~resolved flow;
      (match flow with
       | Ok success -> Ok (success.accepted, (Exact.flow_success_candidate success.transport_success).visit.identity.candidate_id)
       | Error (Exact.Flow_execution_terminal {cause;_}) ->
         (match cause with
          | Exact.Flow_exact_execution_failed f -> failed f.candidate f.cause
          | Exact.Flow_attempt_already_started _ | Exact.Flow_attempt_start_failed _ | Exact.Flow_measurement_start_failed _
          | Exact.Flow_before_measurement_dispatch_callback_failed _ | Exact.Flow_measurement_terminal_callback_failed _
          | Exact.Flow_before_dispatch_callback_failed _ | Exact.Flow_before_advance_callback_failed _ | Exact.Flow_candidates_exhausted _ -> ());
         let error = terminal_error ~rejected:!rejected ~refused:!refused ~retryable:!retryable cause in
         (match Exact.flow_execution_terminal_kind cause with
          | Exact.Advanceable_candidates_exhausted -> Error (Advanceable error)
          | Exact.Non_advanceable_terminal -> Error (Terminal error))
       | Error (Exact.Flow_semantic_candidates_exhausted {rejections;_}) ->
         let detail = String.concat "; " (List.map (fun r -> r.Exact.rejection) (rejections.first :: rejections.rest)) in
         Error (Advanceable (if !retryable then A.Transport_unavailable detail else A.Invalid_response detail)))
    | _ -> Error (Terminal (A.Transport_unavailable "appraiser execution context unavailable"))
(* Retain recovery for transport failures and causes that do not prove a
   permanent refusal. Only typed request/configuration refusals wait for a
   new event. This controls the payout worker; it does not rotate CLI lanes
   or assert that an interrupted native-client turn had no effects. *)
let retryable_codex_error = function
  | Runtime_codex_app_server.Invalid_config _
  | Runtime_codex_app_server.Subscription_required _
  | Runtime_codex_app_server.Unsupported_server_request _
  | Runtime_codex_app_server.Context_window_exceeded _ -> false
  | Runtime_codex_app_server.Rpc_error {code=Some (-32700 | -32600 | -32601 | -32602);_} -> false
  | Runtime_codex_app_server.Rpc_error _ as error ->
    (match Runtime_codex_app_server.input_capacity_refusal error with
     | Some _ -> false | None -> true)
  | Runtime_codex_app_server.Turn_failed {codex_error_info=Some info;_} ->
    (match info with
     | Runtime_codex_app_server.Codex_error_info.Cyber_policy
     | Runtime_codex_app_server.Codex_error_info.Misalignment_policy_violation
     | Runtime_codex_app_server.Codex_error_info.Unauthorized
     | Runtime_codex_app_server.Codex_error_info.Bad_request -> false
     | Runtime_codex_app_server.Codex_error_info.Session_budget_exceeded
     | Runtime_codex_app_server.Codex_error_info.Usage_limit_exceeded
     | Runtime_codex_app_server.Codex_error_info.Rate_limit_exceeded
     | Runtime_codex_app_server.Codex_error_info.Server_overloaded
     | Runtime_codex_app_server.Codex_error_info.Internal_server_error
     | Runtime_codex_app_server.Codex_error_info.Thread_rollback_failed
     | Runtime_codex_app_server.Codex_error_info.Sandbox_error
     | Runtime_codex_app_server.Codex_error_info.Other
     | Runtime_codex_app_server.Codex_error_info.Http_connection_failed _
     | Runtime_codex_app_server.Codex_error_info.Response_stream_connection_failed _
     | Runtime_codex_app_server.Codex_error_info.Response_stream_disconnected _
     | Runtime_codex_app_server.Codex_error_info.Response_too_many_failed_attempts _
     | Runtime_codex_app_server.Codex_error_info.Active_turn_not_steerable _
     | Runtime_codex_app_server.Codex_error_info.Unrecognized _ -> true)
  | Runtime_codex_app_server.Turn_failed {codex_error_info=None;_}
  (* Admission also wraps transient model/list transport failures. *)
  | Runtime_codex_app_server.Reasoning_effort_admission_failed _
  | Runtime_codex_app_server.Spawn_failed _
  | Runtime_codex_app_server.Turn_input_write_failed _
  | Runtime_codex_app_server.Protocol_error _
  | Runtime_codex_app_server.Stopped_by_host _
  | Runtime_codex_app_server.Turn_interrupted
  | Runtime_codex_app_server.Runtime_shutting_down
  | Runtime_codex_app_server.Process_exited _
  | Runtime_codex_app_server.Timeout _ -> true
let retryable_claude_error = function
  | Runtime_claude_code.Invalid_config _
  | Runtime_claude_code.Subscription_required _
  | Runtime_claude_code.Unsupported_control_request _
  | Runtime_claude_code.Context_window_exceeded _ -> false
  | Runtime_claude_code.Spawn_failed _
  | Runtime_claude_code.Protocol_error _
  | Runtime_claude_code.Turn_transport_interrupted _
  | Runtime_claude_code.Turn_failed _
  | Runtime_claude_code.Turn_failed_with_observation _
  | Runtime_claude_code.Stopped_by_host _
  | Runtime_claude_code.Quota_blocked _
  | Runtime_claude_code.Process_exited _
  | Runtime_claude_code.Unhandled_exception _
  | Runtime_claude_code.Timeout _ -> true
let retryable_antigravity_error = function
  | Runtime_antigravity.Invalid_config _ -> false
  | Runtime_antigravity.Spawn_failed _
  | Runtime_antigravity.Protocol_error _
  | Runtime_antigravity.State_callback_failed _
  | Runtime_antigravity.Turn_failed _
  | Runtime_antigravity.Process_exited _
  | Runtime_antigravity.Unhandled_exception _
  | Runtime_antigravity.Timeout _ -> true
let retryable_muse_error = function
  | Runtime_muse_serve.Invalid_config _
  | Runtime_muse_serve.Capability_not_granted _
  | Runtime_muse_serve.Session_not_durable
  | Runtime_muse_serve.Session_model_mismatch _
  | Runtime_muse_serve.Session_workspace_mismatch _
  | Runtime_muse_serve.Session_approval_mode_mismatch _
  | Runtime_muse_serve.Auth_required _
  | Runtime_muse_serve.Unsupported_server_request _ -> false
  | Runtime_muse_serve.Turn_failed error -> error.Runtime_muse_msp.retryable
  | Runtime_muse_serve.Spawn_failed _
  | Runtime_muse_serve.Turn_input_write_failed _
  | Runtime_muse_serve.Protocol_error _
  | Runtime_muse_serve.Rpc_error _
  | Runtime_muse_serve.Turn_cancelled
  | Runtime_muse_serve.Runtime_shutting_down
  | Runtime_muse_serve.Process_exited _
  | Runtime_muse_serve.Timeout _ -> true
let retryable_cli_failure = function
  | Keeper_lane_cli_oneshot.Unknown_runtime _
  | Keeper_lane_cli_oneshot.Not_an_official_client _
  | Keeper_lane_cli_oneshot.Invalid_json_output _
  | Keeper_lane_cli_oneshot.Invalid_domain_output _ -> false
  | Keeper_lane_cli_oneshot.Execution_failed {cause;_} ->
    (match cause with
     | Fusion_official_client.Setup_failure _ -> false
     | Fusion_official_client.Codex_failure error -> retryable_codex_error error
     | Fusion_official_client.Claude_failure error
     | Fusion_official_client.Claude_admission_failure error -> retryable_claude_error error
     | Fusion_official_client.Antigravity_failure error -> retryable_antigravity_error error
     | Fusion_official_client.Muse_failure error -> retryable_muse_error error)
let cli_error failures =
  let detail = String.concat "; " (List.map Keeper_lane_cli_oneshot.failure_to_string failures) in
  if List.exists retryable_cli_failure failures then A.Transport_unavailable detail
  else if List.exists (function
      | Keeper_lane_cli_oneshot.Invalid_json_output _ | Keeper_lane_cli_oneshot.Invalid_domain_output _ -> true
      | Keeper_lane_cli_oneshot.Unknown_runtime _ | Keeper_lane_cli_oneshot.Not_an_official_client _
      | Keeper_lane_cli_oneshot.Execution_failed _ -> false) failures
  then A.Invalid_response detail
  else match failures with
    | [] -> A.Execution_rejected "candle_appraiser CLI walk produced no execution evidence"
    | _ :: _ -> A.Execution_rejected detail
let execute ~cli_runner ~base_path ~observe ~request ~prompt =
  let* resolved = resolve () |> Result.map_error (fun s -> A.Transport_unavailable s) in
  let requirement = Exact.make_output_requirement ~schema:(A.schema request) ~minimum_guarantee:Exact.Json_syntax in
  match execute_http ~observe ~resolved ~request ~prompt ~requirement with
  | Ok answer -> Ok answer
  | Error (Terminal error) -> Error error
  | Error ((No_http_slot | Advanceable _) as previous) ->
    (match previous with Advanceable error -> observe (Failure {transport="http";detail=A.error_to_string error})
     | No_http_slot | Terminal _ -> ());
    match resolved.cli_slots with
    | [] -> (match previous with Advanceable error | Terminal error -> Error error
       | No_http_slot -> Error (A.Execution_rejected "candle_appraiser has no admitted slots"))
    | cli_slots ->
      Keeper_lane_cli_oneshot.walk ?runner:cli_runner ~base_dir:base_path ~cli_slots ~system_prompt:"" ~requirement ~prompt
        ~observe:(function
          | Keeper_lane_cli_oneshot.Dispatching {runtime_id} -> observe (Dispatch runtime_id)
          | Keeper_lane_cli_oneshot.Raw_response {runtime_id;text} -> observe (Raw_response {slot=runtime_id;text}))
        ~validate:(fun raw -> Result.map (fun _ -> raw) (A.decode request raw))
        ~on_failure:(fun failure -> observe (Failure {transport="cli";detail=Keeper_lane_cli_oneshot.failure_to_string failure})) ()
      |> Result.map (fun (slot, raw) ->
        observe (Response {slot;output=raw});
        raw, slot)
      |> Result.map_error (fun failures ->
        let error = cli_error failures in
        match previous, error with
        | Advanceable (A.Transport_unavailable prior),
            (A.Transport_unavailable detail | A.Execution_rejected detail | A.Invalid_response detail)
        | Advanceable (A.Execution_rejected prior | A.Invalid_response prior), A.Transport_unavailable detail ->
          A.Transport_unavailable (prior ^ "; " ^ detail)
        | Advanceable (A.Invalid_response prior), A.Execution_rejected detail ->
          A.Invalid_response (prior ^ "; " ^ detail)
        | (No_http_slot | Advanceable _ | Terminal _),
            (A.Transport_unavailable _ | A.Invalid_response _ | A.Execution_rejected _) -> error)
let run_with ~base_path ~execute ~identity request =
  let registry = Runs.global () in
  let run_id = Random_id.prefixed ~prefix:"candle-appraisal-" ~bytes:16 in
  let started_at = Time_compat.now () in
  let monotonic_start = Mtime_clock.now () in
  let key = prompt_key request in
  let resolution = Prompt_registry.resolve_prompt key in
  let prompt = Prompt_registry.render_resolved_prompt_template key resolution
    ["appraisal_input", Yojson.Safe.to_string (A.input request)] in
  let input = `Assoc ["goal_id", `String identity.A.goal_id; "request_id", `String identity.request_id;
    "verification_run_id", `String identity.verification_run_id; "stage", `String (A.stage request);
    "actual_input", A.input request; "output_schema", A.schema request;
    "prompt", `Assoc ["key", `String key; "source", `String (Prompt_registry.prompt_source_to_string resolution.source);
      "effective_template", `String resolution.effective;
      "rendered", (match prompt with Ok rendered -> `String rendered | Error _ -> `Null)]] in
  Runs.register_running registry ~run_id ~lane:Runs.Candle_appraiser ~actor:base_path ~started_at ~input:(Runs.Exact_input input);
  let attempts = ref [] in
  let selected = ref None in
  let observe observation =
    attempts := observation_json observation :: !attempts;
    match observation with
    | Dispatch slot -> selected := Some slot
    | Response _ | Raw_response _ | Rejection _ | Failure _ | Http_failure _ -> () in
  let complete outcome output =
    Runs.mark_completed registry ~run_id ~outcome
      ~elapsed_s:(Mtime.Span.to_float_ns (Mtime.span monotonic_start (Mtime_clock.now ())) /. 1e9)
      ~selected_slot:!selected ~output:(`Assoc ["result", output; "attempts", `List (List.rev !attempts);
        "semantic_verification", `String "not_performed"])
    |> Result.map_error Runs.completion_error_to_string in
  let fail error =
    let detail = A.error_to_string error in
    let code = match error with
      | A.Invalid_response _ -> "candle_appraisal_rejected"
      | A.Transport_unavailable _ -> "candle_appraisal_unavailable"
      | A.Execution_rejected _ -> "candle_appraisal_execution_rejected" in
    match complete (Runs.Failed {code;detail}) (`Assoc ["error", `String detail]) with
    | Ok () -> Error error
    | Error receipt_error ->
      let detail = detail ^ "; run receipt: " ^ receipt_error in
      (* A receipt failure does not make an already rejected request safe to
         dispatch again. Preserve its scheduling cause while exposing both. *)
      Error (match error with
        | A.Invalid_response _ -> A.Invalid_response detail
        | A.Execution_rejected _ -> A.Execution_rejected detail
        | A.Transport_unavailable _ -> A.Transport_unavailable detail) in
  try
    let result =
      let* prompt = prompt |> Result.map_error (fun detail -> A.Transport_unavailable detail) in
      let* raw, slot_id = execute ~observe ~request ~prompt in
      selected := Some slot_id;
      let* decision = A.decode request raw |> Result.map_error (fun s -> A.Invalid_response s) in
      let* trace = A.trace_of_json (A.trace_json {run_id;slot_id}) |> Result.map_error (fun s -> A.Invalid_response s) in
      let* () = complete Runs.Succeeded raw |> Result.map_error (fun s -> A.Transport_unavailable s) in
      Ok {A.decision;trace} in
    match result with Ok answer -> Ok answer | Error detail -> fail detail
  with
  | Eio.Cancel.Cancelled _ as exn ->
    Eio.Cancel.protect (fun () -> match complete Runs.Cancelled `Null with
      | Ok () -> () | Error detail -> Log.Server.error "candle appraiser cancellation receipt: %s" detail);
    raise exn
  | exn -> fail (A.Transport_unavailable (Printexc.to_string exn))
let run ~base_path = run_with ~base_path ~execute:(execute ~cli_runner:None ~base_path)
module For_testing = struct
  let retryable_execution = retryable_execution
  let terminal_error = terminal_error
  let run_declared ~base_path ~cli_runner = run_with ~base_path ~execute:(execute ~cli_runner:(Some cli_runner) ~base_path)
  let run ~base_path ~execute = run_with ~base_path
    ~execute:(fun ~observe ~request ~prompt ->
      let* raw, slot = execute ~request ~prompt in
      observe (Response {slot;output=raw});
      Ok (raw,slot))
end
