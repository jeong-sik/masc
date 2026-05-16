(** LLM-backed keeper memory-bank consolidation.

    This module is intentionally a narrow MASC-side adapter.  OAS already
    exposes the low-level completion API; keeper memory-bank compaction owns
    the domain prompt, opt-in gate, provider choice, and fallback semantics. *)

let summary_max_tokens = 512

(* Observability for [summarize_with_provider] outcomes and
   [summarize_with_providers] chain exhaustion.  Existing warn lines
   are preserved; this adds a typed counter so operators can read
   success rate per provider, and an explicit warn when the cascade
   yields no summary at all (previously silent).  Closes the
   silent-failure gap flagged in
   .tmp/memory-compacting-analysis.html (LLM-summary triple-silent
   fallback chain). *)
let () =
  Prometheus.register_counter
    ~name:Keeper_metrics.metric_keeper_memory_llm_summary_outcomes
    ~help:
      "Total [summarize_with_provider] attempts classified by label \
       [outcome] (ok_summary | timed_out | http_error | empty_response). \
       Labels: [outcome], [provider] (model_id), [cascade]."
    ();
  Prometheus.register_counter
    ~name:Keeper_metrics.metric_keeper_memory_llm_summary_chain_exhausted
    ~help:
      "Total [summarize_with_providers] runs where every provider \
       returned a non-Ok outcome and the consolidation pass received \
       no summary.  Label [cascade] names the cascade.  Rising rate \
       means consolidation is silently skipping the LLM summary."
    ()
;;

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

let is_direct_completion_provider
    (provider_cfg : Llm_provider.Provider_config.t) : bool =
  match provider_cfg.kind with
  | Claude_code | Gemini_cli | Kimi_cli | Codex_cli -> false
  | Anthropic | Kimi | OpenAI_compat | Ollama | Gemini | Glm | DashScope -> true

let provider_for_summary (provider_cfg : Llm_provider.Provider_config.t) =
  let max_tokens =
    match provider_cfg.max_tokens with
    | Some n when n > 0 -> Some (min n summary_max_tokens)
    | _ -> Some summary_max_tokens
  in
  { provider_cfg with
    max_tokens;
    temperature = Some 0.0;
    tool_choice = None;
    disable_parallel_tool_use = true;
    response_format = Agent_sdk.Types.Off;
    output_schema = None;
  }

let text_block text : Agent_sdk.Types.content_block =
  Agent_sdk.Types.Text text

let message role text : Agent_sdk.Types.message =
  { role; content = [ text_block text ]; name = None; tool_call_id = None; metadata = [] }

let bounded_notes_text texts =
  texts
  |> List.mapi (fun idx text -> Printf.sprintf "%d. %s" (idx + 1) (String.trim text))
  |> String.concat "\n"
  |> String_util.utf8_safe ~max_bytes:6000 ~suffix:"..."
  |> String_util.to_string

let messages_for_summary ~trace_id ~texts =
  let system =
    "You summarize keeper progress notes into one durable memory-bank entry. \
     Preserve concrete code paths, commands, decisions, blockers, and next \
     steps. Do not invent facts. Do not include [STATE] blocks or markdown \
     fences. Output only the summary text."
  in
  let user =
    Printf.sprintf
      "trace_id: %s\n\
       notes:\n\
       %s\n\n\
       Write a concise durable summary for future keeper code work."
      trace_id
      (bounded_notes_text texts)
  in
  [ message Agent_sdk.Types.System system; message Agent_sdk.Types.User user ]

let response_text (response : Agent_sdk.Types.api_response) : string option =
  let text =
    response.content
    |> List.filter_map (function Agent_sdk.Types.Text s -> Some s | _ -> None)
    |> List.map String.trim
    |> List.filter (fun s -> s <> "")
    |> String.concat "\n"
    |> String.trim
  in
  if text = "" then None else Some text

let with_timeout ?clock ~timeout_sec f =
  match clock with
  | None -> Some (f ())
  | Some clock ->
      try Some (Eio.Time.with_timeout_exn clock timeout_sec f)
      with Eio.Time.Timeout -> None

let record_summary_outcome
    ~(cascade_name : string)
    ~(provider_cfg : Llm_provider.Provider_config.t)
    ~(outcome : Keeper_memory_llm_summary_outcome.t) =
  Prometheus.inc_counter
    Keeper_metrics.metric_keeper_memory_llm_summary_outcomes
    ~labels:
      [ ("outcome", Keeper_memory_llm_summary_outcome.to_label outcome)
      ; ("provider", provider_cfg.Llm_provider.Provider_config.model_id)
      ; ("cascade", cascade_name)
      ]
    ()

let summarize_with_provider
    ?(complete : complete_fn = default_complete)
    ?clock
    ?(timeout_sec = Env_config_governance.Inference.timeout_seconds)
    ?(cascade_name = "")
    ~sw
    ~net
    ~(provider_cfg : Llm_provider.Provider_config.t)
    ~trace_id
    ~texts
    () : string option =
  let provider_cfg = provider_for_summary provider_cfg in
  let messages = messages_for_summary ~trace_id ~texts in
  let result, outcome =
    match
      with_timeout ?clock ~timeout_sec (fun () ->
        complete ~sw ~net ?clock ~config:provider_cfg ~messages ())
    with
    | None ->
        Log.Keeper.warn
          "memory LLM summary timed out trace_id=%s provider=%s timeout_sec=%.1f"
          trace_id provider_cfg.model_id timeout_sec;
        None, Keeper_memory_llm_summary_outcome.Timed_out
    | Some (Ok response) ->
        (match response_text response with
         | Some _ as summary ->
             summary, Keeper_memory_llm_summary_outcome.Ok_summary
         | None ->
             Log.Keeper.warn
               "memory LLM summary empty trace_id=%s provider=%s"
               trace_id provider_cfg.model_id;
             None, Keeper_memory_llm_summary_outcome.Empty_response)
    | Some (Error err) ->
        Log.Keeper.warn
          "memory LLM summary failed trace_id=%s provider=%s: %s"
          trace_id provider_cfg.model_id (Oas_compat.Http_client.error_message err);
        None, Keeper_memory_llm_summary_outcome.Http_error
  in
  record_summary_outcome ~cascade_name ~provider_cfg ~outcome;
  result

let summarize_with_providers
    ?complete
    ?clock
    ?timeout_sec
    ?(cascade_name = "")
    ~sw
    ~net
    ~providers
    ~trace_id
    ~texts
    () =
  let rec go = function
    | [] -> None
    | provider_cfg :: rest -> (
        match
          summarize_with_provider ?complete ?clock ?timeout_sec ~cascade_name
            ~sw ~net ~provider_cfg ~trace_id ~texts ()
        with
        | Some summary -> Some summary
        | None -> go rest)
  in
  match go providers with
  | Some _ as summary -> summary
  | None ->
      Prometheus.inc_counter
        Keeper_metrics.metric_keeper_memory_llm_summary_chain_exhausted
        ~labels:[("cascade", cascade_name)]
        ();
      Log.Keeper.warn
        "memory LLM summary chain exhausted trace_id=%s cascade=%s \
         providers_attempted=%d — consolidation skipped LLM summary"
        trace_id
        cascade_name
        (List.length providers);
      None

let make
    ?complete
    ?provider_filter
    ?timeout_sec
    ~(cascade_name : string)
    ~(keeper_name : string)
    () : Keeper_memory_bank.memory_consolidation_summarizer option =
  if not (Keeper_memory_bank.memory_llm_summary_enabled ()) then None
  else
    match Eio_context.get_switch_opt (), Eio_context.get_net_opt () with
    | Some sw, Some net ->
        let clock = Eio_context.get_clock_opt () in
        (match
           Cascade_catalog_runtime.resolve_named_providers_strict
             ~sw ~net ?clock ?provider_filter ~cascade_name ()
         with
         | Error err ->
             Log.Keeper.warn
               "keeper:%s memory LLM summary provider resolution failed cascade=%s: %s"
               keeper_name cascade_name err;
             None
         | Ok providers ->
             let providers =
               List.filter is_direct_completion_provider providers
             in
             if providers = [] then begin
               Log.Keeper.warn
                 "keeper:%s memory LLM summary has no direct completion providers cascade=%s"
                 keeper_name cascade_name;
               None
             end else
               Some
                 (fun ~trace_id ~texts ->
                   summarize_with_providers ?complete ?clock ?timeout_sec
                     ~cascade_name ~sw ~net ~providers ~trace_id ~texts ()))
    | _ ->
        Log.Keeper.warn
          "keeper:%s memory LLM summary skipped: Eio context unavailable cascade=%s"
          keeper_name cascade_name;
        None
