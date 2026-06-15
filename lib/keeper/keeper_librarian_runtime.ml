(** Runtime adapter for Memory OS librarian extraction. *)

let librarian_max_tokens = 1024

type complete_fn =
  sw:Eio.Switch.t ->
  net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t ->
  ?clock:float Eio.Time.clock_ty Eio.Resource.t ->
  config:Llm_provider.Provider_config.t ->
  messages:Agent_sdk.Types.message list ->
  unit ->
  (Agent_sdk.Types.api_response, Llm_provider.Http_client.http_error) result

let default_complete ~sw ~net ?clock ~config ~messages () =
  Llm_provider.Complete.complete ~sw ~net ?clock ~config ~messages ()
;;

let enabled () =
  (* Default on: a keeper without conversation ingestion is the pathology
     the Memory OS exists to fix (2026-06-12 diagnosis, issue #20909).
     The env var stays as the kill switch. *)
  Keeper_memory_bank_env.memory_env_bool_logged
    "MASC_KEEPER_MEMORY_OS_LIBRARIAN"
    ~default:true
;;

let max_messages () =
  Keeper_memory_bank_env.memory_env_int_logged
    "MASC_KEEPER_MEMORY_OS_LIBRARIAN_MAX_MESSAGES"
    ~default:24
  |> max 1
;;

let default_timeout_sec () =
  Keeper_memory_bank_env.memory_env_float_logged
    "MASC_KEEPER_MEMORY_OS_LIBRARIAN_TIMEOUT_SEC"
    ~default:Env_config_governance.Inference.timeout_seconds
;;

let runtime_id_for_librarian ~runtime_id =
  match Sys.getenv_opt "MASC_KEEPER_MEMORY_OS_LIBRARIAN_RUNTIME_ID" with
  | Some value ->
    let value = String.trim value in
    if String.equal value "" then runtime_id else value
  | None -> runtime_id
;;

let select_recent_messages ~max_messages messages =
  let max_messages = max 0 max_messages in
  let len = List.length messages in
  let drop_count = max 0 (len - max_messages) in
  let rec drop n xs =
    if n <= 0
    then xs
    else (
      match xs with
      | [] -> []
      | _ :: rest -> drop (n - 1) rest)
  in
  drop drop_count messages
;;

let provider_for_librarian (provider_cfg : Llm_provider.Provider_config.t) =
  let max_tokens =
    match provider_cfg.max_tokens with
    | Some n when n > 0 -> Some (min n librarian_max_tokens)
    | Some _ -> Some librarian_max_tokens
    | None -> Some librarian_max_tokens
  in
  { provider_cfg with
    max_tokens
  ; temperature = Some 0.0
  ; tool_choice = None
  ; disable_parallel_tool_use = true
  ; response_format = Agent_sdk.Types.JsonMode
  ; output_schema = None
  ; enable_thinking = Some false
  ; preserve_thinking = Some false
  ; thinking_budget = None
  ; clear_thinking = Some true
  }
;;

let message role text =
  Agent_sdk.Types.make_message ~role [ Agent_sdk.Types.Text text ]
;;

let render_prompt key variables =
  match Prompt_registry.render_prompt_template key variables with
  | Ok text ->
    let text = String.trim text in
    if String.equal text ""
    then Error (Printf.sprintf "%s rendered empty prompt" key)
    else Ok text
  | Error msg -> Error (Printf.sprintf "%s: %s" key msg)
;;

let messages_for_librarian (inp : Keeper_librarian.input) =
  let input =
    { inp with messages = select_recent_messages ~max_messages:(max_messages ()) inp.messages }
  in
  match render_prompt Keeper_prompt_names.librarian_system [] with
  | Error _ as e -> e
  | Ok system ->
    (match
       render_prompt
         Keeper_prompt_names.librarian_episode_extraction
         (Keeper_librarian.prompt_variables input)
     with
     | Error _ as e -> e
     | Ok user ->
       Ok
         [ message Agent_sdk.Types.System system
         ; message Agent_sdk.Types.User user
         ])
;;

let http_error_message (err : Llm_provider.Http_client.http_error) =
  match err with
  | Llm_provider.Http_client.NetworkError { message; _ } -> message
  | Llm_provider.Http_client.TimeoutError { message; phase } ->
    Printf.sprintf
      "provider timeout: %s: %s"
      (Llm_provider.Http_client.timeout_phase_to_label phase)
      message
  | Llm_provider.Http_client.AcceptRejected { reason } -> reason
  | Llm_provider.Http_client.ProviderTerminal { kind = _; message } ->
    Printf.sprintf "provider terminal: %s" message
  | Llm_provider.Http_client.ProviderFailure { kind; message } ->
    Llm_provider.Http_client.provider_failure_to_string ~kind ~message
  | Llm_provider.Http_client.HttpError { code; body } ->
    Printf.sprintf
      "HTTP %d: %s"
      code
      (if String.length body > 200 then String.sub body 0 200 ^ "..." else body)
;;

let with_timeout ?clock ~timeout_sec f =
  match clock with
  | None -> Some (f ())
  | Some clock ->
    (try Some (Eio.Time.with_timeout_exn clock timeout_sec f) with
     | Eio.Time.Timeout -> None)
;;

let extract_with_provider
    ?(complete = default_complete)
    ?clock
    ?(timeout_sec = Env_config_governance.Inference.timeout_seconds)
    ~sw
    ~net
    ~provider_cfg
    (inp : Keeper_librarian.input)
  =
  match messages_for_librarian inp with
  | Error _ as e -> e
  | Ok messages ->
    let provider_cfg = provider_for_librarian provider_cfg in
    (match
       with_timeout ?clock ~timeout_sec (fun () ->
         complete ~sw ~net ?clock ~config:provider_cfg ~messages ())
     with
     | None -> Error "librarian provider timed out"
     | Some (Error err) -> Error (http_error_message err)
     | Some (Ok response) ->
       let raw = Agent_sdk_response.text_of_response response |> String.trim in
       if String.equal raw ""
       then Error "librarian provider returned empty response"
       else (
         match Keeper_librarian.episode_of_output inp raw with
         | Some episode -> Ok episode
         | None -> Error "librarian provider returned invalid episode JSON"))
;;

let extract_and_append_with_provider
    ?complete
    ?clock
    ?timeout_sec
    ~sw
    ~net
    ~keeper_id
    ~provider_cfg
    inp
  =
  match extract_with_provider ?complete ?clock ?timeout_sec ~sw ~net ~provider_cfg inp with
  | Error _ as e -> e
  | Ok episode ->
    Keeper_memory_os_io.append_episode_bundle ~keeper_id episode;
    (* RFC-0239 Q4 (supersedes RFC-0238 Capped_by_score): bound the append-only
       fact store after each librarian write. cap_facts' hysteresis keeps this
       off the hot path (a rewrite only fires once the store overflows the
       trigger). A retention failure must not fail the already-succeeded
       append, so it is logged and swallowed. *)
    (try
       let window = Keeper_memory_os_io.fact_recall_window in
       ignore
         (Keeper_memory_os_io.cap_facts
            ~keeper_id
            ~keep:window
            ~trigger:(window + (window / 2))
            ~rank:
              (Keeper_memory_os_policy.score_fact
                 ~now:episode.Keeper_memory_os_types.created_at)
          : int)
     with
     | Eio.Cancel.Cancelled _ as e -> raise e
     | exn ->
       Log.Keeper.warn
         "memory os retention sweep failed keeper=%s: %s"
         keeper_id
         (Printexc.to_string exn));
    Ok episode
;;

let provider_for_runtime ~runtime_id =
  match Runtime.get_runtime_by_id runtime_id with
  | Some rt -> Ok rt.Runtime.provider_config
  | None ->
    (match Runtime.get_default_runtime () with
     | Some rt -> Ok rt.Runtime.provider_config
     | None -> Error "no runtime configured for librarian extraction")
;;

let run_best_effort ?complete ?timeout_sec ~runtime_id ~keeper_id inp =
  if enabled ()
  then (
    try
      match Eio_context.get_switch_opt (), Eio_context.get_net_opt () with
      | Some sw, Some net ->
        let runtime_id = runtime_id_for_librarian ~runtime_id in
        (match provider_for_runtime ~runtime_id with
         | Error err ->
           Log.Keeper.warn ~keeper_name:keeper_id
             "memory os librarian skipped runtime=%s: %s"
             runtime_id
             err
         | Ok provider_cfg ->
           if not (Keeper_memory_llm_summary.is_direct_completion_provider provider_cfg)
           then
             Log.Keeper.warn ~keeper_name:keeper_id
               "memory os librarian skipped runtime=%s provider=%s: provider does not support direct completion"
               runtime_id
               provider_cfg.Llm_provider.Provider_config.model_id
           else (
             let clock = Eio_context.get_clock_opt () in
             let timeout_sec =
               Option.value timeout_sec ~default:(default_timeout_sec ())
             in
             match
               extract_and_append_with_provider
                 ?complete
                 ?clock
                 ~timeout_sec
                 ~sw
                 ~net
                 ~keeper_id
                 ~provider_cfg
                 inp
             with
             | Ok episode ->
               Log.Keeper.info ~keeper_name:keeper_id
                 "memory os librarian wrote episode trace_id=%s generation=%d claims=%d"
                 episode.Keeper_memory_os_types.trace_id
                 episode.generation
                 (List.length episode.claims)
             | Error err ->
               Otel_metric_store.inc_counter
                 Keeper_metrics.(to_string EpisodeCreateFailures)
                 ~labels:[ "keeper", keeper_id; "site", "memory_os_librarian" ]
                 ();
               Log.Keeper.warn ~keeper_name:keeper_id
                 "memory os librarian failed runtime=%s: %s"
                 runtime_id
                 err))
      | _ ->
        Log.Keeper.warn ~keeper_name:keeper_id
          "memory os librarian skipped: Eio context unavailable runtime=%s"
          runtime_id
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | exn ->
      Otel_metric_store.inc_counter
        Keeper_metrics.(to_string EpisodeCreateFailures)
        ~labels:[ "keeper", keeper_id; "site", "memory_os_librarian" ]
        ();
      Log.Keeper.warn ~keeper_name:keeper_id
        "memory os librarian failed runtime=%s: %s"
        runtime_id
        (Printexc.to_string exn))
;;
