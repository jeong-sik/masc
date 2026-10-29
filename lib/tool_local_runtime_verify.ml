(** Tool_local_runtime_verify -- runtime contract verification. *)



(* http_error_message moved to Provider_http_error.to_message (SSOT,
   2026-06-24): four byte-for-output-identical copies unified. *)
let safe_discovery_endpoints () =
  try Some (Discovery_cache.get_cached_or_refresh ())
  with
  | Stdlib.Effect.Unhandled _ -> None
  | Eio.Cancel.Cancelled _ as cancelled ->
    Printexc.raise_with_backtrace cancelled (Printexc.get_raw_backtrace ())
  | _ -> None

let select_endpoint_urls_for_pool ?runtime_pool endpoint_urls =
  match Option.bind runtime_pool String_util.trim_nonempty with
  | None -> if endpoint_urls = [] then None else Some endpoint_urls
  | Some pool
    when String.equal pool Local_runtime_pool.default_pool_label
         || String.equal pool "default" ->
      if endpoint_urls = [] then None else Some endpoint_urls
  | Some pool ->
      let matches url =
        String.equal pool url
        || String.equal pool (Local_runtime_pool.runtime_id_of_base_url url)
      in
      (match List.filter matches endpoint_urls with
       | [] -> None
      | selected -> Some selected)
;;

module For_testing = struct
  let select_endpoint_urls_for_pool = select_endpoint_urls_for_pool
end

let discovery_endpoints_for_pool runtime_pool =
  match safe_discovery_endpoints () with
  | None -> None
  | Some [] -> None
  | Some endpoints ->
      let endpoint_urls =
        List.map (fun (endpoint : Discovery_cache.endpoint_info) -> endpoint.url) endpoints
      in
      Option.map
        (fun selected_urls ->
          List.filter
            (fun (endpoint : Discovery_cache.endpoint_info) ->
              List.mem endpoint.url selected_urls)
            endpoints)
        (select_endpoint_urls_for_pool ?runtime_pool endpoint_urls)

let endpoint_model_id (endpoint : Discovery_cache.endpoint_info) =
  match endpoint.models with
  | model :: _ -> String_util.trim_nonempty model.id
  | [] -> (
      match endpoint.props with
      | Some props -> String_util.trim_nonempty props.model
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

let error_message_of_http_error = Provider_http_error.to_message

(** Probe whether an endpoint supports the OpenAI chat-completions protocol.
    This is a protocol-level probe; it explicitly depends on AGENT_CORE
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
      let messages : Llm_provider.Types.message list = [ Llm_provider.Types.user_msg "hi" ] in
      let run_completion () =
        (Llm_provider.Complete.complete ~sw:env.sw ~net:env.net
          ~config:provider_config ~messages ()).Llm_provider.Completion_outcome.result
      in
      (* A completion that arrived as the window closed is the completion. *)
      let outcome =
        Watched_work.run
          ~watcher:(fun () ->
            Eio.Time.sleep env.clock (Stdlib.Float.of_int timeout_sec);
            Error "timeout")
          (fun () -> Ok (run_completion ()))
      in
      match outcome with
      | Error message -> (Some false, Some message)
      | Ok (Ok _response) -> (Some true, None)
      | Ok (Error http_error) ->
          (Some false, Some (error_message_of_http_error http_error))

(* Why the local pool fails verification. A case carries the values its
   detail names, so the label and the sentence come from one value. *)
type runtime_blocker =
  | Agent_core_discovery_unavailable
  | Provider_unreachable
  | Provider_protocol_incompatible
  | Provider_model_mismatch of { expected : string; actual : string option }
  | Slot_count_insufficient of { expected : int; actual : int }
  | Ctx_mismatch of { expected : int; actual : int option }

let runtime_blocker_label = function
  | Agent_core_discovery_unavailable -> "agent_core_discovery_unavailable"
  | Provider_unreachable -> "provider_unreachable"
  | Provider_protocol_incompatible -> "provider_protocol_incompatible"
  | Provider_model_mismatch _ -> "provider_model_mismatch"
  | Slot_count_insufficient _ -> "slot_count_insufficient"
  | Ctx_mismatch _ -> "ctx_mismatch"

let runtime_blocker_detail = function
  | Agent_core_discovery_unavailable ->
      "No typed local OpenAI-compatible discovery endpoint is registered. This diagnostic does not assess or block official-client, CLI, or remote Keeper provider lanes."
  | Provider_unreachable -> "llama runtime health or slots endpoint failed"
  | Provider_protocol_incompatible ->
      "one or more endpoints failed the AGENT_CORE chat-completions probe"
  | Provider_model_mismatch { expected; actual } ->
      Printf.sprintf "expected model %s, got %s" expected
        (Option.value ~default:"<mixed-or-missing>" actual)
  | Slot_count_insufficient { expected; actual } ->
      Printf.sprintf "expected at least %d slots, got %d" expected actual
  | Ctx_mismatch { expected; actual } ->
      Printf.sprintf "expected ctx %d, got %s" expected
        (match actual with Some value -> Int.to_string value | None -> "<mixed-or-missing>")

let classify_runtime_blocker ~provider_reachable ~slot_reachable
    ~chat_completion_compatible ~expected_model ~actual_model_id ~expected_slots
    ~actual_slots_total ~expected_ctx ~actual_ctx =
  if not provider_reachable || not slot_reachable then Some Provider_unreachable
  else if not chat_completion_compatible then Some Provider_protocol_incompatible
  else
    match expected_model, actual_model_id with
    | Some expected, Some actual when not (String.equal expected actual) ->
        Some (Provider_model_mismatch { expected; actual = Some actual })
    | Some expected, None -> Some (Provider_model_mismatch { expected; actual = None })
    | Some _, Some _ | None, _ -> (
        match expected_slots with
        | Some expected when actual_slots_total < expected ->
            Some (Slot_count_insufficient { expected; actual = actual_slots_total })
        | Some _ | None -> (
            match expected_ctx, actual_ctx with
            | Some expected, Some actual when expected <> actual ->
                Some (Ctx_mismatch { expected; actual = Some actual })
            | Some expected, None -> Some (Ctx_mismatch { expected; actual = None })
            | Some _, Some _ | None, _ -> None))

(* What one verification observed. The discovered and the undiscovered case
   both fill it and [verify_result_json] writes the keys once, so the two
   cases can differ only in values. *)
type verify_result = {
  provider_reachable : bool;
  slot_reachable : bool;
  chat_completion_compatible : bool option;
  actual_model_id : string option;
  actual_slots : int;
  actual_ctx : int option;
  active_slots_now : int;
  configured_capacity : int;
  runtime_blocker : runtime_blocker option;
  runtimes : Yojson.Safe.t list;
}

let verify_result_json ?runtime_pool ?expected_slots ?expected_ctx ?expected_model
    (result : verify_result) =
  `Assoc
    [
      ("checked_at", `String (Masc_domain.now_iso ()));
      ("runtime_pool", Json_util.string_opt_to_json runtime_pool);
      ("source", `String "agent_core_discovery");
      ("verification_scope", `String "local_openai_compatible_runtime_pool");
      ("blocks_keeper_turns", `Bool false);
      ("fleet_provider_health", `String "not_assessed");
      ("cache_age_seconds", `Float (Discovery_cache.cache_age_seconds ()));
      ("provider_reachable", `Bool result.provider_reachable);
      ("slot_reachable", `Bool result.slot_reachable);
      ( "chat_completion_compatible",
        Json_util.bool_opt_to_json result.chat_completion_compatible );
      ("expected_model", Json_util.string_opt_to_json expected_model);
      ("actual_model_id", Json_util.string_opt_to_json result.actual_model_id);
      ("expected_slots", Json_util.int_opt_to_json expected_slots);
      ("actual_slots", `Int result.actual_slots);
      ("expected_ctx", Json_util.int_opt_to_json expected_ctx);
      ("actual_ctx", Json_util.int_opt_to_json result.actual_ctx);
      ("active_slots_now", `Int result.active_slots_now);
      ("configured_capacity", `Int result.configured_capacity);
      ("configured_max_concurrent_models", `Int Inference_utils.max_concurrent_models);
      ( "runtime_blocker",
        Json_util.string_opt_to_json
          (Option.map runtime_blocker_label result.runtime_blocker) );
      ( "detail",
        Json_util.string_opt_to_json
          (Option.map runtime_blocker_detail result.runtime_blocker) );
      ("pass", `Bool (Option.is_none result.runtime_blocker));
      ("runtimes", `List result.runtimes);
    ]

let verify_discovered ?expected_slots ?expected_ctx ?expected_model endpoints =
  let configured_capacity =
    endpoints
    |> List.fold_left
         (fun acc (endpoint : Discovery_cache.endpoint_info) ->
           acc + Option.value ~default:0 (endpoint_total_slots endpoint))
         0
  in
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
              ("provider_reachable", `Bool provider_ok_row);
              ( "provider_status_code",
                Json_util.int_opt_to_json
                  (if provider_ok_row then Some 200 else None) );
              ( "provider_error",
                Json_util.string_opt_to_json
                  (if provider_ok_row then None
                   else Some "agent_core discovery marked endpoint unhealthy") );
              ("slot_reachable", `Bool slot_ok_row);
              ("slot_status_code", Json_util.int_opt_to_json (if slot_ok_row then Some 200 else None));
              ( "props_status_code",
                Json_util.int_opt_to_json
                  (if Option.is_some endpoint.props then Some 200 else None) );
              ( "models_status_code",
                Json_util.int_opt_to_json
                  (if Stdlib.List.length endpoint.models > 0 then Some 200 else None) );
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
  {
    provider_reachable;
    slot_reachable;
    chat_completion_compatible = Some chat_completion_compatible;
    actual_model_id;
    actual_slots = actual_slots_total;
    actual_ctx;
    active_slots_now;
    configured_capacity;
    runtime_blocker =
      classify_runtime_blocker ~provider_reachable ~slot_reachable
        ~chat_completion_compatible ~expected_model ~actual_model_id ~expected_slots
        ~actual_slots_total ~expected_ctx ~actual_ctx;
    runtimes = List.rev runtime_rows;
  }

let undiscovered_result =
  {
    provider_reachable = false;
    slot_reachable = false;
    chat_completion_compatible = None;
    actual_model_id = None;
    actual_slots = 0;
    actual_ctx = None;
    active_slots_now = 0;
    configured_capacity = 0;
    runtime_blocker = Some Agent_core_discovery_unavailable;
    runtimes = [];
  }

let runtime_verify_json ?runtime_pool ?expected_slots ?expected_ctx ?expected_model () =
  let result =
    match discovery_endpoints_for_pool runtime_pool with
    | Some endpoints ->
        verify_discovered ?expected_slots ?expected_ctx ?expected_model endpoints
    | None -> undiscovered_result
  in
  verify_result_json ?runtime_pool ?expected_slots ?expected_ctx ?expected_model result
