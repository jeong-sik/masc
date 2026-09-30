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
let invalid_output = function
  | Exact.Incomplete_output | Exact.Missing_output | Exact.Ambiguous_output _
  | Exact.Unexpected_output_content | Exact.Invalid_json_output -> true
  | Exact.Completion_failed _ | Exact.Response_body_deadline_exceeded | Exact.Provider_response_refused _ -> false
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
let execute_http ~observe ~resolved ~request ~prompt ~requirement =
  let rejected = ref false in
  let failed (candidate : Exact.flow_attempt_receipt) (error : Exact.execution_error) =
    if invalid_output error.Exact.cause then rejected := true;
    observe (Http_failure {slot=candidate.visit.identity.candidate_id;error}) in
  let classify detail = if !rejected then A.Invalid_response detail else A.Transport_unavailable detail in
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
    let* attempt = Exact.start_flow snapshot
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
           | Exact.Flow_candidate_rejected _ -> ()); Ok ()) ~validate attempt in
      Runtime_exact_lane_backpressure.observe flow;
      (match flow with
       | Ok success -> Ok (success.accepted, (Exact.flow_success_candidate success.transport_success).visit.identity.candidate_id)
       | Error (Exact.Flow_execution_terminal {cause;_}) ->
         (match cause with
          | Exact.Flow_exact_execution_failed f -> failed f.candidate f.cause
          | Exact.Flow_attempt_already_started _ | Exact.Flow_attempt_start_failed _ | Exact.Flow_measurement_start_failed _
          | Exact.Flow_before_measurement_dispatch_callback_failed _ | Exact.Flow_measurement_terminal_callback_failed _
          | Exact.Flow_before_dispatch_callback_failed _ | Exact.Flow_before_advance_callback_failed _ | Exact.Flow_candidates_exhausted _ -> ());
         let detail = flow_failure cause in
         (match Exact.flow_execution_terminal_kind cause with
          | Exact.Advanceable_candidates_exhausted -> Error (Advanceable (classify detail))
          | Exact.Non_advanceable_terminal -> Error (Terminal (classify detail)))
       | Error (Exact.Flow_semantic_candidates_exhausted {rejections;_}) ->
         Error (Advanceable (A.Invalid_response (String.concat "; " (List.map (fun r -> r.Exact.rejection) (rejections.first :: rejections.rest))))))
    | _ -> Error (Terminal (A.Transport_unavailable "appraiser execution context unavailable"))
let cli_error failures =
  let detail = String.concat "; " (List.map Keeper_lane_cli_oneshot.failure_to_string failures) in
  if List.exists (function
      | Keeper_lane_cli_oneshot.Invalid_json_output _ | Keeper_lane_cli_oneshot.Invalid_domain_output _ -> true
      | Keeper_lane_cli_oneshot.Unknown_runtime _ | Keeper_lane_cli_oneshot.Not_an_official_client _
      | Keeper_lane_cli_oneshot.Execution_failed _ -> false) failures
  then A.Invalid_response detail else A.Transport_unavailable detail
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
       | No_http_slot -> Error (A.Transport_unavailable "candle_appraiser has no admitted slots"))
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
        | Advanceable (A.Invalid_response prior), A.Transport_unavailable detail -> A.Invalid_response (prior ^ "; " ^ detail)
        | (No_http_slot | Advanceable _ | Terminal _), (A.Transport_unavailable _ | A.Invalid_response _) -> error)
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
    let code = match error with A.Invalid_response _ -> "candle_appraisal_rejected" | A.Transport_unavailable _ -> "candle_appraisal_unavailable" in
    match complete (Runs.Failed {code;detail}) (`Assoc ["error", `String detail]) with
    | Ok () -> Error error
    | Error receipt_error -> Error (A.Transport_unavailable (detail ^ "; run receipt: " ^ receipt_error)) in
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
  let run_declared ~base_path ~cli_runner = run_with ~base_path ~execute:(execute ~cli_runner:(Some cli_runner) ~base_path)
  let run ~base_path ~execute = run_with ~base_path
    ~execute:(fun ~observe ~request ~prompt ->
      let* raw, slot = execute ~request ~prompt in
      observe (Response {slot;output=raw});
      Ok (raw,slot))
end
