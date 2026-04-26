(** Tool_local_runtime_verify -- runtime contract verification. *)

include Tool_local_runtime_http
module Oas_types = Oas.Types

let runtime_snapshots_for_pool runtime_pool =
  let snapshots = Local_runtime_pool.snapshots () in
  match Option.bind runtime_pool trim_to_option with
  | None -> snapshots
  | Some pool when String.equal pool Local_runtime_pool.default_pool_label -> snapshots
  | Some pool ->
      let filtered =
        List.filter
          (fun (runtime : Local_runtime_pool.runtime_snapshot) ->
            String.equal runtime.id pool || String.equal runtime.base_url pool)
          snapshots
      in
      if filtered = [] then snapshots else filtered

let safe_discovery_endpoints () =
  try Some (Discovery_cache.get_cached_or_refresh ())
  with
  | Stdlib.Effect.Unhandled _ -> None
  | _ -> None

let discovery_endpoints_for_pool runtime_pool =
  match safe_discovery_endpoints () with
  | None -> None
  | Some [] -> None
  | Some endpoints ->
      let matches_pool (endpoint : Discovery_cache.endpoint_info) =
        match Option.bind runtime_pool trim_to_option with
        | None -> true
        | Some pool
          when String.equal pool Local_runtime_pool.default_pool_label
               || String.equal pool "default" ->
            true
        | Some pool ->
            String.equal pool endpoint.url
            || String.equal pool
                 (Local_runtime_pool.runtime_id_of_base_url endpoint.url)
      in
      let filtered = List.filter matches_pool endpoints in
      Some (if filtered = [] then endpoints else filtered)

let active_slots_of_json json =
  let open Yojson.Safe.Util in
  let slots =
    match json with
    | `List items -> items
    | `Assoc _ -> (
        match member "slots" json with
        | `List items -> items
        | _ -> (
            match member "data" json with
            | `List items -> items
            | _ -> (
                match member "items" json with `List items -> items | _ -> [])))
    | _ -> []
  in
  let is_active slot =
    let status =
      slot |> member "status" |> to_string_option |> Option.value ~default:""
      |> String.lowercase_ascii
    in
    (slot |> member "is_processing" |> to_bool_option |> Option.value ~default:false)
    || (match slot |> member "state" with
       | `Int value -> value <> 0
       | `Intlit value -> Option.value ~default:0 (parse_int_opt value) <> 0
       | _ -> false)
    || status = "processing" || status = "prompt" || status = "generating"
  in
  List.fold_left (fun acc slot -> if is_active slot then acc + 1 else acc) 0 slots

let slot_count_of_json json =
  let open Yojson.Safe.Util in
  let slots =
    match json with
    | `List items -> items
    | `Assoc _ -> (
        match member "slots" json with
        | `List items -> items
        | _ -> (
            match member "data" json with
            | `List items -> items
            | _ -> (
                match member "items" json with `List items -> items | _ -> [])))
    | _ -> []
  in
  List.length slots

let endpoint_model_id (endpoint : Discovery_cache.endpoint_info) =
  match endpoint.models with
  | model :: _ -> trim_to_option model.id
  | [] -> (
      match endpoint.props with
      | Some props -> trim_to_option props.model
      | None -> None)

let endpoint_total_slots (endpoint : Discovery_cache.endpoint_info) =
  match endpoint.slots with
  | Some slots when slots.total > 0 -> Some slots.total
  | _ -> (
      match endpoint.props with
      | Some props when props.total_slots > 0 -> Some props.total_slots
      | _ -> None)

let endpoint_ctx_size (endpoint : Discovery_cache.endpoint_info) =
  match endpoint.props with
  | Some props when props.ctx_size > 0 -> Some props.ctx_size
  | _ -> None

let endpoint_busy_slots (endpoint : Discovery_cache.endpoint_info) =
  match endpoint.slots with Some slots -> slots.busy | None -> 0

let first_endpoint_url endpoints =
  match endpoints with
  | (endpoint : Discovery_cache.endpoint_info) :: _ -> Some endpoint.url
  | [] -> None

let error_message_of_http_error = function
  | Llm_provider.Http_client.ProviderTerminal { message; _ } -> message
  | Llm_provider.Http_client.NetworkError { message; _ } -> message
  | Llm_provider.Http_client.AcceptRejected { reason } -> reason
  | Llm_provider.Http_client.CliTransportRequired { kind } ->
      Printf.sprintf "%s provider requires a CLI transport" kind
  | Llm_provider.Http_client.ProviderTerminal
      { kind = Llm_provider.Http_client.Max_turns { turns; limit }; message } ->
      Printf.sprintf "provider terminal: max turns exceeded (%d/%d): %s"
        turns limit message
  | Llm_provider.Http_client.ProviderTerminal
      { kind = Llm_provider.Http_client.Other subtype; message } ->
      Printf.sprintf "provider terminal: %s: %s" subtype message
  | Llm_provider.Http_client.HttpError { code; body } -> (
      try
        let json = Yojson.Safe.from_string body in
        match Yojson.Safe.Util.member "error" json with
        | `Assoc fields -> (
            match List.assoc_opt "message" fields with
            | Some (`String msg) -> msg
            | _ -> Printf.sprintf "HTTP %d" code)
        | _ -> Printf.sprintf "HTTP %d" code
      with Yojson.Json_error _ -> Printf.sprintf "HTTP %d" code)

(** Probe whether an endpoint supports the OpenAI chat-completions protocol.
    This is a protocol-level probe; it explicitly depends on OAS
    [Llm_provider.Complete.complete] because the goal is to verify the
    endpoint's wire protocol, not to run a full agent turn. *)
let probe_chat_completion_compatible
    ?(timeout_sec = 5)
    (endpoint : Discovery_cache.endpoint_info) =
  match Masc_eio_env.get_opt (), endpoint_model_id endpoint with
  | None, _ -> (None, None)
  | _, None ->
      Log.warn ~ctx:"runtime_verify"
        "chat-completions probe skipped caller_surface=runtime_verify endpoint=%s reason=missing_model_id"
        endpoint.url;
      (None, Some "missing model id")
  | Some env, Some model_id ->
      Log.info ~ctx:"runtime_verify"
        "chat-completions probe caller_surface=runtime_verify endpoint=%s model_id=%s timeout_sec=%d"
        endpoint.url model_id timeout_sec;
      let provider_config =
        Llm_provider.Provider_config.make
          ~kind:Llm_provider.Provider_config.OpenAI_compat
          ~model_id ~base_url:endpoint.url
          ~request_path:Masc_network_defaults.openai_chat_completions_path
          ~max_tokens:1 ~temperature:Oas_worker_cascade.deterministic_temperature ()
      in
      let messages : Oas_types.message list =
        [
          {
            Oas_types.role = Oas_types.User;
            content = [ Oas_types.Text "hi" ];
            name = None;
            tool_call_id = None;
            metadata = [];
          };
        ]
      in
      let run_completion () =
        Llm_provider.Complete.complete ~sw:env.sw ~net:env.net
          ~config:provider_config ~messages ()
      in
      let outcome =
        match env.clock with
        | Some clock -> (
            try Ok (Eio.Time.with_timeout_exn clock (float_of_int timeout_sec) run_completion)
            with Eio.Time.Timeout -> Error "timeout")
        | None -> Ok (run_completion ())
      in
      match outcome with
      | Error message -> (Some false, Some message)
      | Ok (Ok _response) -> (Some true, None)
      | Ok (Error http_error) ->
          (Some false, Some (error_message_of_http_error http_error))

let provider_health_reachable ~status ~body:_ =
  status = Some 200

let chat_contract_probe_body ~model_id =
  Yojson.Safe.to_string
    (`Assoc
      [
        ("model", `String model_id);
        ("messages", `List [ `Assoc [ ("role", `String "user"); ("content", `String "ping") ] ]);
        ("max_tokens", `Int 1);
        ("temperature", `Float 0.0);
      ])

let chat_contract_reachable ~status ~body =
  if status <> Some 200 then
    false
  else
    match body with
    | None -> false
    | Some payload -> (
        match Yojson.Safe.from_string payload with
        | exception Yojson.Json_error _ -> false
        | json -> (
            match Yojson.Safe.Util.member "choices" json with
            | `List _ -> true
            | _ -> false))

let chat_contract_status ~status ~body =
  match status with
  | Some 200 when chat_contract_reachable ~status ~body -> "confirmed"
  | Some (400 | 404 | 405 | 415 | 422) -> "rejected"
  | Some _ -> "unknown"
  | None -> "unknown"

let classify_runtime_blocker ~provider_reachable ~slot_reachable
    ~chat_contract_status ~expected_model ~actual_model_id ~expected_slots
    ~actual_slots_total ~expected_ctx ~actual_ctx ~chat_completion_compatible
    =
  if not provider_reachable || not slot_reachable then
    (Some "provider_unreachable", Some "llama runtime health or slots endpoint failed")
  else if not chat_completion_compatible then
    ( Some "provider_protocol_incompatible",
      Some "one or more endpoints failed the OAS chat-completions probe" )
  else if
    match expected_model, actual_model_id with
    | Some expected, Some actual -> not (String.equal expected actual)
    | Some _, None -> true
    | _ -> false
  then
    ( Some "provider_model_mismatch",
      Some
        (Printf.sprintf "expected model %s, got %s"
           (Option.value ~default:"<missing>" expected_model)
           (Option.value ~default:"<mixed-or-missing>" actual_model_id)) )
  else if
    match expected_slots with
    | Some expected -> actual_slots_total < expected
    | None -> false
  then
    ( Some "slot_count_insufficient",
      Some
        (Printf.sprintf "expected at least %d slots, got %d"
           (Option.value ~default:0 expected_slots) actual_slots_total) )
  else if
    match expected_ctx, actual_ctx with
    | Some expected, Some actual -> expected <> actual
    | Some _, None -> true
    | _ -> false
  then
    ( Some "ctx_mismatch",
      Some
        (Printf.sprintf "expected ctx %s, got %s"
           (match expected_ctx with Some value -> string_of_int value | None -> "<none>")
           (match actual_ctx with Some value -> string_of_int value | None -> "<mixed-or-missing>")) )
  else if String.equal chat_contract_status "rejected" then
    ( Some "chat_contract_incompatible",
      Some "runtime passed health/slots but failed /v1/chat/completions contract probe" )
  else
    (None, None)

let runtime_verify_json_from_discovery ?runtime_pool ?expected_slots ?expected_ctx
    ?expected_model endpoints () =
  let configured_capacity =
    endpoints
    |> List.fold_left
         (fun acc (endpoint : Discovery_cache.endpoint_info) ->
           acc + Option.value ~default:0 (endpoint_total_slots endpoint))
         0
  in
  let configured_max_concurrent_models = Inference_utils.max_concurrent_models in
  let available_model_permits = Inference_utils.model_permits_available () in
  let runtime_rows, provider_reachable, slot_reachable, actual_slots_total,
      active_slots_now, actual_ctxs, actual_models, chat_completion_compatible =
    List.fold_left
      (fun
        ( rows,
          provider_ok,
          slot_ok,
          slots_acc,
          active_acc,
          ctxs,
          models,
          chat_ok )
        (endpoint : Discovery_cache.endpoint_info)
      ->
        let provider_ok_row = endpoint.healthy in
        let actual_slots = endpoint_total_slots endpoint in
        let slot_ok_row = Option.is_some actual_slots in
        let actual_ctx = endpoint_ctx_size endpoint in
        let actual_model = endpoint_model_id endpoint in
        let current_active = endpoint_busy_slots endpoint in
        let chat_probe_ok, chat_probe_error =
          probe_chat_completion_compatible endpoint
        in
        let row =
          `Assoc
            [
              ( "runtime_id",
                `String
                  (Local_runtime_pool.runtime_id_of_base_url endpoint.url) );
              ("base_url", `String endpoint.url);
              ("provider_base_url", `String endpoint.url);
              ("slot_url", `String endpoint.url);
              ("provider_reachable", `Bool provider_ok_row);
              ( "provider_status_code",
                int_opt_to_json
                  (if provider_ok_row then Some 200 else None) );
              ( "provider_error",
                string_opt_to_json
                  (if provider_ok_row then None
                   else Some "oas discovery marked endpoint unhealthy") );
              ("slot_reachable", `Bool slot_ok_row);
              ("slot_status_code", int_opt_to_json (if slot_ok_row then Some 200 else None));
              ("slot_error", `Null);
              ( "props_status_code",
                int_opt_to_json
                  (if Option.is_some endpoint.props then Some 200 else None) );
              ("props_error", `Null);
              ( "models_status_code",
                int_opt_to_json
                  (if endpoint.models <> [] then Some 200 else None) );
              ("models_error", `Null);
              ("expected_model", string_opt_to_json expected_model);
              ("actual_model_id", string_opt_to_json actual_model);
              ("expected_slots", int_opt_to_json expected_slots);
              ("actual_slots", int_opt_to_json actual_slots);
              ("expected_ctx", int_opt_to_json expected_ctx);
              ("actual_ctx", int_opt_to_json actual_ctx);
              ("active_slots_now", `Int current_active);
              ( "chat_completion_compatible",
                match chat_probe_ok with
                | Some value -> `Bool value
                | None -> `Null );
              ("chat_completion_error", string_opt_to_json chat_probe_error);
            ]
        in
        ( row :: rows,
          provider_ok && provider_ok_row,
          slot_ok && slot_ok_row,
          slots_acc + Option.value ~default:0 actual_slots,
          active_acc + current_active,
          (match actual_ctx with Some value -> value :: ctxs | None -> ctxs),
          (match actual_model with Some value -> value :: models | None -> models),
          (match chat_probe_ok with Some false -> false | _ -> chat_ok) ))
      ([], true, true, 0, 0, [], [], true) endpoints
  in
  let actual_ctx =
    match List.sort_uniq compare actual_ctxs with [ value ] -> Some value | _ -> None
  in
  let actual_model_id =
    match List.sort_uniq String.compare actual_models with
    | [ value ] -> Some value
    | _ -> None
  in
  let runtime_blocker, detail =
    classify_runtime_blocker ~provider_reachable ~slot_reachable
      ~chat_contract_status:(if chat_completion_compatible then "confirmed" else "rejected")
      ~expected_model
      ~actual_model_id ~expected_slots ~actual_slots_total ~expected_ctx
      ~actual_ctx ~chat_completion_compatible
  in
  `Assoc
    [
      ("checked_at", `String (Types.now_iso ()));
      ("runtime_pool", string_opt_to_json runtime_pool);
      ("source", `String "oas_discovery");
      ("cache_age_seconds", `Float (Discovery_cache.cache_age_seconds ()));
      ("provider_base_url", string_opt_to_json (first_endpoint_url endpoints));
      ("slot_url", string_opt_to_json (first_endpoint_url endpoints));
      ("provider_reachable", `Bool provider_reachable);
      ("slot_reachable", `Bool slot_reachable);
      ("chat_completion_compatible", `Bool chat_completion_compatible);
      ("expected_model", string_opt_to_json expected_model);
      ("actual_model_id", string_opt_to_json actual_model_id);
      ("expected_slots", int_opt_to_json expected_slots);
      ("actual_slots", `Int actual_slots_total);
      ("expected_ctx", int_opt_to_json expected_ctx);
      ("actual_ctx", int_opt_to_json actual_ctx);
      ("active_slots_now", `Int active_slots_now);
      ("peak_hot_slots", `Int active_slots_now);
      ("configured_capacity", `Int configured_capacity);
      ("configured_max_concurrent_models", `Int configured_max_concurrent_models);
      ("available_model_permits", `Int available_model_permits);
      ("runtime_blocker", string_opt_to_json runtime_blocker);
      ("detail", string_opt_to_json detail);
      ("pass", `Bool (runtime_blocker = None));
      ("runtimes", `List (List.rev runtime_rows));
    ]

let runtime_verify_json_legacy ?runtime_pool ?expected_slots ?expected_ctx
    ?expected_model () =
  let runtimes = runtime_snapshots_for_pool runtime_pool in
  let has_runtimes = runtimes <> [] in
  let configured_capacity =
    runtimes
    |> List.fold_left
         (fun acc (runtime : Local_runtime_pool.runtime_snapshot) ->
           acc + runtime.max_concurrency)
         0
  in
  let configured_max_concurrent_models = Inference_utils.max_concurrent_models in
  let available_model_permits = Inference_utils.model_permits_available () in
  let runtime_rows, provider_reachable, slot_reachable, actual_slots_total,
      active_slots_now, actual_ctxs, actual_models, chat_contract_statuses =
    List.fold_left
      (fun
        (rows, provider_ok, slot_ok, slots_acc, active_acc, ctxs, models, chat_states)
        (runtime : Local_runtime_pool.runtime_snapshot)
      ->
        let base_url = String.trim runtime.base_url in
        let provider_url = base_url ^ "/health" in
        let slot_url = base_url ^ "/slots" in
        let props_url = base_url ^ "/props" in
        let models_url =
          base_url ^ Masc_network_defaults.openai_models_path
        in
        let provider_status, provider_body, provider_err =
          match http_get_text_with_status provider_url with
          | Ok (status_code, payload) -> (status_code, Some payload, None)
          | Error err -> (None, None, Some err)
        in
        let slot_status, slot_json, slot_err =
          match http_get_json_with_status slot_url with
          | Ok (status_code, payload) -> (status_code, Some payload, None)
          | Error err -> (None, None, Some err)
        in
        let props_status, props_json, props_err =
          match http_get_json_with_status props_url with
          | Ok (status_code, payload) -> (status_code, Some payload, None)
          | Error err -> (None, None, Some err)
        in
        let models_status, models_json, models_err =
          match http_get_json_with_status models_url with
          | Ok (status_code, payload) -> (status_code, Some payload, None)
          | Error err -> (None, None, Some err)
        in
        let provider_ok_row =
          provider_health_reachable ~status:provider_status ~body:provider_body
        in
        let provider_ok' = provider_ok && provider_ok_row in
        let slot_ok_row = slot_status = Some 200 in
        let slot_ok' = slot_ok && slot_ok_row in
        let actual_slots =
          match Option.bind props_json (fun json -> int_member json "total_slots") with
          | Some total -> Some total
          | None ->
              (match slot_json with
               | Some json ->
                   let total = slot_count_of_json json in
                   if total > 0 then Some total else None
               | None -> None)
        in
        let actual_ctx =
          Option.bind props_json (fun json ->
              match Yojson.Safe.Util.member "default_generation_settings" json with
              | `Assoc _ as settings -> int_member settings "n_ctx"
              | _ -> None)
        in
        let actual_model =
          match
            Option.bind models_json (fun json ->
                match Yojson.Safe.Util.member "data" json with
                | `List ((`Assoc _ as first) :: _) -> string_member first "id"
                | `List _ -> None
                | _ -> None)
          with
          | Some model -> Some model
          | None -> runtime.model
        in
        let probe_model =
          match actual_model with
          | Some model_id -> Some model_id
          | None -> (
              match expected_model with
              | Some model_id when String.trim model_id <> "" -> Some (String.trim model_id)
              | _ -> runtime.model)
        in
        let chat_status, chat_body, chat_err =
          match probe_model with
          | None -> (None, None, Some "chat contract probe skipped: no model id available")
          | Some model_id ->
              let url =
                base_url ^ Masc_network_defaults.openai_chat_completions_path
              in
              let body_json = chat_contract_probe_body ~model_id in
              match http_post_json_text_with_status ~timeout_sec:15 ~url ~body_json with
              | Ok (status_code, payload) -> (status_code, Some payload, None)
              | Error err -> (None, None, Some err)
        in
        let chat_status_label =
          chat_contract_status ~status:chat_status ~body:chat_body
        in
        let current_active =
          slot_json |> Option.map active_slots_of_json |> Option.value ~default:0
        in
        let row =
          `Assoc
            [
              ("runtime_id", `String runtime.id);
              ("base_url", `String base_url);
              ("provider_base_url", `String base_url);
              ("slot_url", `String base_url);
              ("provider_reachable", `Bool provider_ok_row);
              ("provider_status_code", int_opt_to_json provider_status);
              ("provider_error", string_opt_to_json provider_err);
              ("slot_reachable", `Bool slot_ok_row);
              ("slot_status_code", int_opt_to_json slot_status);
              ("slot_error", string_opt_to_json slot_err);
              ("props_status_code", int_opt_to_json props_status);
              ("props_error", string_opt_to_json props_err);
              ("models_status_code", int_opt_to_json models_status);
              ("models_error", string_opt_to_json models_err);
              ("chat_status_code", int_opt_to_json chat_status);
              ("chat_contract_status", `String chat_status_label);
              ("chat_contract_reachable", `Bool (chat_contract_reachable ~status:chat_status ~body:chat_body));
              ("chat_error", string_opt_to_json chat_err);
              ("expected_model", string_opt_to_json expected_model);
              ("actual_model_id", string_opt_to_json actual_model);
              ("expected_slots", int_opt_to_json expected_slots);
              ("actual_slots", int_opt_to_json actual_slots);
              ("expected_ctx", int_opt_to_json expected_ctx);
              ("actual_ctx", int_opt_to_json actual_ctx);
              ("active_slots_now", `Int current_active);
            ]
        in
        ( row :: rows,
          provider_ok',
          slot_ok',
          slots_acc + Option.value ~default:0 actual_slots,
          active_acc + current_active,
          (match actual_ctx with Some value -> value :: ctxs | None -> ctxs),
          (match actual_model with Some value -> value :: models | None -> models),
          chat_status_label :: chat_states ))
      ([], true, true, 0, 0, [], [], []) runtimes
  in
  let actual_ctx =
    match List.sort_uniq compare actual_ctxs with [ value ] -> Some value | _ -> None
  in
  let actual_model_id =
    match List.sort_uniq String.compare actual_models with
    | [ value ] -> Some value
    | _ -> None
  in
  let overall_chat_contract_status =
    let states = List.sort_uniq String.compare chat_contract_statuses in
    if not has_runtimes then
      "unknown"
    else if List.mem "rejected" states then
      "rejected"
    else if List.mem "unknown" states then
      "unknown"
    else
      "confirmed"
  in
  let runtime_blocker, detail =
    classify_runtime_blocker
      ~provider_reachable:(provider_reachable && has_runtimes)
      ~slot_reachable:(slot_reachable && has_runtimes) ~expected_model
      ~actual_model_id ~expected_slots ~actual_slots_total ~expected_ctx ~actual_ctx
      ~chat_contract_status:overall_chat_contract_status
      ~chat_completion_compatible:true
  in
  `Assoc
    [
      ("checked_at", `String (Types.now_iso ()));
      ("runtime_pool", string_opt_to_json runtime_pool);
      ("provider_base_url", `String Env_config.Llama.server_url);
      ("slot_url", `String Env_config.Llama.server_url);
      ("provider_reachable", `Bool (provider_reachable && has_runtimes));
      ("slot_reachable", `Bool (slot_reachable && has_runtimes));
      ("chat_completion_compatible", `Bool true);
      ("chat_contract_status", `String overall_chat_contract_status);
      ("chat_contract_reachable", `Bool (String.equal overall_chat_contract_status "confirmed"));
      ("expected_model", string_opt_to_json expected_model);
      ("actual_model_id", string_opt_to_json actual_model_id);
      ("expected_slots", int_opt_to_json expected_slots);
      ("actual_slots", `Int actual_slots_total);
      ("expected_ctx", int_opt_to_json expected_ctx);
      ("actual_ctx", int_opt_to_json actual_ctx);
      ("active_slots_now", `Int active_slots_now);
      ("peak_hot_slots", `Int active_slots_now);
      ("configured_capacity", `Int configured_capacity);
      ("configured_max_concurrent_models", `Int configured_max_concurrent_models);
      ("available_model_permits", `Int available_model_permits);
      ("runtime_blocker", string_opt_to_json runtime_blocker);
      ("detail", string_opt_to_json detail);
      ("pass", `Bool (runtime_blocker = None));
      ("runtimes", `List (List.rev runtime_rows));
    ]

let runtime_verify_json ?runtime_pool ?expected_slots ?expected_ctx ?expected_model () =
  match discovery_endpoints_for_pool runtime_pool with
  | Some endpoints ->
      runtime_verify_json_from_discovery ?runtime_pool ?expected_slots ?expected_ctx
        ?expected_model endpoints ()
  | None ->
      runtime_verify_json_legacy ?runtime_pool ?expected_slots ?expected_ctx
        ?expected_model ()
