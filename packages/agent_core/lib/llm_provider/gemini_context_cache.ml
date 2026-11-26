(* See gemini_context_cache.mli for module rationale. *)

(* Gemini explicit context caching enforces a minimum cached token floor
   (1024-2048 tokens depending on model family); 4096 bytes of JSON/text is a
   conservative lower bound so tiny prefixes stay on implicit caching. *)
let default_min_prefix_bytes = 4096
let default_negative_ttl_s = 300.0
let max_cached_entries = 256
let max_negative_entries = 256
let max_refresh_margin_s = 60.0

type handle =
  { key : string
  ; resource_name : string
  }

type cache_entry =
  { resource_name : string
  ; expires_at_s : float
  }

type negative_entry =
  { neg_expires_at_s : float
  }

type inflight_slot =
  { promise : handle option Eio.Promise.t
  ; resolver : handle option Eio.Promise.u
  ; os_cond : Stdlib.Condition.t
  ; mutable done_ : bool
  ; mutable result : handle option
  ; mutable auth_invalidated : bool
  }

let eio_probe_key : unit Eio.Fiber.key = Eio.Fiber.create_key ()

let in_eio_fiber () =
  match Eio.Fiber.get eio_probe_key with
  | Some () | None -> true
  | exception Effect.Unhandled _ -> false
;;

let cache_mu = Mutex.create ()
let entries : (string, cache_entry) Hashtbl.t = Hashtbl.create 32
let negative_entries : (string, negative_entry) Hashtbl.t = Hashtbl.create 32
let in_flight : (string, inflight_slot) Hashtbl.t = Hashtbl.create 32

let with_cache_lock f = Mutex.protect cache_mu f

let clear_for_tests () =
  with_cache_lock (fun () ->
    Hashtbl.clear entries;
    Hashtbl.clear negative_entries;
    Hashtbl.clear in_flight)
;;

let invalidate ~key =
  with_cache_lock (fun () ->
    Hashtbl.remove entries key;
    Hashtbl.remove negative_entries key)
;;

let explicit_cache_ttl_if_enabled ~(config : Provider_config.t) =
  match config.explicit_context_cache_ttl_s with
  | None -> None
  | Some ttl_s ->
    let caps, _ = Provider_config.resolve_request_capabilities config in
    (match caps.Capabilities.prompt_cache_wire with
     | Capabilities.Gemini_explicit_cached_content -> Some ttl_s
     | Capabilities.No_prompt_cache_wire
     | Capabilities.Openrouter_top_level_cache_control
     | Capabilities.Kimi_prompt_cache_options -> None)
;;

let strip_trailing_slashes url =
  let len = ref (String.length url) in
  while !len > 0 && url.[!len - 1] = '/' do
    decr len
  done;
  String.sub url 0 !len
;;

let bare_model_id model_id =
  if String.starts_with ~prefix:"models/" model_id
  then String.sub model_id 7 (String.length model_id - 7)
  else model_id
;;

let vertex_target_of_base_url ~base_url =
  let trimmed = strip_trailing_slashes base_url in
  match Vertex_endpoint.parse_base_url trimmed with
  | Error _ -> None
  | Ok (project, location) ->
    let host, region =
      match location with
      | Vertex_endpoint.Global -> "aiplatform.googleapis.com", "global"
      | Vertex_endpoint.Regional r -> r ^ "-aiplatform.googleapis.com", r
    in
    Some (host, project, region)
;;

let cached_contents_url ~base_url =
  match vertex_target_of_base_url ~base_url with
  | Some (host, project, region) ->
    Printf.sprintf
      "https://%s/v1/projects/%s/locations/%s/cachedContents"
      host
      project
      region
  | None -> strip_trailing_slashes base_url ^ "/cachedContents"
;;

let model_resource_name ?base_url model_id =
  match Option.bind base_url (fun base_url -> vertex_target_of_base_url ~base_url) with
  | Some (_host, project, region) ->
    Printf.sprintf
      "projects/%s/locations/%s/publishers/google/models/%s"
      project
      region
      (bare_model_id model_id)
  | None ->
    if String.starts_with ~prefix:"models/" model_id
    then model_id
    else "models/" ^ model_id
;;

let prefix_components (prefix : Backend_gemini.cacheable_prefix) =
  (match prefix.system_instruction with
   | Some si -> [ "systemInstruction", si ]
   | None -> [])
  @ (match prefix.tools_json with
     | Some tools -> [ "tools", tools ]
     | None -> [])
  @
  match prefix.tool_config_json with
  | Some tc -> [ "toolConfig", tc ]
  | None -> []
;;

let prefix_byte_size (prefix : Backend_gemini.cacheable_prefix) =
  match prefix_components prefix with
  | [] -> 0
  | fields -> String.length (Yojson.Safe.to_string (`Assoc fields))
;;

let canonical_headers hdrs =
  hdrs
  |> List.map (fun (k, v) -> String.lowercase_ascii (String.trim k), v)
  |> List.sort (fun (k1, v1) (k2, v2) ->
    match String.compare k1 k2 with
    | 0 -> String.compare v1 v2
    | c -> c)
  |> List.map (fun (k, v) -> `List [ `String k; `String v ])
;;

let is_ephemeral_request_header ~cache_session_header name =
  let lower = String.lowercase_ascii (String.trim name) in
  match lower with
  | "traceparent" | "tracestate" | "baggage" | "x-request-id" | "x-correlation-id" ->
    true
  | _ ->
    (match cache_session_header with
     | Some session_header ->
       String.equal lower (String.lowercase_ascii (String.trim session_header))
     | None -> false)
;;

let is_bearer_authorization_header (name, value) =
  if String.equal (String.lowercase_ascii (String.trim name)) "authorization"
  then (
    let trimmed = String.lowercase_ascii (String.trim value) in
    String.equal trimmed "bearer"
    || String.starts_with ~prefix:"bearer " trimmed
    || String.starts_with ~prefix:"bearer\t" trimmed)
  else false
;;

let auth_scheme_tag = function
  | Provider_config.Provider_default -> "provider_default"
  | Provider_config.Bearer_token -> "bearer_token"
;;

let credential_source_tag = function
  | Provider_config.Static_credential -> "static"
  | Provider_config.Refreshable_credential _ -> "refreshable"
;;

let provider_authentication_tag = function
  | Provider_config.No_auth -> "no_auth"
  | Provider_config.Api_key -> "api_key"
  | Provider_config.Setup_token -> "setup_token"
;;

let provider_identity_tag (config : Provider_config.t) =
  let provider_id = Option.value ~default:"" config.provider_id in
  let binding =
    match Provider_config.selected_provider_identity config with
    | None -> "none"
    | Some { Provider_config.authentication; credential_scope } ->
      provider_authentication_tag authentication
      ^ ":"
      ^ Option.value ~default:"" credential_scope
  in
  provider_id
  ^ "\x01"
  ^ auth_scheme_tag config.auth_scheme
  ^ "\x01"
  ^ credential_source_tag config.credential_source
  ^ "\x01"
  ^ binding
;;

let credential_fingerprint ~(config : Provider_config.t) ~auth_headers =
  (* Rotating OAuth Bearer tokens (Vertex ADC / [Refreshable_credential]) must
     not participate in the cache key — otherwise every ~1h OAuth refresh
     misses the local cache and orphans still-billed Vertex [cachedContents]
     resources. Static API keys (e.g. AI Studio [x-goog-api-key] / static
     [config.api_key]) remain hashed verbatim so distinct accounts stay
     strictly isolated. *)
  let is_ephemeral_bearer =
    match config.credential_source with
    | Provider_config.Refreshable_credential _ -> true
    | Provider_config.Static_credential ->
      Option.is_some (vertex_target_of_base_url ~base_url:config.base_url)
  in
  let auth_material =
    match auth_headers with
    | _ :: _ ->
      if is_ephemeral_bearer
      then (
        let bearer_hdrs, non_bearer_hdrs =
          List.partition is_bearer_authorization_header auth_headers
        in
        let non_bearer_json =
          Yojson.Safe.to_string (`List (canonical_headers non_bearer_hdrs))
        in
        let bearer_marker =
          match bearer_hdrs with
          | [] -> "no-bearer"
          | _ :: _ -> "ephemeral-bearer"
        in
        bearer_marker ^ "\x01" ^ non_bearer_json)
      else Yojson.Safe.to_string (`List (canonical_headers auth_headers))
    | [] ->
      (match config.credential_source with
       | Provider_config.Refreshable_credential _ -> "refreshable-no-headers"
       | Provider_config.Static_credential ->
         if Secret.is_empty config.api_key
         then "no-auth"
         else "api-key:" ^ Secret.header_value config.api_key)
  in
  (* Exclude per-call tracing/correlation/session headers (e.g. W3C
     [traceparent]/[tracestate] injected by [config_with_trace_context]) from
     the cache key so traced turns reuse the cached resource while still
     forwarding those headers on outbound [POST .../cachedContents] calls. *)
  let cache_session_header = Provider_config.cache_session_header config in
  let stable_headers =
    Provider_config.effective_request_headers config
    |> List.filter (fun (k, _) ->
      not (is_ephemeral_request_header ~cache_session_header k))
    |> canonical_headers
    |> fun xs -> Yojson.Safe.to_string (`List xs)
  in
  let endpoint_scope = strip_trailing_slashes config.base_url in
  let identity = provider_identity_tag config in
  Agent_core_sha256.(
    digest_string
      (endpoint_scope
       ^ "\x00"
       ^ identity
       ^ "\x00"
       ^ auth_material
       ^ "\x00"
       ^ stable_headers)
    |> to_hex)
;;

let prefix_key
      ?(auth_headers = [])
      ~(config : Provider_config.t)
      ~(prefix : Backend_gemini.cacheable_prefix)
      ()
  =
  let key_fp = credential_fingerprint ~config ~auth_headers in
  let canonical =
    `Assoc
      ([ "base_url", `String (strip_trailing_slashes config.base_url)
       ; "key_fp", `String key_fp
       ; "model_id", `String (model_resource_name ~base_url:config.base_url config.model_id)
       ]
       @ prefix_components prefix)
    |> Yojson.Safe.to_string
  in
  Agent_core_sha256.(digest_string canonical |> to_hex)
;;

let build_create_body ?base_url ~model_id ~ttl_s ~(prefix : Backend_gemini.cacheable_prefix) () =
  let fields =
    [ "model", `String (model_resource_name ?base_url model_id)
    ; "ttl", `String (Printf.sprintf "%ds" ttl_s)
    ]
    @ prefix_components prefix
  in
  Yojson.Safe.to_string (`Assoc fields)
;;

let current_time_s ?clock () =
  match clock with
  | Some c -> Eio.Time.now c
  | None -> Unix.gettimeofday ()
;;

let refresh_margin_s ~ttl_s =
  Float.min max_refresh_margin_s (float_of_int ttl_s *. 0.1)
;;

type lookup_decision =
  | Live_hit of handle
  | Negative_hit
  | Join_inflight of inflight_slot
  | Leader of inflight_slot

let lookup_or_begin_inflight ~key ~now_s ~margin_s =
  with_cache_lock (fun () ->
    let live_hit =
      match Hashtbl.find_opt entries key with
      | Some entry when entry.expires_at_s -. now_s > margin_s ->
        Some { key; resource_name = entry.resource_name }
      | Some _ ->
        Hashtbl.remove entries key;
        None
      | None -> None
    in
    match live_hit with
    | Some handle -> Live_hit handle
    | None ->
      let negative_hit =
        match Hashtbl.find_opt negative_entries key with
        | Some neg when Float.compare now_s neg.neg_expires_at_s < 0 -> true
        | Some _ ->
          Hashtbl.remove negative_entries key;
          false
        | None -> false
      in
      if negative_hit
      then Negative_hit
      else (
        match Hashtbl.find_opt in_flight key with
        | Some slot -> Join_inflight slot
        | None ->
          let promise, resolver = Eio.Promise.create () in
          let slot =
            { promise
            ; resolver
            ; os_cond = Stdlib.Condition.create ()
            ; done_ = false
            ; result = None
            ; auth_invalidated = false
            }
          in
          Hashtbl.replace in_flight key slot;
          Leader slot))
;;

let store_entry ~key ~resource_name ~expires_at_s =
  with_cache_lock (fun () ->
    Hashtbl.remove negative_entries key;
    if (not (Hashtbl.mem entries key)) && Hashtbl.length entries >= max_cached_entries
    then (
      let oldest =
        Hashtbl.fold
          (fun k v acc ->
             match acc with
             | None -> Some (k, v.expires_at_s)
             | Some (_, best_exp) when Float.compare v.expires_at_s best_exp < 0 ->
               Some (k, v.expires_at_s)
             | Some _ -> acc)
          entries
          None
      in
      Option.iter (fun (oldest_key, _) -> Hashtbl.remove entries oldest_key) oldest);
    Hashtbl.replace entries key { resource_name; expires_at_s })
;;

let store_negative_entry ~key ~expires_at_s =
  with_cache_lock (fun () ->
    Hashtbl.remove entries key;
    if (not (Hashtbl.mem negative_entries key))
       && Hashtbl.length negative_entries >= max_negative_entries
    then (
      let oldest =
        Hashtbl.fold
          (fun k v acc ->
             match acc with
             | None -> Some (k, v.neg_expires_at_s)
             | Some (_, best_exp) when Float.compare v.neg_expires_at_s best_exp < 0 ->
               Some (k, v.neg_expires_at_s)
             | Some _ -> acc)
          negative_entries
          None
      in
      Option.iter
        (fun (oldest_key, _) -> Hashtbl.remove negative_entries oldest_key)
        oldest);
    Hashtbl.replace negative_entries key { neg_expires_at_s = expires_at_s })
;;

let evict_live_entry ~key =
  with_cache_lock (fun () -> Hashtbl.remove entries key)
;;

let is_permanent_negative_cache_status status =
  status >= 400
  && status < 500
  && status <> 401
  && status <> 403
  && status <> 408
  && status <> 429
  && status <> 499
;;

let await_inflight
      ?clock
      ?on_auth_invalidated
      ~effective_timeout_s
      (slot : inflight_slot)
  : handle option
  =
  let res, auth_invalidated =
    if in_eio_fiber ()
    then (
      let r =
        match clock, effective_timeout_s with
        | Some c, Some t when Float.is_finite t && Float.compare t 0.0 > 0 ->
          (match Under_deadline.run c t (fun () -> Eio.Promise.await slot.promise) with
           | Ok result -> result
           | Error `Timeout -> None)
        | Some _, Some _ | Some _, None | None, (Some _ | None) ->
          Eio.Promise.await slot.promise
      in
      let invalidated = with_cache_lock (fun () -> slot.auth_invalidated) in
      r, invalidated)
    else
      with_cache_lock (fun () ->
        while not slot.done_ do
          Stdlib.Condition.wait slot.os_cond cache_mu
        done;
        slot.result, slot.auth_invalidated)
  in
  if auth_invalidated then Option.iter (fun cb -> cb ()) on_auth_invalidated;
  res
;;

let parse_created_resource_name body =
  try
    let open Yojson.Safe.Util in
    match
      Json_util.from_string_bounded_exn body |> member "name" |> to_string_option
    with
    | Some name when not (Api_common.string_is_blank name) -> Some (String.trim name)
    | Some _ | None -> None
  with
  | Yojson.Json_error _ | Yojson.Safe.Util.Type_error _ -> None
;;

let describe_http_error = function
  | Http_client.HttpError { code; _ } -> Printf.sprintf "HTTP %d" code
  | Http_client.NetworkError { message; _ } -> "network_error: " ^ message
  | Http_client.Connect_failed { message; _ } -> "connect_failed: " ^ message
  | Http_client.TimeoutError { message; _ } -> "timeout: " ^ message
  | Http_client.AcceptRejected { reason } -> "accept_rejected: " ^ reason
  | Http_client.ProviderTerminal { message; _ } -> "provider_terminal: " ^ message
  | Http_client.ProviderFailure { message; _ } -> "provider_failure: " ^ message
;;

let resolve_or_create
      ~net
      ?clock
      ?timeout_s
      ?connection_cache
      ?(min_prefix_bytes = default_min_prefix_bytes)
      ?(negative_ttl_s = default_negative_ttl_s)
      ?on_auth_invalidated
      ~(config : Provider_config.t)
      ~auth_headers
      ~ttl_s
      ~(prefix : Backend_gemini.cacheable_prefix)
      ()
  =
  if ttl_s <= 0 || prefix_byte_size prefix < min_prefix_bytes
  then None
  else (
    let effective_timeout_s =
      match clock, timeout_s, config.connect_timeout_s with
      | Some _, Some t, _ -> Some t
      | Some _, None, Some t -> Some t
      | Some _, None, None
      | None, (Some _ | None), (Some _ | None) -> None
    in
    let timeout_budget_exhausted =
      match effective_timeout_s with
      | Some t when (not (Float.is_finite t)) || Float.compare t 0.0 <= 0 -> true
      | Some _ | None -> false
    in
    let key = prefix_key ~auth_headers ~config ~prefix () in
    let now_s = current_time_s ?clock () in
    let margin_s = refresh_margin_s ~ttl_s in
    if timeout_budget_exhausted
    then (
      (* Even with zero remaining HTTP budget, a warm local hit still avoids
         network I/O; otherwise skip creation immediately. *)
      with_cache_lock (fun () ->
        match Hashtbl.find_opt entries key with
        | Some entry when entry.expires_at_s -. now_s > margin_s ->
          Some { key; resource_name = entry.resource_name }
        | Some _ | None -> None))
    else (
      match lookup_or_begin_inflight ~key ~now_s ~margin_s with
      | Live_hit hit -> Some hit
      | Negative_hit -> None
      | Join_inflight slot ->
        await_inflight ?clock ?on_auth_invalidated ~effective_timeout_s slot
      | Leader slot ->
        let outcome = ref None in
        let auth_invalidated = ref false in
        let finish () =
          (* Pure synchronous cleanup: safe inside [Fun.protect] even on
             [Eio.Cancel.Cancelled]. Never performs yielding Eio effects. *)
          let should_resolve =
            with_cache_lock (fun () ->
              if slot.done_
              then false
              else (
                (match Hashtbl.find_opt in_flight key with
                 | Some cur when cur == slot -> Hashtbl.remove in_flight key
                 | Some _ | None -> ());
                slot.result <- !outcome;
                slot.auth_invalidated <- !auth_invalidated;
                slot.done_ <- true;
                Stdlib.Condition.broadcast slot.os_cond;
                true))
          in
          if should_resolve
          then ignore (Eio.Promise.try_resolve slot.resolver !outcome : bool)
        in
        let res =
          Fun.protect ~finally:finish (fun () ->
            if not (in_eio_fiber ())
            then (
              Diag.warn
                "gemini_context_cache"
                "skipping explicit cachedContents creation outside Eio context for \
                 model=%s; falling back to implicit caching"
                config.model_id;
              None)
            else (
              let url = cached_contents_url ~base_url:config.base_url in
              let body =
                build_create_body
                  ~base_url:config.base_url
                  ~model_id:config.model_id
                  ~ttl_s
                  ~prefix
                  ()
              in
              let merged_headers =
                Provider_config.effective_request_headers config @ auth_headers
              in
              let has_content_type =
                List.exists
                  (fun (k, _) ->
                     String.equal (String.lowercase_ascii (String.trim k)) "content-type")
                  merged_headers
              in
              let headers =
                if has_content_type
                then merged_headers
                else ("Content-Type", "application/json") :: merged_headers
              in
              let post_result =
                Eio.Switch.run (fun create_sw ->
                  Http_client.post_sync
                    ?cache:connection_cache
                    ?clock
                    ?timeout_s:effective_timeout_s
                    ~sw:create_sw
                    ~net
                    ~url
                    ~headers
                    ~body
                    ())
              in
              let res =
                match post_result with
                | Error err ->
                  Diag.warn
                    "gemini_context_cache"
                    "explicit cachedContents creation failed for model=%s (%s); falling \
                     back to implicit caching"
                    config.model_id
                    (describe_http_error err);
                  None
                | Ok resp ->
                  if Http_client.is_success_status resp.status
                  then (
                    match parse_created_resource_name resp.body with
                    | Some resource_name ->
                      let expires_at_s = current_time_s ?clock () +. float_of_int ttl_s in
                      store_entry ~key ~resource_name ~expires_at_s;
                      Some { key; resource_name }
                    | None ->
                      Diag.warn
                        "gemini_context_cache"
                        "explicit cachedContents HTTP %d response omitted valid resource \
                         name for model=%s; falling back to implicit caching"
                        resp.status
                        config.model_id;
                      None)
                  else (
                    if resp.status = 401
                    then (
                      evict_live_entry ~key;
                      if Provider_config.invalidate_credential config
                      then auth_invalidated := true)
                    else if resp.status = 403
                    then evict_live_entry ~key
                    else if is_permanent_negative_cache_status resp.status
                            && Float.is_finite negative_ttl_s
                            && Float.compare negative_ttl_s 0.0 > 0
                    then
                      store_negative_entry
                        ~key
                        ~expires_at_s:(current_time_s ?clock () +. negative_ttl_s);
                    Diag.warn
                      "gemini_context_cache"
                      "explicit cachedContents HTTP %d for model=%s; falling back to \
                       implicit caching"
                      resp.status
                      config.model_id;
                    None)
              in
              outcome := res;
              res))
        in
        if !auth_invalidated then Option.iter (fun cb -> cb ()) on_auth_invalidated;
        res))
;;

let mentions_cached_content text =
  let lower = String.lowercase_ascii text in
  Agent_core_strings.contains_substring ~haystack:lower ~needle:"cachedcontent"
  || Agent_core_strings.contains_substring ~haystack:lower ~needle:"cached_content"
  || Agent_core_strings.contains_substring ~haystack:lower ~needle:"cached content"
;;

let inspect_rpc_fields err_obj =
  let has_details, detail_mentions =
    match List.assoc_opt "details" err_obj with
    | Some (`List items) ->
      ( true
      , List.exists
          (function
            | `Assoc d ->
              (match List.assoc_opt "reason" d with
               | Some (`String r) when mentions_cached_content r -> true
               | Some (`String _ | `Assoc _ | `List _ | `Int _ | `Intlit _ | `Float _ | `Bool _ | `Null)
               | None ->
                 (match List.assoc_opt "fieldViolations" d with
                  | Some (`List fvs) ->
                    List.exists
                      (function
                        | `Assoc fv ->
                          let field_hit =
                            match List.assoc_opt "field" fv with
                            | Some (`String f) -> mentions_cached_content f
                            | Some (`Assoc _ | `List _ | `Int _ | `Intlit _ | `Float _ | `Bool _ | `Null)
                            | None -> false
                          in
                          let desc_hit =
                            match List.assoc_opt "description" fv with
                            | Some (`String desc) -> mentions_cached_content desc
                            | Some (`Assoc _ | `List _ | `Int _ | `Intlit _ | `Float _ | `Bool _ | `Null)
                            | None -> false
                          in
                          field_hit || desc_hit
                        | `List _ | `String _ | `Int _ | `Intlit _ | `Float _ | `Bool _ | `Null ->
                          false)
                      fvs
                  | Some (`Assoc _ | `String _ | `Int _ | `Intlit _ | `Float _ | `Bool _ | `Null)
                  | None -> false))
            | `List _ | `String _ | `Int _ | `Intlit _ | `Float _ | `Bool _ | `Null -> false)
          items )
    | Some (`Assoc _ | `String _ | `Int _ | `Intlit _ | `Float _ | `Bool _ | `Null)
    | None -> false, false
  in
  let has_msg, msg_mentions =
    match List.assoc_opt "message" err_obj with
    | Some (`String msg) -> true, mentions_cached_content msg
    | Some (`Assoc _ | `List _ | `Int _ | `Intlit _ | `Float _ | `Bool _ | `Null)
    | None -> false, false
  in
  if has_details || has_msg then Some (detail_mentions || msg_mentions) else None
;;

let structured_rpc_cached_content_of_object fields =
  match List.assoc_opt "error" fields with
  | Some (`String err_str) -> Some (mentions_cached_content err_str)
  | Some (`Assoc inner) -> inspect_rpc_fields inner
  | Some (`List _ | `Int _ | `Intlit _ | `Float _ | `Bool _ | `Null) | None ->
    inspect_rpc_fields fields
;;

let structured_rpc_cached_content_error body =
  match Json_util.from_string_bounded body with
  | Error _ -> None
  | Ok (`Assoc fields) -> structured_rpc_cached_content_of_object fields
  | Ok (`List items) ->
    List.fold_left
      (fun acc item ->
         match acc with
         | Some true -> Some true
         | Some false | None ->
           (match item with
            | `Assoc fields ->
              (match structured_rpc_cached_content_of_object fields with
               | Some true -> Some true
               | Some false -> Some false
               | None -> acc)
            | `List _ | `String _ | `Int _ | `Intlit _ | `Float _ | `Bool _ | `Null -> acc))
      None
      (List.take 8 items)
  | Ok (`String _ | `Int _ | `Intlit _ | `Float _ | `Bool _ | `Null) -> None
;;

let is_cached_content_error (err : Http_client.http_error) : bool =
  match err with
  | Http_client.HttpError { code = 404; _ } -> true
  | Http_client.HttpError { code = 400 | 403; body = Http_client.Received body; _ } ->
    (match structured_rpc_cached_content_error body with
     | Some matched -> matched
     | None -> mentions_cached_content body)
  | Http_client.HttpError
      { code = _
      ; body = Http_client.Received _ | Http_client.Not_received_in_window
      ; retry_after_header = _
      }
  | Http_client.NetworkError _
  | Http_client.Connect_failed _
  | Http_client.TimeoutError _
  | Http_client.AcceptRejected _
  | Http_client.ProviderTerminal _
  | Http_client.ProviderFailure _ -> false
;;
