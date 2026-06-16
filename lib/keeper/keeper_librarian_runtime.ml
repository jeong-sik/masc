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

let provider_slot_busy = "librarian provider slot busy"

let provider_slot = Eio.Semaphore.make 1

let provider_slot_wait_sec () =
  Keeper_memory_bank_env.memory_env_float_logged
    "MASC_KEEPER_MEMORY_OS_LIBRARIAN_SLOT_WAIT_SEC"
    ~default:0.25
  |> max 0.001
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

(* Bounded parse-retry for librarian extraction (typed-harness contract C6).

   The librarian asks a provider for a JSON episode. When the provider returns a
   non-empty response that does not parse into the typed episode
   ([Keeper_librarian.episode_of_output] -> None), the prior behavior dropped the
   episode and only incremented [EpisodeCreateFailures]: a counter makes the loss
   visible but does not recover it (the telemetry-as-fix shape CLAUDE.md rejects).
   Instead, re-ask the provider with a corrective nudge up to
   [librarian_max_parse_retries] times before giving up. Transport failures
   (timeout / HTTP error) are NOT retried here — they are a provider-availability
   problem, not the model-output problem this bound addresses. *)
let librarian_max_parse_retries = 2

let parse_retry_nudge =
  "Your previous response could not be parsed as the required JSON episode \
   object. Respond with ONLY a single JSON object — no markdown fences, no \
   prose — containing: episode_summary (string), claims (array of objects with \
   claim, confidence, category, source_turn), open_items, constraints, \
   preserved_tool_refs."

type attempt_outcome =
  | Parsed of Keeper_memory_os_types.episode
  | Unparseable of string
    (* provider returned output we could not parse into an episode — retryable *)
  | Transport_failed of string (* timeout / HTTP error — not retried here *)

let rec run_with_parse_retries ~max_retries ~attempt messages =
  match attempt messages with
  | Parsed episode -> Ok episode
  | Transport_failed msg -> Error msg
  | Unparseable msg ->
    if max_retries <= 0
    then Error msg
    else
      run_with_parse_retries
        ~max_retries:(max_retries - 1)
        ~attempt
        (messages @ [ message Agent_sdk.Types.User parse_retry_nudge ])
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

let with_provider_slot ?clock f =
  match
    with_timeout ?clock ~timeout_sec:(provider_slot_wait_sec ()) (fun () ->
      Eio.Semaphore.acquire provider_slot)
  with
  | None -> Error provider_slot_busy
  | Some () ->
    (* fun-protect-finally-ok: [Eio.Semaphore.release] only returns the
       provider slot; it does not wait, acquire, or perform I/O. *)
    Fun.protect ~finally:(fun () -> Eio.Semaphore.release provider_slot) f
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
    with_provider_slot ?clock (fun () ->
      let attempt messages =
        match
          with_timeout ?clock ~timeout_sec (fun () ->
            complete ~sw ~net ?clock ~config:provider_cfg ~messages ())
        with
        | None -> Transport_failed "librarian provider timed out"
        | Some (Error err) -> Transport_failed (http_error_message err)
        | Some (Ok response) ->
          let raw = Agent_sdk_response.text_of_response response |> String.trim in
          if String.equal raw ""
          then Unparseable "librarian provider returned empty response"
          else (
            match Keeper_librarian.episode_of_output inp raw with
            | Some episode -> Parsed episode
            | None -> Unparseable "librarian provider returned invalid episode JSON")
      in
      run_with_parse_retries
        ~max_retries:librarian_max_parse_retries
        ~attempt
        messages)
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
    let now = episode.Keeper_memory_os_types.created_at in
    (* RFC-0243: persist the episode log (unique episode file + event), then
       UPSERT its claims into the fact store instead of blind-appending. A claim
       re-extracted across turns is folded into the existing row
       (Keeper_memory_os_policy.reobserve_fact: confidence blends, access_count
       and last_verified_at refresh) rather than accumulating as an immortal
       frozen-confidence duplicate — the accuracy-inversion root fix. The same
       call applies the RFC-0239 Q4 retention cap in one atomic rewrite. The
       episode log already retains the raw claims, but a fact-merge failure is
       still reported to the caller so the turn is not counted as a clean
       librarian write. *)
    Keeper_memory_os_io.append_episode ~keeper_id episode;
    Keeper_memory_os_io.append_event ~keeper_id episode;
    (match
       try
         let window = Keeper_memory_os_io.fact_recall_window in
         let (_ : Keeper_memory_os_io.fact_merge_stats) =
           Keeper_memory_os_io.merge_and_cap_facts
             ~keeper_id
             ~merge:(Keeper_memory_os_policy.reobserve_fact ~now)
             ~incoming:episode.Keeper_memory_os_types.claims
             ~keep:window
             ~trigger:(window + (window / 2))
             ~rank:(Keeper_memory_os_policy.score_fact ~now)
         in
         Ok ()
       with
       | Eio.Cancel.Cancelled _ as e -> raise e
       | exn ->
         let message = Printexc.to_string exn in
         Log.Keeper.warn "memory os fact upsert failed keeper=%s: %s" keeper_id message;
         Error message
     with
     | Error message -> Error ("memory os fact upsert failed: " ^ message)
     | Ok () ->
       (* RFC-0246 §2.7: record the episode's co-occurrence associations. This
          is enrichment for associative recall, not part of the fact contract,
          so a failure here is logged and swallowed (Cancelled re-raised) after
          the fact write has succeeded. *)
       (try
          Keeper_memory_os_io.append_edges
            ~keeper_id
            (Keeper_memory_os_edges.co_occurrence_edges episode)
        with
        | Eio.Cancel.Cancelled _ as e -> raise e
        | exn ->
          Log.Keeper.warn
            "memory os edge write failed keeper=%s: %s"
            keeper_id
            (Printexc.to_string exn));
       Ok episode)
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
             | Error err when String.equal err provider_slot_busy ->
               Log.Keeper.info ~keeper_name:keeper_id
                 "memory os librarian skipped runtime=%s: provider slot busy"
                 runtime_id
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
