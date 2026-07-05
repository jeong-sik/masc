open Keeper_approval_queue_rules_types

(** Version of the [hitl_context_summary] schema/record. Bumping this is the
    signal for downstream consumers (dashboard, audit) that the shape or prompt
    contract changed. *)
let summary_version = 1

(** The HITL summary system prompt is intentionally a single module-level
    string. It is short and stable; versioning is carried by [summary_version]
    and the structured-output schema, so prompt tweaks are reflected in the
    output record version rather than by a separate prompt registry ID. *)
let system_prompt =
  "You are a neutral forensic analyst helping a human operator review a keeper \
   tool-approval request. Summarize the context, surface the most important \
   uncertainties, and suggest concrete approval options. Each option should \
   include a short label, a rationale, and an optional estimated risk delta \
   (one of: low, medium, high, critical). If the current turn/chat is part of \
   an active task or goal, state the relationship explicitly in the first \
   sentence of context_summary. If context collection was partial \
   (partial_context=true), raise uncertainty and call out what is missing. \
   Respond only with the requested JSON."
;;

(* ── Metrics ────────────────────────────────────── *)

let () =
  Otel_metric_store.register_counter
    ~name:Keeper_metrics.(to_string HitlSummaryOutcomes)
    ~help:
      "Total HITL context-summary worker outcomes classified by [outcome]. \
       Labels: [outcome] (ok_summary | parse_error | provider_error | timeout | \
       no_provider_config | no_net | slot_unavailable | crashed | \
       degraded_plain_json), [risk_level]. [degraded_plain_json] is emitted \
       alongside the terminal outcome when the judge endpoint could not serve \
       native structured output and the plain-text JSON path was used."
    ()
;;

let record_outcome ~risk_level outcome =
  Otel_metric_store.inc_counter
    Keeper_metrics.(to_string HitlSummaryOutcomes)
    ~labels:
      [ "outcome", outcome
      ; "risk_level", risk_level_to_string risk_level
      ]
    ()
;;

(* ── Bounded concurrency ────────────────────────── *)

(** Global semaphore cap for in-flight HITL summary LLM calls. Created lazily
    so [Runtime_params] is initialized before the limit is read. The cap is
    sampled at creation time; a runtime-param change takes effect only after
    process restart, which matches other capacity-sensitive gates in the
    codebase. *)
let summary_semaphore =
  lazy (Eio.Semaphore.make (Keeper_config.hitl_summary_concurrency_limit ()))
;;

let with_summary_slot f =
  let sem = Lazy.force summary_semaphore in
  Eio.Switch.run (fun sw ->
    Eio.Semaphore.acquire sem;
    Eio.Switch.on_release sw (fun () -> Eio.Semaphore.release sem);
    f sw)
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
      `Assoc [ "task_id", `String task_id; "found", `Bool false ], acc
    | Some task ->
      let task_goal_id =
        let index = Workspace_goal_index.build_task_goal_index_for_config config in
        match Hashtbl.find_opt index task_id with
        | Some (g :: _) -> Some g
        | Some [] | None -> None
      in
      `Assoc
        [ "task_id", `String task_id
        ; "title", `String task.title
        ; "status", `String (Masc_domain.task_status_to_string task.task_status)
        ; "goal_id", Json_util.string_opt_to_json task_goal_id
        ; "found", `Bool true
        ], acc
  with
  | exn ->
    let acc = note acc (Printf.sprintf "task %s lookup failed: %s" task_id (Printexc.to_string exn)) in
    `Assoc [ "task_id", `String task_id; "found", `Bool false ], acc
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
    let rec take n acc = function
      | [] -> List.rev acc
      | _ when n <= 0 -> List.rev acc
      | x :: xs -> take (n - 1) (x :: acc) xs
    in
    Keeper_chat_store.to_json_array
      (take (Keeper_config.hitl_summary_chat_message_limit ()) [] filtered),
    acc
  with
  | exn ->
    let acc = note acc (Printf.sprintf "chat lookup failed: %s" (Printexc.to_string exn)) in
    `List [], acc
;;

let collect_context_parts entry =
  let acc0 = { partial = false; notes = [] } in
  let config_opt, acc =
    try Some (Workspace_utils.default_config entry.audit_base_path), acc0 with
    | exn ->
      ( None
      , note acc0 (Printf.sprintf "workspace config unavailable: %s" (Printexc.to_string exn)) )
  in
  let task_json, acc =
    match entry.task_id, config_opt with
    | Some task_id, Some config -> task_context config ~task_id acc
    | Some task_id, None ->
      let acc = note acc (Printf.sprintf "task %s skipped (no workspace config)" task_id) in
      `Assoc [ "task_id", `String task_id; "found", `Bool false ], acc
    | None, _ -> `Null, acc
  in
  let goal_ids =
    (match entry.goal_id with
     | Some g -> [ g ]
     | None -> [])
    @ entry.goal_ids
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
  (* Board signals are not collected yet; we intentionally do NOT mark the
     context partial just because this optional dimension is absent. partial
     is reserved for lookup failures. *)
  task_json, goals_json, chat_json, acc.partial, acc.notes
;;

let build_context_bundle ~(entry : pending_approval) : Yojson.Safe.t =
  let task_json, goals_json, chat_json, partial_context, context_notes =
    collect_context_parts entry
  in
  `Assoc
    [ "keeper_name", `String entry.keeper_name
    ; "tool_name", `String entry.tool_name
    ; "action_key", `String entry.action_key
    ; "risk_level", `String (risk_level_to_string entry.risk_level)
    ; "sandbox_target", `String entry.sandbox_target
    ; "turn_id", Json_util.int_opt_to_json entry.turn_id
    ; "task_id", Json_util.string_opt_to_json entry.task_id
    ; "goal_id", Json_util.string_opt_to_json entry.goal_id
    ; "goal_ids", `List (List.map (fun g -> `String g) entry.goal_ids)
    ; "input", entry.input
    ; "task", task_json
    ; "goals", goals_json
    ; "chat_messages", chat_json
    ; "board_signals", `Null
    ; "partial_context", `Bool partial_context
    ; "context_notes", `List (List.rev_map (fun s -> `String s) context_notes)
    ]
;;

(* ── LLM call ───────────────────────────────────── *)

let message role text = Agent_sdk.Types.text_message role text

(** How the judge model is asked to return the summary.

    [Native_structured] uses provider-native json_schema structured output.
    [Plain_json_text] is the graceful-degradation path for judge endpoints that
    cannot serve a native json_schema request — GLM exposes json_object only,
    and raw OpenAI-compatible endpoints (e.g. mimo, runpod proxies) are not
    declared in the OAS catalog. In that mode we prompt for a bare JSON object
    and parse the model's visible text best-effort; a parse failure is surfaced
    as [Summary_failed] by the caller, never silently dropped. *)
type summary_mode =
  | Native_structured
  | Plain_json_text

(** Appended on the [Plain_json_text] path so a model without native structured
    output still returns a parseable object. The schema is the SSOT for both
    paths (native applies it as [response_format]; here it is inlined). *)
let plain_json_instruction =
  Printf.sprintf
    "Return ONLY a single JSON object with no markdown fences and no prose. It \
     must conform to this JSON Schema:\n%s"
    (Yojson.Safe.to_string Keeper_structured_output_schema.hitl_context_summary_schema)
;;

let messages_for_summary ~mode ~context_bundle =
  let base =
    [ message Agent_sdk.Types.System system_prompt
    ; message Agent_sdk.Types.User (Yojson.Safe.to_string context_bundle)
    ]
  in
  match mode with
  | Native_structured -> base
  | Plain_json_text -> base @ [ message Agent_sdk.Types.User plain_json_instruction ]
;;

(** Cap cost and sampling for the summary LLM call (mirrors the guard in
    [keeper_memory_llm_summary.provider_for_summary]) and decide the output mode.

    We ask OAS whether this judge endpoint can serve a native json_schema request
    ([validate_output_schema_request]) rather than string-matching the eventual
    provider error. If it cannot, we return the un-schema'd config plus
    [Plain_json_text] so the evaluator still produces a judgment for every
    keeper's model fleet instead of failing outright. *)
let provider_config_for_summary (provider_cfg : Llm_provider.Provider_config.t) =
  let summary_max_tokens = Keeper_config.hitl_summary_max_tokens () in
  let max_tokens =
    match provider_cfg.max_tokens with
    | Some n when n > 0 -> Some (min n summary_max_tokens)
    | Some _ ->
      (* DET-OK: an invalid (non-positive) upstream token budget is treated as
         unset; we clamp to the policy cap at this boundary. *)
      Some summary_max_tokens
    | None -> Some summary_max_tokens
  in
  let clamped =
    { provider_cfg with
      max_tokens
    ; temperature = Some (Keeper_config.hitl_summary_temperature ())
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

let call_summary_llm ~sw ~net ~provider_config ~context_bundle () =
  let config, mode = provider_config_for_summary provider_config in
  let messages = messages_for_summary ~mode ~context_bundle in
  Keeper_llm_bridge.run_with_timeout_and_fallback
    ~timeout_s:(Keeper_config.hitl_summary_timeout_sec ())
    (fun () ->
       Llm_provider.Complete.complete ~sw ~net ~config ~messages ()
       |> Result.map (fun response -> response, mode)
       |> Result.map_error (fun http_err ->
            Agent_sdk.Error.Internal (Provider_http_error.to_message http_err)))
;;

(* ── Parsing ────────────────────────────────────── *)

let parse_suggested_option json =
  let open Yojson.Safe.Util in
  let label = json |> member "label" |> to_string in
  let rationale = json |> member "rationale" |> to_string in
  let estimated_risk_delta =
    match json |> member "estimated_risk_delta" with
    | `Null -> None
    | `String s ->
      (match risk_level_of_string s with
       | Some lvl -> Some lvl
       | None ->
         raise
           (Failure
              (Printf.sprintf
                 "estimated_risk_delta %S is not %s"
                 s
                 allowed_risk_level_values_label)))
    | other ->
      raise
        (Failure
           (Printf.sprintf
              "estimated_risk_delta must be null or %s, got %s"
              allowed_risk_level_values_label
              (Yojson.Safe.to_string other)))
  in
  { label; rationale; estimated_risk_delta }
;;

let parse_summary ~generated_at ~model_run_id json =
  let open Yojson.Safe.Util in
  { summary_version
  ; generated_at
  ; model_run_id
  ; context_summary = json |> member "context_summary" |> to_string
  ; key_questions = json |> member "key_questions" |> convert_each to_string
  ; suggested_options = json |> member "suggested_options" |> convert_each parse_suggested_option
  ; risk_rationale = json |> member "risk_rationale" |> to_string_option
  ; uncertainty = json |> member "uncertainty" |> to_float
  }
;;

(** Best-effort extraction of a single JSON object from a model's visible text,
    used only on the [Plain_json_text] degradation path. Tries the trimmed text
    as-is, then the first ['{'] .. last ['}'] span (which also covers a fenced
    ```json block, since the braces sit inside the fence). Returns [Error]
    rather than a partial object so the caller surfaces [Summary_failed] instead
    of silently accepting non-conforming output. *)
let extract_json_object (text : string) : (Yojson.Safe.t, string) result =
  let try_parse s =
    match Yojson.Safe.from_string (String.trim s) with
    | `Assoc _ as json -> Some json
    | _ -> None
    | exception _ -> None
  in
  let brace_span () =
    match String.index_opt text '{', String.rindex_opt text '}' with
    | Some i, Some j when j > i -> Some (String.sub text i (j - i + 1))
    | _ -> None
  in
  match try_parse text with
  | Some json -> Ok json
  | None ->
    (match Option.bind (brace_span ()) try_parse with
     | Some json -> Ok json
     | None -> Error "HITL summary: no JSON object found in model response text")
;;

let summary_of_response ~generated_at ~mode (response : Agent_sdk.Types.api_response) =
  let parse_json json =
    try Ok (parse_summary ~generated_at ~model_run_id:response.id json) with
    | exn ->
      Error (Printf.sprintf "HITL summary parse failed: %s" (Printexc.to_string exn))
  in
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

let spawn ~sw ?provider_config ~(entry : pending_approval) ~on_summary ~on_failure () =
  let generated_at = Time_compat.now () in
  match provider_config with
  | None ->
    record_outcome ~risk_level:entry.risk_level "no_provider_config";
    on_failure ~reason:"HITL summary: no provider config available" ~retryable:false
  | Some provider_config ->
    Eio.Fiber.fork ~sw (fun () ->
      try
        with_summary_slot (fun sw ->
          let context_bundle = build_context_bundle ~entry in
          match Eio_context.get_net_opt () with
          | None ->
            record_outcome ~risk_level:entry.risk_level "no_net";
            on_failure ~reason:"HITL summary worker: Eio net unavailable" ~retryable:true
          | Some net ->
            (match call_summary_llm ~sw ~net ~provider_config ~context_bundle () with
             | Ok (response, mode) ->
               (* Record the degradation itself (not just its outcome) so
                  operators can see when the judge fleet lacks native structured
                  output, rather than it being invisible behind ok/parse_error. *)
               (match mode with
                | Plain_json_text ->
                  record_outcome ~risk_level:entry.risk_level "degraded_plain_json"
                | Native_structured -> ());
               (match summary_of_response ~generated_at ~mode response with
                | Ok summary ->
                  record_outcome ~risk_level:entry.risk_level "ok_summary";
                  on_summary summary
                | Error reason ->
                  record_outcome ~risk_level:entry.risk_level "parse_error";
                  on_failure ~reason ~retryable:true)
             | Error (Agent_sdk.Error.Api (Timeout _)) ->
               record_outcome ~risk_level:entry.risk_level "timeout";
               on_failure ~reason:"HITL summary LLM call timed out" ~retryable:true
             | Error err ->
               record_outcome ~risk_level:entry.risk_level "provider_error";
               on_failure ~reason:(Agent_sdk.Error.to_string err) ~retryable:true))
      with
      | Eio.Cancel.Cancelled _ as e -> raise e
      | exn ->
        record_outcome ~risk_level:entry.risk_level "crashed";
        Log.Keeper.warn
          "HITL summary worker crashed approval_id=%s err=%s"
          entry.id
          (Printexc.to_string exn);
        on_failure ~reason:(Printexc.to_string exn) ~retryable:true)
;;

module For_testing = struct
  type nonrec summary_mode = summary_mode =
    | Native_structured
    | Plain_json_text

  let build_context_bundle = build_context_bundle
  let parse_summary = parse_summary
  let summary_of_response = summary_of_response
  let provider_config_for_summary = provider_config_for_summary
  let extract_json_object = extract_json_object
  let summary_version = summary_version
end
;;
