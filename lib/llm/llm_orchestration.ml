(** Llm_orchestration — Concurrency diagnostics, response caching, and health filtering.

    Inference functions (complete, cascade, run_prompt_cascade, call_provider_stream)
    have been removed. All LLM calls now route through {!Oas_worker} or {!Llm_cascade}.

    Retained: concurrency counters, cache helpers, health filtering. *)

open Llm_types

(* ================================================================ *)
(* Concurrency diagnostics (no throttling)                           *)
(* ================================================================ *)

(** Maximum concurrent LLM calls — retained for diagnostics/dashboard.
    No longer enforced via semaphore: llama-server handles slot-based
    parallelism internally, and cloud APIs return rate-limit errors. *)
let max_concurrent_llm =
  int_of_env_default "MASC_MAX_CONCURRENT_LLM" ~default:8 ~min_v:1 ~max_v:128

(** Atomic counter tracking in-flight LLM calls (observability only). *)
let inflight = Atomic.make 0

let llm_semaphore_available () = max_concurrent_llm - Atomic.get inflight
let llm_permits_in_use () = Atomic.get inflight

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
