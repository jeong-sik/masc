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

let provider_config_for_summary ~keeper_name =
  let resolve runtime_id =
    Option.map
      (fun runtime ->
         { runtime_id; provider_config = runtime.Runtime.provider_config })
      (Runtime.get_runtime_by_id runtime_id)
  in
  let keeper_runtime_id () =
    match Runtime.runtime_id_for_keeper keeper_name with
    | Some id when String.trim id <> "" -> id
    | Some _ | None -> Keeper_config.default_runtime_id ()
  in
  let summary_runtime_id = Runtime.runtime_id_for_hitl_summary () in
  match resolve summary_runtime_id with
  | Some _ as config -> config
  | None ->
    let fallback_runtime_id = keeper_runtime_id () in
    Log.Keeper.warn
      ~keeper_name
      "HITL judgment runtime=%s is unavailable; falling back to keeper runtime=%s"
      summary_runtime_id
      fallback_runtime_id;
    resolve fallback_runtime_id
;;

(* ── Metrics ────────────────────────────────────── *)

let () =
  Otel_metric_store.register_counter
    ~name:Keeper_metrics.(to_string HitlSummaryOutcomes)
    ~help:
      "Total HITL context-summary worker outcomes classified by [outcome]. \
       Labels: [outcome] (ok_summary | parse_error | provider_error | timeout | \
       no_provider_config | no_net | prompt_error | crashed | \
       degraded_plain_json | restart_worker_recovered | \
       restart_judgment_recovered | restart_retryable_recovered | \
       lane_activity_retry | lane_activity_judgment_recovered). \
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

let with_summary_slot f =
  Eio.Switch.run f
;;

(* ── Context collection ─────────────────────────── *)

type context_acc =
  { partial : bool
  ; notes : string list
  }

let note acc msg = { partial = true; notes = msg :: acc.notes }

let task_context config ~task_id acc =
  try
    let tasks = Workspace_query.get_tasks_safe config in
    match List.find_opt (fun (t : Masc_domain.task) -> String.equal t.id task_id) tasks with
    | None ->
      let acc = note acc (Printf.sprintf "task %s not found" task_id) in
      `Assoc [ "task_id", `String task_id; "found", `Bool false ], [], acc
    | Some task ->
      let task_goal_ids =
        let index = Workspace_goal_index.build_task_goal_index_for_config config in
        match Hashtbl.find_opt index task_id with
        | Some goal_ids -> List.sort_uniq String.compare goal_ids
        | None -> []
      in
      `Assoc
        [ "task_id", `String task_id
        ; "title", `String task.title
        ; "status", `String (Masc_domain.task_status_to_string task.task_status)
        ; "goal_ids", Json_util.json_string_list task_goal_ids
        ; "found", `Bool true
        ], task_goal_ids, acc
  with
  | exn ->
    let acc = note acc (Printf.sprintf "task %s lookup failed: %s" task_id (Printexc.to_string exn)) in
    `Assoc [ "task_id", `String task_id; "found", `Bool false ], [], acc
;;

let goal_context config ~goal_id acc =
  try
    match Goal_store.get_goal config ~goal_id with
    | None ->
      let acc = note acc (Printf.sprintf "goal %s not found" goal_id) in
      `Assoc [ "goal_id", `String goal_id; "found", `Bool false ], acc
    | Some goal ->
      let status_label =
        match Goal_store.goal_status_to_yojson goal.status with
        | `String s -> s
        | other ->
          (* Schema change guard: fail loud instead of silently degrading to
             "unknown". The caller catches and records the exception. *)
          raise
            (Failure
               (Printf.sprintf
                  "goal_status_to_yojson returned non-string for goal %s: %s"
                  goal_id
                  (Yojson.Safe.to_string other)))
      in
      `Assoc
        [ "goal_id", `String goal_id
        ; "title", `String goal.title
        ; "phase", `String (Goal_phase.to_string goal.phase)
        ; "status", `String status_label
        ; "priority", `Int goal.priority
        ; "found", `Bool true
        ], acc
  with
  | exn ->
    let acc = note acc (Printf.sprintf "goal %s lookup failed: %s" goal_id (Printexc.to_string exn)) in
    `Assoc [ "goal_id", `String goal_id; "found", `Bool false ], acc
;;

let chat_context ~base_dir ~keeper_name ~turn_id acc =
  try
    let messages = Keeper_chat_store.load ~base_dir ~keeper_name in
    let filtered =
      List.filter
        (fun (m : Keeper_chat_store.chat_message) ->
           match m.turn_ref with
           | None -> false
           | Some tr -> Int.equal (Ids.Turn_ref.absolute_turn tr) turn_id)
        messages
    in
    Keeper_chat_store.to_json_array filtered, acc
  with
  | exn ->
    let acc = note acc (Printf.sprintf "chat lookup failed: %s" (Printexc.to_string exn)) in
    `List [], acc
;;

let collect_context_parts entry =
  let acc0 =
    match entry.request_context with
    | Some _ -> { partial = false; notes = [] }
    | None ->
      note
        { partial = false; notes = [] }
        "exact outer-turn request context is unavailable"
  in
  let config_opt, acc =
    try Some (Workspace_utils.default_config entry.audit_base_path), acc0 with
    | exn ->
      ( None
      , note acc0 (Printf.sprintf "workspace config unavailable: %s" (Printexc.to_string exn)) )
  in
  let task_json, task_goal_ids, acc =
    match entry.task_id, config_opt with
    | Some task_id, Some config -> task_context config ~task_id acc
    | Some task_id, None ->
      let acc = note acc (Printf.sprintf "task %s skipped (no workspace config)" task_id) in
      `Assoc [ "task_id", `String task_id; "found", `Bool false ], [], acc
    | None, _ -> `Null, [], acc
  in
  let goal_ids =
    (match entry.goal_id with
     | Some g -> [ g ]
     | None -> [])
    @ entry.goal_ids
    @ task_goal_ids
    |> List.filter (fun s -> not (String.equal s ""))
    |> List.sort_uniq String.compare
  in
  let goals_json, acc =
    match config_opt with
    | Some config ->
      let goals, acc =
        List.fold_left
          (fun (goals, acc) goal_id ->
             let g, acc = goal_context config ~goal_id acc in
             g :: goals, acc)
          ([], acc)
          goal_ids
      in
      `List (List.rev goals), acc
    | None ->
      let acc =
        if goal_ids <> [] then note acc "goals skipped (no workspace config)" else acc
      in
      `List [], acc
  in
  let chat_json, acc =
    match entry.turn_id with
    | Some turn_id ->
      chat_context ~base_dir:entry.audit_base_path ~keeper_name:entry.keeper_name ~turn_id acc
    | None -> `Null, acc
  in
  task_json, goals_json, chat_json, acc.partial, acc.notes
;;

let build_context_bundle ~(entry : pending_approval) : Yojson.Safe.t =
  let task_json, goals_json, chat_json, partial_context, context_notes =
    collect_context_parts entry
  in
  `Assoc
    [ "keeper_name", `String entry.keeper_name
    ; "tool_name", `String entry.tool_name
    ; "turn_id", Json_util.int_opt_to_json entry.turn_id
    ; "task_id", Json_util.string_opt_to_json entry.task_id
    ; "goal_id", Json_util.string_opt_to_json entry.goal_id
    ; "goal_ids", `List (List.map (fun g -> `String g) entry.goal_ids)
    ; "input", entry.input
    ; ( "request_context"
      , match entry.request_context with
        | Some context -> context
        | None -> `Null )
    ; "task", task_json
    ; "goals", goals_json
    ; "chat_messages", chat_json
    ; "partial_context", `Bool partial_context
    ; "context_notes", `List (List.rev_map (fun s -> `String s) context_notes)
    ]
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
    (match
       Keeper_llm_bridge.run_with_timeout_and_fallback
         ~timeout_s:(Keeper_config.hitl_summary_timeout_sec ())
         (fun () ->
            Llm_provider.Complete.complete ~sw ~net ~config ~messages ()
            |> Result.map_error (fun http_err ->
                 Agent_sdk.Error.Internal (Provider_http_error.to_message http_err)))
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
  match provider_config with
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
          with_summary_slot (fun sw ->
          let context_bundle = build_context_bundle ~entry in
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
                 ~retryable:false
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
               on_failure ~reason:(Agent_sdk.Error.to_string error) ~retryable:true))
      with
      | Eio.Cancel.Cancelled _ as e -> raise e
      | exn ->
        record_outcome "crashed";
        Log.Keeper.warn
          "HITL summary worker crashed approval_id=%s err=%s"
          entry.id
          (Printexc.to_string exn);
          on_failure ~reason:(Printexc.to_string exn) ~retryable:true))
;;

module For_testing = struct
  type nonrec summary_mode = summary_mode =
    | Native_structured
    | Plain_json_text

  let build_context_bundle = build_context_bundle
  let parse_summary = parse_summary
  let summary_of_response = summary_of_response
  let provider_config_for_summary = prepare_provider_config
  let extract_json_object = extract_json_object
  let summary_llm_error_outcomes = summary_llm_error_outcomes
  let system_prompt = system_prompt
  let summary_version = summary_version
end
;;
