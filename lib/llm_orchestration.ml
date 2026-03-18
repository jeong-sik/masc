(** Llm_orchestration — Concurrency control, response caching, and cascade logic for LLM calls. *)

open Printf
open Llm_types

(* ================================================================ *)
(* Concurrency limiter — throttle simultaneous LLM requests          *)
(* ================================================================ *)

(** Maximum concurrent cascade/LLM calls.
    Default 2 is conservative for local llama.cpp runtimes on 128GB hosts. *)
let max_concurrent_llm =
  int_of_env_default "MASC_MAX_CONCURRENT_LLM" ~default:2 ~min_v:1 ~max_v:128

let llm_semaphore = Eio.Semaphore.make max_concurrent_llm

let llm_semaphore_available () = Eio.Semaphore.get_value llm_semaphore

(** Outstanding permit counter for diagnostics.
    Tracks how many LLM calls are currently holding a permit. *)
let permits_outstanding = Atomic.make 0

let [@warning "-32"] permits_outstanding_count () = Atomic.get permits_outstanding

(** Eio-safe permit acquisition: explicit try/with ensures release on any
    exception including Eio.Cancel.Cancelled.
    Also tracks outstanding permits via Atomic counter for diagnostics. *)
let with_llm_permit f =
  Eio.Semaphore.acquire llm_semaphore;
  Atomic.incr permits_outstanding;
  match f () with
  | result ->
      Atomic.decr permits_outstanding;
      Eio.Semaphore.release llm_semaphore;
      result
  | exception exn ->
      Atomic.decr permits_outstanding;
      Eio.Semaphore.release llm_semaphore;
      raise exn

let llm_permits_in_use () =
  max_concurrent_llm - Eio.Semaphore.get_value llm_semaphore

(* ================================================================ *)
(* Response cache helpers                                            *)
(* ================================================================ *)

let completion_cache_schema_version = "1.0.0"

let response_format_to_string = function
  | `Text -> "text"
  | `Json -> "json"

let message_fingerprint_json (m : message) : Yojson.Safe.t =
  let m = sanitize_message_utf8 m in
  `Assoc
    [
      ("role", `String (string_of_role m.role));
      ("content", `String (text_of_message m));
    ]

let completion_request_fingerprint_json (req : completion_request) : Yojson.Safe.t =
  let req = normalize_request req in
  `Assoc
    [
      ("schema_version", `String completion_cache_schema_version);
      ("provider", `String (string_of_provider req.model.provider));
      ("model_id", `String req.model.model_id);
      ("response_format", `String (response_format_to_string req.response_format));
      ("temperature", `Float req.temperature);
      ("max_tokens", `Int req.max_tokens);
      ("messages", `List (List.map message_fingerprint_json req.messages));
    ]

let completion_cache_key (req : completion_request) =
  let canonical = Yojson.Safe.to_string (completion_request_fingerprint_json req) in
  Llm_response_cache.make_key ~namespace:"llmresp" ~content:canonical

let cache_key_of_request = completion_cache_key

let prompt_char_count (req : completion_request) =
  List.fold_left (fun acc (m : message) -> acc + String.length (text_of_message m)) 0
    req.messages

let request_has_tool_role_message (req : completion_request) =
  List.exists (fun (m : message) -> m.role = Tool) req.messages

let cache_bypass_reason (req : completion_request) : string option =
  if not Env_config.Llm.cache_enabled then
    Some "disabled"
  else if req.tools <> [] then
    Some "tools_present"
  else if request_has_tool_role_message req then
    Some "tool_role_message"
  else if req.temperature > Env_config.Llm.cache_max_temperature then
    Some "temperature"
  else if prompt_char_count req > Env_config.Llm.cache_max_prompt_chars then
    Some "prompt_too_large"
  else
    None

let record_cache_bypass reason =
  Prometheus.inc_counter "masc_llm_cache_bypass_total" ();
  Prometheus.inc_counter "masc_llm_cache_bypass_total"
    ~labels:[ ("reason", reason) ] ()

(* ================================================================ *)
(* Core: complete                                                   *)
(* ================================================================ *)

(** Single completion with MASC-level cache check/write (OAS serialization format)
    and OAS metrics. Cache key uses MASC's temperature-aware fingerprint.
    Cache values use OAS api_response JSON format via {!Llm_provider.Cache}. *)
let complete ?timeout_sec (req : completion_request) : (completion_response, string) result =
  let t0 = Time_compat.now () in
  let req = normalize_request req in
  let cache_key =
    match cache_bypass_reason req with
    | Some reason ->
        record_cache_bypass reason;
        None
    | None -> Some (completion_cache_key req)
  in
  let cached_result =
    match cache_key with
    | None -> None
    | Some key -> (
        match Llm_response_cache.get_json ~key with
        | Ok (Some cached_json) -> (
            match Llm_provider.Cache.response_of_json cached_json with
            | Some api_resp ->
                Prometheus.inc_counter "masc_llm_cache_hits_total" ();
                Some (Ok (Llm_provider_dispatch.completion_response_of_api_response api_resp))
            | None ->
                Prometheus.inc_counter "masc_llm_cache_errors_total" ();
                let _ = Llm_response_cache.delete ~key in
                Log.LlmClient.warn "cache decode error: incompatible format";
                None)
        | Ok None ->
            Prometheus.inc_counter "masc_llm_cache_misses_total" ();
            None
        | Error e ->
            Prometheus.inc_counter "masc_llm_cache_errors_total" ();
            Log.LlmClient.warn "cache read error: %s" e;
            None)
  in
  let metrics_opt = Some (Llm_oas_adapters.metrics_adapter ()) in
  let result =
    match cached_result with
    | Some cached -> cached
    | None ->
        let upstream_result =
          match req.model.provider with
          | Glm_cloud ->
              Llm_provider_dispatch.call_glm_cloud_with_pool
                ?timeout_sec ?metrics:metrics_opt req
          | _ ->
              Llm_provider_dispatch.call_provider
                ?timeout_sec ?metrics:metrics_opt req
        in
        (match (cache_key, upstream_result) with
        | Some key, Ok resp -> (
            let api_resp =
              Llm_provider_dispatch.api_response_of_completion_response resp
            in
            match
              Llm_response_cache.set_json ~key
                ~ttl_seconds:Env_config.Llm.cache_ttl_seconds
                (Llm_provider.Cache.response_to_json api_resp)
            with
            | Ok () -> Prometheus.inc_counter "masc_llm_cache_writes_total" ()
            | Error e ->
                Prometheus.inc_counter "masc_llm_cache_errors_total" ();
                Log.LlmClient.warn "cache write error: %s" e);
            Ok resp
        | _ -> upstream_result)
  in
  let elapsed_ms = int_of_float ((Time_compat.now () -. t0) *. 1000.0) in
  Result.map (fun resp -> { resp with latency_ms = elapsed_ms }) result

(* ================================================================ *)
(* Provider-aware capacity check                                    *)
(* ================================================================ *)

(** Check whether local providers (Llama) have healthy endpoints.
    When cloud fallbacks exist in the cascade, unhealthy local providers
    are removed so cloud takes over. When the cascade is local-only,
    requests pass through unchanged — the provider returns a connection
    error, which is more informative than a synthetic "unhealthy" error. *)
let filter_by_provider_health (requests : completion_request list)
    : completion_request list =
  let has_local = List.exists (fun (r : completion_request) ->
    r.model.provider = Llama) requests in
  if not has_local then requests
  else
    let has_cloud = List.exists (fun (r : completion_request) ->
      r.model.provider <> Llama) requests in
    let endpoints = Llm_discovery_cache.get_cached_or_refresh () in
    let any_healthy = Llm_discovery_cache.any_local_healthy () in
    let idle = Llm_discovery_cache.idle_slot_count () in
    let busy = Llm_discovery_cache.busy_slot_count () in
    Log.LlmClient.info
      "cascade capacity: local endpoints=%d healthy=%b idle=%d busy=%d"
      (List.length endpoints) any_healthy idle busy;
    if not any_healthy && has_cloud then begin
      Log.LlmClient.warn
        "cascade: local endpoints unhealthy, falling back to cloud providers";
      List.filter (fun (r : completion_request) ->
        r.model.provider <> Llama) requests
    end else
      requests

(* ================================================================ *)
(* Cascade: try models in order                                     *)
(* ================================================================ *)

let cascade ?(accept = fun _ -> true) ?timeout_sec
    (requests : completion_request list) : (completion_response, string) result =
  let requests = filter_by_provider_health requests in
  with_llm_permit (fun () ->
    let avail = Eio.Semaphore.get_value llm_semaphore in
    Log.LlmClient.debug "cascade: acquired permit (%d/%d available)"
      avail max_concurrent_llm;
    let deadline_opt =
      Option.map (fun sec -> Time_compat.now () +. float_of_int sec) timeout_sec
    in
    let remaining_timeout_sec () =
      match deadline_opt with
      | None -> None
      | Some deadline ->
          let remaining = int_of_float (Float.ceil (deadline -. Time_compat.now ())) in
          Some (max 0 remaining)
    in
    let rec try_next errors = function
      | [] ->
        let all_errors = String.concat "; " (List.rev errors) in
        Error (sprintf "All models failed: %s" all_errors)
      | _ when Option.value ~default:1 (remaining_timeout_sec ()) <= 0 ->
        let all_errors =
          String.concat "; " (List.rev ("cascade deadline exceeded" :: errors))
        in
        Error (sprintf "All models failed: %s" all_errors)
      | req :: rest ->
        Log.LlmClient.debug "cascade: trying %s (%s)"
          req.model.model_id (string_of_provider req.model.provider);
        let attempt_result =
          match remaining_timeout_sec () with
          | None -> complete req
          | Some sec when sec > 0 ->
              complete ~timeout_sec:sec req
          | Some _ -> Error "cascade deadline exceeded"
        in
        match attempt_result with
        | Ok resp ->
          if accept resp then (
            Log.LlmClient.info "cascade: success with %s (%dms)"
              resp.model_used resp.latency_ms;
            Ok resp)
          else (
            Log.LlmClient.warn
              "cascade: %s rejected by validator, continuing"
              resp.model_used;
            try_next ("response rejected by validator" :: errors) rest)
        | Error e ->
          Log.LlmClient.warn "cascade: %s failed: %s"
            req.model.model_id e;
          try_next (e :: errors) rest
    in
    try_next [] requests)

(* ================================================================ *)
(* run_prompt_cascade                                                *)
(* ================================================================ *)

let run_prompt_cascade ?(temperature = 0.7) ?timeout_sec
    ?(accept = fun _ -> true) ?system ~model_specs ~max_tokens ~prompt () =
  let msgs =
    match system with
    | Some s -> [ system_msg s; user_msg prompt ]
    | None -> [ user_msg prompt ]
  in
  let requests =
    List.map
      (fun (model : model_spec) ->
        ({
           model;
           messages = msgs;
           temperature;
           max_tokens;
           tools = [];
           response_format = `Text;
         }
          : completion_request))
      model_specs
  in
  cascade ?timeout_sec ~accept requests

(* ================================================================ *)
(* Streaming completion                                             *)
(* ================================================================ *)

(** Execute a streaming LLM completion using OAS provider path.
    Each SSE event (token deltas) is delivered to [on_event] as it arrives.
    Returns the final assembled response after the stream ends.

    Streaming bypasses cache: SSE events are incremental and not cacheable.
    No retry logic — a single attempt is made.
    Falls back to batch completion (synthesising a single delta event)
    when provider config is unavailable or streaming fails. *)
let call_provider_stream ?timeout_sec (req : completion_request)
    ~(on_event : Llm_provider.Types.sse_event -> unit)
    : (completion_response, string) result =
  let req = normalize_request req in
  (* Try real streaming first *)
  let stream_result =
    match Llm_provider_dispatch.provider_config_of_request req with
    | Error _ -> None  (* fall through to batch *)
    | Ok (config, messages, tools) ->
        let env = Llm_eio_env.get () in
        Log.LlmClient.debug
          "provider stream req: model=%s provider=%s max_tokens=%d tools=%d"
          req.model.model_id
          (string_of_provider req.model.provider)
          req.max_tokens (List.length req.tools);
        let result =
          try
            Llm_provider.Complete.complete_stream
              ~sw:env.sw ~net:env.net ~config
              ~messages
              ?tools:(if tools = [] then None else Some tools)
              ~on_event ()
          with exn ->
            Error (Llm_provider.Http_client.NetworkError
                     { message = Printexc.to_string exn })
        in
        (match result with
         | Ok resp ->
             let masc_resp = completion_response_of_api_response resp in
             let text = text_of_response masc_resp in
             if String.trim text = "" && masc_resp.tool_calls = [] then
               None  (* empty response, try batch *)
             else
               Some (Ok masc_resp)
         | Error http_err ->
             Log.LlmClient.warn "stream: provider error: %s"
               (string_of_http_error http_err);
             None  (* fall through to batch *))
  in
  match stream_result with
  | Some result -> result
  | None ->
      (* Fallback: batch call, then synthesise SSE events *)
      Log.LlmClient.info
        "stream: falling back to batch for %s" req.model.model_id;
      let timeout_sec_int =
        Option.map (fun f -> max 1 (int_of_float (Float.ceil f))) timeout_sec
      in
      let batch_result = complete ?timeout_sec:timeout_sec_int req in
      (match batch_result with
       | Ok resp ->
           let text = text_of_response resp in
           on_event (MessageStart {
             id = "batch-" ^ req.model.model_id;
             model = resp.model_used;
             usage = None;
           });
           if text <> "" then
             on_event (ContentBlockDelta {
               index = 0;
               delta = TextDelta text;
             });
           on_event MessageStop;
           Ok resp
       | Error _ as e -> e)
