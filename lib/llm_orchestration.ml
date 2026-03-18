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

let token_usage_to_json (u : token_usage) : Yojson.Safe.t =
  `Assoc
    [
      ("input_tokens", `Int u.input_tokens);
      ("output_tokens", `Int u.output_tokens);
      ("total_tokens", `Int u.total_tokens);
      ("cache_creation_input_tokens", `Int u.cache_creation_input_tokens);
      ("cache_read_input_tokens", `Int u.cache_read_input_tokens);
    ]

let token_usage_of_json (json : Yojson.Safe.t) : (token_usage, string) result =
  let open Yojson.Safe.Util in
  try
    Ok
      {
        input_tokens = json |> member "input_tokens" |> to_int;
        output_tokens = json |> member "output_tokens" |> to_int;
        total_tokens = json |> member "total_tokens" |> to_int;
        cache_creation_input_tokens =
          json |> member "cache_creation_input_tokens" |> to_int;
        cache_read_input_tokens = json |> member "cache_read_input_tokens" |> to_int;
      }
  with exn -> Error (Printexc.to_string exn)

let tool_call_to_json (tc : tool_call) : Yojson.Safe.t =
  `Assoc
    [
      ("call_id", `String tc.call_id);
      ("call_name", `String tc.call_name);
      ("call_arguments", `String tc.call_arguments);
    ]

let tool_call_of_json (json : Yojson.Safe.t) : (tool_call, string) result =
  let open Yojson.Safe.Util in
  try
    Ok
      {
        call_id = json |> member "call_id" |> to_string;
        call_name = json |> member "call_name" |> to_string;
        call_arguments = json |> member "call_arguments" |> to_string;
      }
  with exn -> Error (Printexc.to_string exn)

let completion_response_to_cache_json (resp : completion_response) : Yojson.Safe.t =
  `Assoc
    [
      ("schema_version", `String completion_cache_schema_version);
      ("kind", `String "completion_response");
      ( "response",
        `Assoc
          [
            ("content", `String (text_of_response resp));
            ("tool_calls", `List (List.map tool_call_to_json resp.tool_calls));
            ("usage", token_usage_to_json resp.usage);
            ("model_used", `String resp.model_used);
          ] );
    ]

let completion_response_of_cache_json
    (json : Yojson.Safe.t) : (completion_response, string) result =
  let open Yojson.Safe.Util in
  try
    let schema_version = json |> member "schema_version" |> to_string in
    if not (String.equal schema_version completion_cache_schema_version) then
      Error
        (Printf.sprintf "schema mismatch: expected=%s actual=%s"
           completion_cache_schema_version schema_version)
    else
      let kind = json |> member "kind" |> to_string in
      if not (String.equal kind "completion_response") then
        Error (Printf.sprintf "unexpected cache kind: %s" kind)
      else
        let body = json |> member "response" in
        let usage_json = body |> member "usage" in
        let usage = token_usage_of_json usage_json in
        let tool_calls =
          body |> member "tool_calls" |> to_list
          |> List.map tool_call_of_json
        in
        let tool_calls =
          List.fold_right
            (fun item acc ->
              match (item, acc) with
              | Ok tc, Ok xs -> Ok (tc :: xs)
              | Error e, _ -> Error e
              | _, Error e -> Error e)
            tool_calls (Ok [])
        in
        (match usage, tool_calls with
        | Ok usage, Ok tool_calls ->
            Ok
              {
                content = [Agent_sdk.Types.Text (body |> member "content" |> to_string)];
                tool_calls;
                usage;
                model_used = body |> member "model_used" |> to_string;
                latency_ms = 0;
              }
        | Error e, _ -> Error e
        | _, Error e -> Error e)
  with exn -> Error (Printexc.to_string exn)

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
            match completion_response_of_cache_json cached_json with
            | Ok resp ->
                Prometheus.inc_counter "masc_llm_cache_hits_total" ();
                Some (Ok resp)
            | Error e ->
                Prometheus.inc_counter "masc_llm_cache_errors_total" ();
                let _ = Llm_response_cache.delete ~key in
                Log.LlmClient.warn "cache decode error: %s" e;
                None)
        | Ok None ->
            Prometheus.inc_counter "masc_llm_cache_misses_total" ();
            None
        | Error e ->
            Prometheus.inc_counter "masc_llm_cache_errors_total" ();
            Log.LlmClient.warn "cache read error: %s" e;
            None)
  in
  let result =
    match cached_result with
    | Some cached -> cached
    | None ->
      let upstream_result =
          match req.model.provider with
          | Glm_cloud ->
              Llm_provider_bridge.call_glm_cloud_with_pool ?timeout_sec req
          | _ ->
              Llm_provider_bridge.call ?timeout_sec req
        in
        (match (cache_key, upstream_result) with
        | Some key, Ok resp -> (
            match
              Llm_response_cache.set_json ~key
                ~ttl_seconds:Env_config.Llm.cache_ttl_seconds
                (completion_response_to_cache_json resp)
            with
            | Ok () -> Prometheus.inc_counter "masc_llm_cache_writes_total" ()
            | Error e ->
                Prometheus.inc_counter "masc_llm_cache_errors_total" ();
                Log.LlmClient.warn "cache write error: %s" e);
            Ok resp
        | _ -> upstream_result)
  in
  let elapsed_ms = int_of_float ((Time_compat.now () -. t0) *. 1000.0) in
  (* Inject latency into response *)
  Result.map (fun resp -> { resp with latency_ms = elapsed_ms }) result

(* ================================================================ *)
(* Provider-aware capacity check                                    *)
(* ================================================================ *)

(** Check whether local providers (Llama) have healthy endpoints.
    Returns the request list with unhealthy local providers removed.
    Cloud providers (Anthropic, Gemini, GLM, etc.) always pass through. *)
let filter_by_provider_health (requests : completion_request list)
    : completion_request list =
  let has_local_request =
    List.exists (fun (r : completion_request) ->
      r.model.provider = Llama) requests
  in
  if not has_local_request then requests
  else
    let endpoints = Llm_discovery_cache.get_cached_or_refresh () in
    let any_healthy = Llm_discovery_cache.any_local_healthy () in
    let idle = Llm_discovery_cache.idle_slot_count () in
    let busy = Llm_discovery_cache.busy_slot_count () in
    Log.LlmClient.info
      "cascade capacity: local endpoints=%d healthy=%b idle=%d busy=%d"
      (List.length endpoints) any_healthy idle busy;
    if not any_healthy then begin
      Log.LlmClient.warn
        "cascade: all local endpoints unhealthy, skipping local providers";
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
  if requests = [] then
    Error "All providers unhealthy (local endpoints down, no cloud fallback)"
  else
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
