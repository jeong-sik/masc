open Keeper_approval_queue

(** Version of the [hitl_context_summary] schema/record. Bumping this is the
    signal for downstream consumers (dashboard, audit) that the shape or prompt
    contract changed. *)
let summary_version = 2

let system_prompt () =
  Prompt_registry.render_prompt_template Keeper_prompt_names.gate_judgment []
;;

type summary_provider =
  { runtime_id : string
  ; provider_config : Llm_provider.Provider_config.t
  }

let provider_config_for_summary () =
  match Runtime.hitl_summary_runtime_id () with
  | None -> None
  | Some runtime_id ->
    Runtime.get_runtime_by_id runtime_id
    |> Option.map (fun runtime ->
      { runtime_id; provider_config = runtime.Runtime.provider_config })
;;

let readiness () =
  let ( let* ) = Result.bind in
  let* (_ : string) = system_prompt () in
  match Runtime.hitl_summary_runtime_id () with
  | None ->
    Error "Auto Judge requires an explicit [runtime].hitl_summary runtime"
  | Some runtime_id ->
    (match Runtime.get_runtime_by_id runtime_id with
     | Some _ -> Ok ()
     | None ->
       Error
         (Printf.sprintf
            "Auto Judge [runtime].hitl_summary=%s is not loaded"
            runtime_id))
;;

let effective_max_concurrency ~configured ~runtime_limit =
  match runtime_limit with
  | Some limit -> Int.min configured limit
  | None -> configured
;;

let max_concurrency () =
  let configured = Keeper_config.hitl_summary_max_concurrency () in
  let runtime_limit =
    match Runtime.hitl_summary_runtime_id () with
    | Some runtime_id ->
      (match Runtime.get_runtime_by_id runtime_id with
       | Some runtime -> runtime.Runtime.binding.max_concurrent
       | None -> None)
    | None -> None
  in
  effective_max_concurrency ~configured ~runtime_limit
;;

(* ── Metrics ────────────────────────────────────── *)

let () =
  Otel_metric_store.register_counter
    ~name:Keeper_metrics.(to_string HitlSummaryOutcomes)
    ~help:
      "Total HITL context-summary worker outcomes classified by [outcome]. \
       Labels: [outcome] (ok_summary | parse_error | provider_error | timeout | \
       exact_context_unavailable | no_provider_config | no_net | prompt_error | crashed | \
       degraded_plain_json | restart_worker_recovered | \
       restart_judgment_recovered | operator_retry_started). \
       [degraded_plain_json] is emitted alongside the terminal outcome when \
       the judge endpoint could not serve native structured output and the \
       strict plain-JSON capability path was used. The restart outcomes record which exact persisted work \
       was recovered after process restart."
    ()
;;

let record_outcome outcome =
  Otel_metric_store.inc_counter
    Keeper_metrics.(to_string HitlSummaryOutcomes)
    ~labels:[ "outcome", outcome ]
    ()
;;

(* ── Exact request evidence ─────────────────────── *)

type context_bundle_error = Exact_request_context_unavailable

let context_bundle_error_to_string = function
  | Exact_request_context_unavailable ->
    "HITL summary: exact outer-turn request context is unavailable"
;;

let build_context_bundle ~(entry : pending_approval) =
  match entry.request_context with
  | None -> Error Exact_request_context_unavailable
  | Some request_context ->
    Ok
      (`Assoc
         [ "keeper_name", `String entry.keeper_name
         ; "tool_name", `String entry.tool_name
         ; "turn_id", Json_util.int_opt_to_json entry.turn_id
         ; "task_id", Json_util.string_opt_to_json entry.task_id
         ; "goal_id", Json_util.string_opt_to_json entry.goal_id
         ; "goal_ids", `List (List.map (fun g -> `String g) entry.goal_ids)
         ; "input", entry.input
         ; "request_context", request_context
         ])
;;

(* ── LLM call ───────────────────────────────────── *)

let message role text = Agent_sdk.Types.text_message role text

(** How the judge model is asked to return the summary.

    [Native_structured] uses provider-native json_schema structured output.
    [Plain_json_text] is the explicit capability path for judge endpoints that
    cannot serve a native json_schema request — GLM exposes json_object only,
    and raw OpenAI-compatible endpoints (e.g. mimo, runpod proxies) are not
    declared in the OAS catalog. In that mode we prompt for a bare JSON object
    and parse the complete visible text strictly; a parse failure is surfaced
    as [Summary_failed] by the caller, never silently dropped. *)
type summary_mode =
  | Native_structured
  | Plain_json_text

type summary_llm_error =
  | Prompt_unavailable of string
  | Llm_call_error of
      { mode : summary_mode
      ; error : Agent_sdk.Error.sdk_error
      }

let plain_mode_degradation_outcomes = function
  | Plain_json_text -> [ "degraded_plain_json" ]
  | Native_structured -> []
;;

let summary_llm_error_outcomes ~mode error =
  let terminal =
    match error with
    | Agent_sdk.Error.Api (Timeout _) -> "timeout"
    | _ -> "provider_error"
  in
  plain_mode_degradation_outcomes mode @ [ terminal ]
;;

let summary_llm_error_retryable error =
  error
  |> Agent_sdk.Error_domain.of_sdk_error
  |> Agent_sdk.Error_domain.is_retryable
;;

let sdk_error_of_http_error error =
  Agent_sdk.Provider_failure_attribution.sdk_error_of_http_error error
;;

let root_clock_for_body_timeout ~body_timeout_s ~root_clock =
  match body_timeout_s with
  | None -> None
  | Some _ -> root_clock
;;

let body_timeout_clock () =
  root_clock_for_body_timeout
    ~body_timeout_s:(Keeper_runtime_resolved.body_timeout_override_sec ())
    ~root_clock:(Eio_context.get_clock_opt ())
;;

(** Appended on the [Plain_json_text] path so a model without native structured
    output still returns a parseable object. The schema is the SSOT for both
    paths (native applies it as [response_format]; here it is inlined). *)
let plain_json_instruction =
  Printf.sprintf
    "Return ONLY a single JSON object with no markdown fences and no prose. It \
     must conform to this JSON Schema:\n%s"
    (Yojson.Safe.to_string Keeper_structured_output_schema.hitl_context_summary_schema)
;;

let messages_for_summary ~system_prompt ~mode ~context_bundle =
  let base =
    [ message Agent_sdk.Types.System system_prompt
    ; message Agent_sdk.Types.User (Yojson.Safe.to_string context_bundle)
    ]
  in
  match mode with
  | Native_structured -> base
  | Plain_json_text -> base @ [ message Agent_sdk.Types.User plain_json_instruction ]
;;

(** Configure sampling for the summary LLM call and decide the output mode.

    We ask OAS whether this judge endpoint can serve a native json_schema request
    ([validate_output_schema_request]) rather than string-matching the eventual
    provider error. If it cannot, we return the un-schema'd config plus
    [Plain_json_text] so the evaluator still produces a judgment for every
    keeper's model fleet instead of failing outright. *)
let prepare_provider_config ~runtime_id (provider_cfg : Llm_provider.Provider_config.t) =
  let temperature =
    Runtime_inference.resolve_temperature
      ~runtime_id
      ~fallback:Keeper_config.hitl_summary_temperature
  in
  let clamped =
    { provider_cfg with
      temperature = Some temperature
    ; tool_choice = None
    ; disable_parallel_tool_use = true
    }
  in
  let structured =
    Keeper_structured_output_schema.apply_hitl_summary_schema_to_config clamped
  in
  match Llm_provider.Provider_config.validate_output_schema_request structured with
  | Ok () -> structured, Native_structured
  | Error _ -> clamped, Plain_json_text
;;

let call_summary_llm ~sw ~net ~runtime_id ~provider_config ~context_bundle () =
  let config, mode = prepare_provider_config ~runtime_id provider_config in
  let messages =
    match system_prompt () with
    | Ok system_prompt -> Ok (messages_for_summary ~system_prompt ~mode ~context_bundle)
    | Error detail -> Error detail
  in
  match messages with
  | Error detail -> Error (Prompt_unavailable detail)
  | Ok messages ->
    let clock = body_timeout_clock () in
    (match
       Keeper_provider_subcall.complete ~sw ~net ?clock ~config ~messages ()
       |> Result.map_error sdk_error_of_http_error
     with
     | Ok response -> Ok (response, mode)
     | Error error -> Error (Llm_call_error { mode; error }))
;;

(* ── Parsing ────────────────────────────────────── *)

let parse_summary ~generated_at ~model_run_id json =
  match json with
  | `Assoc fields ->
    hitl_context_summary_of_yojson_with_error
      (`Assoc
         ([ "summary_version", `Int summary_version
          ; "generated_at", `Float generated_at
          ; "model_run_id", `String model_run_id
          ]
          @ fields))
  | _ -> Error "HITL summary model output must be a JSON object"
;;

(** Strict parsing of one complete JSON object from the model's visible text,
    used only on the [Plain_json_text] capability path. Fences, surrounding
    prose, trailing bytes, and non-object JSON are rejected. *)
let extract_json_object (text : string) : (Yojson.Safe.t, string) result =
  match Yojson.Safe.from_string (String.trim text) with
  | `Assoc _ as json -> Ok json
  | _ -> Error "HITL summary response must be exactly one JSON object"
  | exception Yojson.Json_error detail ->
    Error ("HITL summary response is not exact JSON: " ^ detail)
;;

let summary_of_response ~generated_at ~mode (response : Agent_sdk.Types.api_response) =
  let parse_json json = parse_summary ~generated_at ~model_run_id:response.id json in
  match mode with
  | Native_structured ->
    (match
       Agent_sdk_response.structured_json_of_response
         ~schema_name:"hitl_context_summary"
         response
     with
     | Ok json -> parse_json json
     | Error detail ->
       Error (Printf.sprintf "HITL summary structured response parse failed: %s" detail))
  | Plain_json_text ->
    (match extract_json_object (Agent_sdk_response.text_of_response response) with
     | Ok json -> parse_json json
     | Error detail -> Error detail)
;;

(* ── Spawn ──────────────────────────────────────── *)

let spawn
      ~sw
      ~runtime_id
      ?provider_config
      ~(entry : pending_approval)
      ~on_summary
      ~on_failure
      ~on_finish
      ()
  =
  let generated_at = Time_compat.now () in
  match build_context_bundle ~entry with
  | Error error ->
    Fun.protect
      ~finally:on_finish
      (fun () ->
         record_outcome "exact_context_unavailable";
         on_failure ~reason:(context_bundle_error_to_string error) ~retryable:false)
  | Ok context_bundle ->
    (match provider_config with
     | None ->
       Fun.protect
         ~finally:on_finish
         (fun () ->
            record_outcome "no_provider_config";
            on_failure ~reason:"HITL summary: no provider config available" ~retryable:true)
     | Some provider_config ->
       Eio.Fiber.fork ~sw (fun () ->
         Fun.protect
           ~finally:on_finish
           (fun () ->
           try
             match Eio_context.get_net_opt () with
             | None ->
               record_outcome "no_net";
               on_failure
                 ~reason:"HITL summary worker: Eio net unavailable"
                 ~retryable:true
             | Some net ->
               (match
                  call_summary_llm ~sw ~net ~runtime_id ~provider_config ~context_bundle ()
                with
                | Ok (response, mode) ->
                  (* Record the degradation itself (not just its outcome) so
                     operators can see when the judge fleet lacks native structured
                     output, rather than it being invisible behind ok/parse_error. *)
                  (match mode with
                   | Plain_json_text ->
                     record_outcome "degraded_plain_json"
                   | Native_structured -> ());
                  (match summary_of_response ~generated_at ~mode response with
                   | Ok summary ->
                     record_outcome "ok_summary";
                     on_summary summary
                   | Error reason ->
                     record_outcome "parse_error";
                     on_failure ~reason ~retryable:true)
                | Error (Prompt_unavailable detail) ->
                  record_outcome "prompt_error";
                  on_failure
                    ~reason:("HITL Gate judgment prompt unavailable: " ^ detail)
                    ~retryable:true
                | Error
                    (Llm_call_error
                       { mode; error = (Agent_sdk.Error.Api (Timeout _) as error) }) ->
                  List.iter
                    record_outcome
                    (summary_llm_error_outcomes ~mode error);
                  on_failure
                    ~reason:"HITL summary LLM call timed out"
                    ~retryable:true
                | Error (Llm_call_error { mode; error }) ->
                  List.iter
                    record_outcome
                    (summary_llm_error_outcomes ~mode error);
                  on_failure
                    ~reason:(Agent_sdk.Error.to_string error)
                    ~retryable:(summary_llm_error_retryable error))
         with
         | Eio.Cancel.Cancelled _ as e -> raise e
         | exn ->
           record_outcome "crashed";
           Log.Keeper.warn
             "HITL summary worker crashed approval_id=%s err=%s"
             entry.id
             (Printexc.to_string exn);
           on_failure ~reason:(Printexc.to_string exn) ~retryable:true)))
;;

module For_testing = struct
  type nonrec summary_mode = summary_mode =
    | Native_structured
    | Plain_json_text

  type nonrec context_bundle_error = context_bundle_error =
    | Exact_request_context_unavailable

  let build_context_bundle = build_context_bundle
  let context_bundle_error_to_string = context_bundle_error_to_string
  let parse_summary = parse_summary
  let summary_of_response = summary_of_response
  let provider_config_for_summary = prepare_provider_config
  let extract_json_object = extract_json_object
  let summary_llm_error_outcomes = summary_llm_error_outcomes
  let summary_llm_error_retryable = summary_llm_error_retryable
  let sdk_error_of_http_error = sdk_error_of_http_error
  let effective_max_concurrency = effective_max_concurrency
  let body_timeout_clock = body_timeout_clock
  let system_prompt = system_prompt
  let summary_version = summary_version
end
;;
