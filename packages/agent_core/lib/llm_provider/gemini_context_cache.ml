(* See gemini_context_cache.mli for module rationale. *)

(* Gemini explicit context caching enforces a minimum cached token floor
   (1024-2048 tokens depending on model family); 4096 bytes of JSON/text is a
   conservative lower bound so tiny prefixes stay on implicit caching. *)
let default_min_prefix_bytes = 4096
let max_cached_entries = 256
let max_refresh_margin_s = 60.0

type handle =
  { key : string
  ; resource_name : string
  }

type cache_entry =
  { resource_name : string
  ; expires_at_s : float
  }

let cache_mu = Mutex.create ()
let entries : (string, cache_entry) Hashtbl.t = Hashtbl.create 32

let with_cache_lock f = Mutex.protect cache_mu f

let clear_for_tests () =
  with_cache_lock (fun () -> Hashtbl.clear entries)
;;

let invalidate ~key =
  with_cache_lock (fun () -> Hashtbl.remove entries key)
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

let cached_contents_url ~base_url =
  strip_trailing_slashes base_url ^ "/cachedContents"
;;

let model_resource_name model_id =
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

let prefix_key ~(config : Provider_config.t) ~(prefix : Backend_gemini.cacheable_prefix) =
  let key_fp =
    if Secret.is_empty config.api_key
    then "no-key"
    else Secret.fingerprint config.api_key
  in
  let canonical =
    `Assoc
      ([ "base_url", `String (strip_trailing_slashes config.base_url)
       ; "key_fp", `String key_fp
       ; "model_id", `String (model_resource_name config.model_id)
       ]
       @ prefix_components prefix)
    |> Yojson.Safe.to_string
  in
  Agent_core_sha256.(digest_string canonical |> to_hex)
;;

let build_create_body ~model_id ~ttl_s ~(prefix : Backend_gemini.cacheable_prefix) =
  let fields =
    [ "model", `String (model_resource_name model_id)
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

let lookup_live ~key ~now_s ~margin_s =
  with_cache_lock (fun () ->
    match Hashtbl.find_opt entries key with
    | Some entry when entry.expires_at_s -. now_s > margin_s ->
      Some { key; resource_name = entry.resource_name }
    | Some _ ->
      Hashtbl.remove entries key;
      None
    | None -> None)
;;

let store_entry ~key ~resource_name ~expires_at_s =
  with_cache_lock (fun () ->
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

let parse_created_resource_name body =
  try
    let open Yojson.Safe.Util in
    match Yojson.Safe.from_string body |> member "name" |> to_string_option with
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
      ~sw
      ~net
      ?clock
      ?connection_cache
      ?(min_prefix_bytes = default_min_prefix_bytes)
      ~(config : Provider_config.t)
      ~auth_headers
      ~ttl_s
      ~(prefix : Backend_gemini.cacheable_prefix)
      ()
  =
  if ttl_s <= 0 || prefix_byte_size prefix < min_prefix_bytes
  then None
  else (
    let key = prefix_key ~config ~prefix in
    let now_s = current_time_s ?clock () in
    let margin_s = refresh_margin_s ~ttl_s in
    match lookup_live ~key ~now_s ~margin_s with
    | Some _ as hit -> hit
    | None ->
      let url = cached_contents_url ~base_url:config.base_url in
      let body = build_create_body ~model_id:config.model_id ~ttl_s ~prefix in
      let headers = ("Content-Type", "application/json") :: auth_headers in
      let timeout_s =
        match clock, config.connect_timeout_s with
        | Some _, Some t -> Some t
        | (Some _ | None), None | None, Some _ -> None
      in
      match
        Http_client.post_sync
          ?cache:connection_cache
          ?clock
          ?timeout_s
          ~sw
          ~net
          ~url
          ~headers
          ~body
          ()
      with
      | Error err ->
        Diag.warn
          "gemini_context_cache"
          "explicit cachedContents creation failed for model=%s (%s); falling back to \
           implicit caching"
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
              "explicit cachedContents HTTP %d response omitted valid resource name for \
               model=%s; falling back to implicit caching"
              resp.status
              config.model_id;
            None)
        else (
          Diag.warn
            "gemini_context_cache"
            "explicit cachedContents HTTP %d for model=%s; falling back to implicit caching"
            resp.status
            config.model_id;
          None))
;;

let is_cached_content_error (err : Http_client.http_error) : bool =
  match err with
  | Http_client.HttpError { code = 404; _ } -> true
  | Http_client.HttpError { code = 400; body = Http_client.Received body; _ } ->
    let lower = String.lowercase_ascii body in
    Agent_core_strings.contains_substring ~haystack:lower ~needle:"cachedcontent"
    || Agent_core_strings.contains_substring ~haystack:lower ~needle:"cached_content"
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
