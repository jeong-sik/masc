module Format = Stdlib.Format
module Map = Stdlib.Map
module Set = Stdlib.Set
module Queue = Stdlib.Queue
module Hashtbl = Stdlib.Hashtbl
module Mutex = Stdlib.Mutex
module Option = Stdlib.Option
module Result = Stdlib.Result
module Sys = Stdlib.Sys
module Filename = Stdlib.Filename
module List = Stdlib.List
module Array = Stdlib.Array
module String = Stdlib.String
module Char = Stdlib.Char
module Int = Stdlib.Int
module Float = Stdlib.Float

(** Tool_local_runtime_verify -- runtime contract verification. *)

module Oas_types = Agent_sdk.Types


(* http_error_message moved to Provider_http_error.to_message (SSOT,
   2026-06-24): four byte-for-output-identical copies unified. *)
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
        match Option.bind runtime_pool String_util.trim_to_option with
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
      Some (if Stdlib.List.length filtered = 0 then endpoints else filtered)

let endpoint_model_id (endpoint : Discovery_cache.endpoint_info) =
  match endpoint.models with
  | model :: _ -> String_util.trim_to_option model.id
  | [] -> (
      match endpoint.props with
      | Some props -> String_util.trim_to_option props.model
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

let error_message_of_http_error = Provider_http_error.to_message

(** Probe whether an endpoint supports the OpenAI chat-completions protocol.
    This is a protocol-level probe; it explicitly depends on OAS
    [Llm_provider.Complete.complete] because the goal is to verify the
    endpoint's wire protocol, not to run a full agent turn. *)
let probe_chat_completion_compatible
    ?(timeout_sec = 5)
    (endpoint : Discovery_cache.endpoint_info) =
  match Masc_eio_env.get_opt (), endpoint_model_id endpoint with
  | None, _ ->
      let message =
        "Eio environment not initialized; refusing chat-completions probe \
         without timeout enforcement"
      in
      Log.Runtime_verify.error
        "chat-completions probe failed caller_surface=runtime_verify endpoint=%s reason=eio_env_missing"
        endpoint.url;
      (Some false, Some message)
  | _, None ->
      Log.Runtime_verify.warn "chat-completions probe skipped caller_surface=runtime_verify endpoint=%s reason=missing_model_id"
        endpoint.url;
      (None, Some "missing model id")
  | Some env, Some model_id ->
      Log.Runtime_verify.info "chat-completions probe caller_surface=runtime_verify endpoint=%s model_id=%s timeout_sec=%d"
        endpoint.url model_id timeout_sec;
      let provider_config =
        Llm_provider.Provider_config.make
          ~kind:Llm_provider.Provider_config.OpenAI_compat
          ~model_id ~base_url:endpoint.url
          ~request_path:Masc_network_defaults.openai_chat_completions_path
          ~max_tokens:1 ()
      in
      let messages : Oas_types.message list = [ Oas_types.user_msg "hi" ] in
      let run_completion () =
        Llm_provider.Complete.complete ~sw:env.sw ~net:env.net
          ~config:provider_config ~messages ()
      in
      let outcome =
        try Ok (Eio.Time.with_timeout_exn env.clock (Stdlib.Float.of_int timeout_sec) run_completion)
        with Eio.Time.Timeout -> Error "timeout"
      in
      match outcome with
      | Error message -> (Some false, Some message)
      | Ok (Ok _response) -> (Some true, None)
      | Ok (Error http_error) ->
          (Some false, Some (error_message_of_http_error http_error))

let provider_health_reachable ~status =
  Option.equal Int.equal status (Some 200)

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
           (match expected_ctx with Some value -> Int.to_string value | None -> "<none>")
           (match actual_ctx with Some value -> Int.to_string value | None -> "<mixed-or-missing>")) )
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
                Json_util.int_opt_to_json
                  (if provider_ok_row then Some 200 else None) );
              ( "provider_error",
                Json_util.string_opt_to_json
                  (if provider_ok_row then None
                   else Some "oas discovery marked endpoint unhealthy") );
              ("slot_reachable", `Bool slot_ok_row);
              ("slot_status_code", Json_util.int_opt_to_json (if slot_ok_row then Some 200 else None));
              ("slot_error", `Null);
              ( "props_status_code",
                Json_util.int_opt_to_json
                  (if Option.is_some endpoint.props then Some 200 else None) );
              ("props_error", `Null);
              ( "models_status_code",
                Json_util.int_opt_to_json
                  (if Stdlib.List.length endpoint.models > 0 then Some 200 else None) );
              ("models_error", `Null);
              ("expected_model", Json_util.string_opt_to_json expected_model);
              ("actual_model_id", Json_util.string_opt_to_json actual_model);
              ("expected_slots", Json_util.int_opt_to_json expected_slots);
              ("actual_slots", Json_util.int_opt_to_json actual_slots);
              ("expected_ctx", Json_util.int_opt_to_json expected_ctx);
              ("actual_ctx", Json_util.int_opt_to_json actual_ctx);
              ("active_slots_now", `Int current_active);
              ( "chat_completion_compatible",
                match chat_probe_ok with
                | Some value -> `Bool value
                | None -> `Null );
              ("chat_completion_error", Json_util.string_opt_to_json chat_probe_error);
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
      ("checked_at", `String (Masc_domain.now_iso ()));
      ("runtime_pool", Json_util.string_opt_to_json runtime_pool);
      ("source", `String "oas_discovery");
      ("cache_age_seconds", `Float (Discovery_cache.cache_age_seconds ()));
      ("provider_base_url", Json_util.string_opt_to_json (first_endpoint_url endpoints));
      ("slot_url", Json_util.string_opt_to_json (first_endpoint_url endpoints));
      ("provider_reachable", `Bool provider_reachable);
      ("slot_reachable", `Bool slot_reachable);
      ("chat_completion_compatible", `Bool chat_completion_compatible);
      ("expected_model", Json_util.string_opt_to_json expected_model);
      ("actual_model_id", Json_util.string_opt_to_json actual_model_id);
      ("expected_slots", Json_util.int_opt_to_json expected_slots);
      ("actual_slots", `Int actual_slots_total);
      ("expected_ctx", Json_util.int_opt_to_json expected_ctx);
      ("actual_ctx", Json_util.int_opt_to_json actual_ctx);
      ("active_slots_now", `Int active_slots_now);
      ("peak_hot_slots", `Int active_slots_now);
      ("configured_capacity", `Int configured_capacity);
      ("configured_max_concurrent_models", `Int configured_max_concurrent_models);
      ("runtime_blocker", Json_util.string_opt_to_json runtime_blocker);
      ("detail", Json_util.string_opt_to_json detail);
      ("pass", `Bool (Option.is_none runtime_blocker));
      ("runtimes", `List (List.rev runtime_rows));
    ]

let runtime_verify_json_missing_discovery ?runtime_pool ?expected_slots
    ?expected_ctx ?expected_model () =
  `Assoc
    [
      ("checked_at", `String (Masc_domain.now_iso ()));
      ("runtime_pool", Json_util.string_opt_to_json runtime_pool);
      ("source", `String "oas_discovery");
      ("cache_age_seconds", `Float (Discovery_cache.cache_age_seconds ()));
      ("provider_base_url", `Null);
      ("slot_url", `Null);
      ("provider_reachable", `Bool false);
      ("slot_reachable", `Bool false);
      ("chat_completion_compatible", `Null);
      ("expected_model", Json_util.string_opt_to_json expected_model);
      ("actual_model_id", `Null);
      ("expected_slots", Json_util.int_opt_to_json expected_slots);
      ("actual_slots", `Int 0);
      ("expected_ctx", Json_util.int_opt_to_json expected_ctx);
      ("actual_ctx", `Null);
      ("active_slots_now", `Int 0);
      ("peak_hot_slots", `Int 0);
      ("configured_capacity", `Int 0);
      ("configured_max_concurrent_models", `Int Inference_utils.max_concurrent_models);
      ("runtime_blocker", `String "oas_discovery_unavailable");
      ("detail", `String "runtime verification requires OAS discovery endpoints");
      ("pass", `Bool false);
      ("runtimes", `List []);
    ]

let runtime_verify_json ?runtime_pool ?expected_slots ?expected_ctx ?expected_model () =
  match discovery_endpoints_for_pool runtime_pool with
  | Some endpoints ->
      runtime_verify_json_from_discovery ?runtime_pool ?expected_slots ?expected_ctx
        ?expected_model endpoints ()
  | None ->
      runtime_verify_json_missing_discovery ?runtime_pool ?expected_slots ?expected_ctx
        ?expected_model ()
