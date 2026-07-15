(** LLM-backed keeper memory-bank consolidation.

    This module is intentionally a narrow MASC-side adapter.  OAS already
    exposes the low-level completion API; keeper memory-bank compaction owns
    the domain prompt, opt-in gate, provider choice, and fallback semantics. *)


(* http_error_message moved to Provider_http_error.to_message (SSOT,
   2026-06-24): four byte-for-output-identical copies unified. *)
let summary_max_tokens = 512

(* Observability for [summarize_with_provider] outcomes and
   [summarize_with_providers] chain exhaustion.  Existing warn lines
   are preserved; this adds a typed counter so operators can read
   success rate per provider, and an explicit warn when the runtime
   yields no summary at all (previously silent).  Closes the
   silent-failure gap flagged in
   .tmp/memory-compacting-analysis.html (LLM-summary triple-silent
   fallback chain). *)
let () =
  Otel_metric_store.register_counter
    ~name:Keeper_metrics.(to_string MemoryLlmSummaryOutcomes)
    ~help:
      "Total [summarize_with_provider] attempts classified by label \
       [outcome] (ok_summary | timed_out | http_error | empty_response | \
       invalid_structured_response). \
       Labels: [outcome], [provider] (neutral runtime lane — concrete \
       model_id is OAS-owned and redacted per RFC-0132 PR-2), [runtime_id]."
    ();
  Otel_metric_store.register_counter
    ~name:Keeper_metrics.(to_string MemoryLlmSummaryChainExhausted)
    ~help:
      "Total [summarize_with_providers] runs where every provider \
       returned a non-Ok outcome and the consolidation pass received \
       no summary.  Label [runtime_id] names the runtime.  Rising rate \
       means consolidation is silently skipping the LLM summary."
    ()
;;

(* RFC-0132 PR-2: memory-summary outcome metric label + warn logs are an
   external boundary; redact concrete provider/model identity via SSOT.
   Runtime identity stays in-boundary through the separate [runtime_id]
   label and warn-log argument. *)
let runtime_lane_label =
  Boundary_redaction.to_string Boundary_redaction.runtime_model_label

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
  | Anthropic | Kimi | OpenAI_compat | Ollama | Gemini | Glm | DashScope -> true

let provider_for_summary (provider_cfg : Llm_provider.Provider_config.t) =
  let max_tokens =
    match provider_cfg.max_tokens with
    | Some n when n > 0 -> Some (min n summary_max_tokens)
    | _ -> Some summary_max_tokens
  in
  { provider_cfg with
    max_tokens;
    tool_choice = None;
    disable_parallel_tool_use = true;
  }
  |> Keeper_structured_output_schema.apply_to_provider_config
       Keeper_structured_output_schema.memory_bank_summary_output_schema

let summary_schema_supported provider_cfg =
  Keeper_structured_output_schema.provider_config_accepts_schema
    Keeper_structured_output_schema.memory_bank_summary_output_schema
    provider_cfg

let message role text : Agent_sdk.Types.message = Agent_sdk.Types.text_message role text

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
     steps. Do not invent facts. Do not include markdown fences. Output only \
     a JSON object with a non-empty string field named \
     summary."
  in
  let user =
    Printf.sprintf
      "trace_id: %s\n\
       notes:\n\
       %s\n\n\
       Write a concise durable summary for future keeper code work. Return \
       {\"summary\":\"...\"} only."
      trace_id
      (bounded_notes_text texts)
  in
  [ message Agent_sdk.Types.System system; message Agent_sdk.Types.User user ]

let raw_response_text (response : Agent_sdk.Types.api_response) : string option =
  let text =
    Agent_sdk_response.text_of_response response
    |> String.split_on_char '\n'
    |> List.map String.trim
    |> List.filter (fun s -> s <> "")
    |> String.concat "\n"
    |> String.trim
  in
  if text = "" then None else Some text

type summary_parse_error =
  | Empty_summary_response
  | Invalid_structured_response of string

let summary_text_result_of_json = function
  | `Assoc fields ->
    (match List.assoc_opt "summary" fields with
     | Some (`String summary) ->
       let summary = String.trim summary in
       if summary = "" then Error Empty_summary_response else Ok summary
     | Some _ -> Error (Invalid_structured_response "summary field must be a string")
     | None -> Error (Invalid_structured_response "missing summary field"))
  | _ -> Error (Invalid_structured_response "summary response must be an object")
;;

let summary_text_result_of_raw_text raw =
  let raw = String.trim raw in
  if raw = "" then Error Empty_summary_response
  else
    match Yojson.Safe.from_string raw with
    | exception Yojson.Json_error msg ->
        Error (Invalid_structured_response ("invalid JSON: " ^ msg))
    | json -> summary_text_result_of_json json
;;

let summary_text_result_of_response response =
  match raw_response_text response with
  | None -> Error Empty_summary_response
  | Some _ ->
    (match
       Agent_sdk_response.structured_json_of_response
         ~schema_name:"keeper_memory_bank_summary"
         response
     with
     | Ok json -> summary_text_result_of_json json
     | Error detail -> Error (Invalid_structured_response detail))

let summary_text_of_response response =
  match summary_text_result_of_response response with
  | Ok summary -> Some summary
  | Error _ -> None
;;

type 'a timeout_result =
  | Completed of 'a
  | Timed_out
  | Clock_unavailable

(* No wall-clock budget kill (fail-open; RFC-0156 withdrew the MASC turn-budget
   timeout policy). Run [f] to natural completion instead of wrapping it in
   [Eio.Time.with_timeout_exn]: a slow-but-healthy provider that is still
   streaming would otherwise turn every budget expiry into kill -> error ->
   retry churn. A genuine INNER transport timeout raised from within [f]
   (HTTP client / connect / idle) still surfaces as [Eio.Time.Timeout] ->
   [Timed_out]. [Eio.Cancel.Cancelled] is not caught here, so it propagates
   unchanged. The no-clock branch stays as-is (env-not-initialised guard). *)
let with_timeout ?clock ~timeout_sec:_ f =
  match clock with
  | None -> Clock_unavailable
  | Some _clock ->
    (try Completed (f ()) with
     | Eio.Time.Timeout -> Timed_out)

let record_summary_outcome
    ~(runtime_id : string)
    ~(outcome : Keeper_memory_llm_summary_outcome.t) =
  Otel_metric_store.inc_counter
    Keeper_metrics.(to_string MemoryLlmSummaryOutcomes)
    ~labels:
      [ ("outcome", Keeper_memory_llm_summary_outcome.to_label outcome)
      ; ("provider", runtime_lane_label)
      ; ("runtime_id", runtime_id)
      ]
    ()

let summarize_with_provider
    ?(complete : complete_fn = default_complete)
    ?clock
    ?(timeout_sec = Env_config_runtime_services.Inference.timeout_seconds)
    ~runtime_id
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
    | Timed_out ->
        Log.Keeper.warn
          "memory LLM summary timed out trace_id=%s runtime=%s timeout_sec=%.1f"
          trace_id runtime_id timeout_sec;
        None, Keeper_memory_llm_summary_outcome.Timed_out
    | Clock_unavailable ->
        Log.Keeper.warn
          "memory LLM summary clock unavailable trace_id=%s runtime=%s \
           timeout_sec=%.1f — refusing provider call without enforcing timeout"
          trace_id runtime_id timeout_sec;
        None, Keeper_memory_llm_summary_outcome.Clock_unavailable
    | Completed (Ok response) ->
        (match summary_text_result_of_response response with
         | Ok summary ->
             Some summary, Keeper_memory_llm_summary_outcome.Ok_summary
         | Error Empty_summary_response ->
             Log.Keeper.warn
               "memory LLM summary empty trace_id=%s runtime=%s"
               trace_id runtime_id;
             None, Keeper_memory_llm_summary_outcome.Empty_response
         | Error (Invalid_structured_response detail) ->
             Log.Keeper.warn
               "memory LLM summary invalid structured response trace_id=%s \
                runtime=%s detail=%s"
               trace_id runtime_id detail;
             None, Keeper_memory_llm_summary_outcome.Invalid_structured_response)
    | Completed (Error err) ->
        Log.Keeper.warn
          "memory LLM summary failed trace_id=%s runtime=%s: %s"
          trace_id runtime_id (Provider_http_error.to_message err);
        None, Keeper_memory_llm_summary_outcome.Http_error
  in
  record_summary_outcome ~runtime_id ~outcome;
  result

module For_testing = struct
  let summary_text_of_response = summary_text_of_response
  let summary_text_result_of_response = summary_text_result_of_response
  let record_summary_outcome = record_summary_outcome
  let summarize_with_provider = summarize_with_provider
end

let summarize_with_providers
    ?complete
    ?clock
    ?timeout_sec
    ~runtime_id
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
          summarize_with_provider ?complete ?clock ?timeout_sec ~runtime_id
            ~sw ~net ~provider_cfg ~trace_id ~texts ()
        with
        | Some summary -> Some summary
        | None -> go rest)
  in
  match go providers with
  | Some _ as summary -> summary
  | None ->
      Otel_metric_store.inc_counter
        Keeper_metrics.(to_string MemoryLlmSummaryChainExhausted)
        ~labels:[("runtime_id", runtime_id)]
        ();
      Log.Keeper.warn
        "memory LLM summary chain exhausted trace_id=%s runtime=%s \
         providers_attempted=%d — consolidation skipped LLM summary"
        trace_id
        runtime_id
        (List.length providers);
      None

let make
    ?complete
    ?timeout_sec
    ~(runtime_id : string)
    ~(keeper_name : string)
    () : Keeper_memory_bank.memory_consolidation_summarizer option =
  if not (Keeper_memory_bank.memory_llm_summary_enabled ()) then None
  else
    match Eio_context.get_switch_opt (), Eio_context.get_net_opt () with
    | Some sw, Some net ->
        let clock = Eio_context.get_clock_opt () in
        let provider_runtime_id =
          Keeper_memory_runtime_resolution.runtime_id_for_librarian ~runtime_id
        in
        (match
           Keeper_memory_runtime_resolution.provider_for_runtime
             ~runtime_id:provider_runtime_id
         with
         | Error err ->
             Log.Keeper.warn ~keeper_name:keeper_name
               "memory LLM summary provider resolution failed runtime=%s: %s"
               provider_runtime_id err;
             None
         | Ok provider ->
             let providers =
               [ provider ]
               |> List.filter is_direct_completion_provider
               |> List.filter summary_schema_supported
             in
             if providers = [] then begin
               Log.Keeper.warn ~keeper_name:keeper_name
                 "memory LLM summary has no schema-capable direct completion providers runtime=%s"
                 provider_runtime_id;
               None
             end else
               Some
                 (fun ~trace_id ~texts ->
                   summarize_with_providers ?complete ?clock ?timeout_sec
                     ~runtime_id:provider_runtime_id ~sw ~net ~providers ~trace_id ~texts ()))
    | _ ->
        Log.Keeper.warn ~keeper_name:keeper_name
          "memory LLM summary skipped: Eio context unavailable runtime=%s"
          runtime_id;
        None
