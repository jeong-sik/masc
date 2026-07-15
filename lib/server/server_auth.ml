
open Masc_domain
open Server_utils
open Result.Syntax

let trim_opt = Env_config_core.trim_opt

let configured_bind_host () =
  Env_config_core.masc_host ()

let ipaddr_is_loopback = function
  | Ipaddr.V4 addr ->
      let octets = Ipaddr.V4.to_octets addr in
      String.length octets = 4 && Char.code octets.[0] = 127
  | Ipaddr.V6 addr ->
      Ipaddr.V6.compare addr Ipaddr.V6.localhost = 0

let ipaddr_is_unspecified = function
  | Ipaddr.V4 addr -> Ipaddr.V4.compare addr Ipaddr.V4.any = 0
  | Ipaddr.V6 addr -> Ipaddr.V6.compare addr Ipaddr.V6.unspecified = 0

let is_loopback_host = Masc_network_defaults.is_loopback_host

let is_unspecified_host host =
  match Ipaddr.of_string (String.trim host) with
  | Ok ip -> ipaddr_is_unspecified ip
  | Error _ -> false

let base_url_has_non_loopback_host () =
  match Env_config_core.masc_http_base_url_result () with
  | Error _ -> false  (* no base URL configured — defer to bind-host check *)
  | Ok url -> (
      match Uri.host (Uri.of_string url) with
      | None -> true  (* fail-closed: unparseable host → treat as non-local *)
      | Some host -> not (is_loopback_host host))

let http_auth_strict_enabled () =
  Env_config.Transport.http_auth_strict_env_enabled ()
  || not (is_loopback_host (configured_bind_host ()))
  || base_url_has_non_loopback_host ()

let http_auth_bind_host () =
  configured_bind_host ()

let http_auth_bind_is_loopback () =
  is_loopback_host (configured_bind_host ())

let strict_http_auth_error endpoint =
  Printf.sprintf
    "%s requires workspace auth enabled with require_token=true when server is \
     bound to a non-loopback host or MASC_HTTP_BASE_URL points to a public address."
    endpoint

let ensure_strict_http_token_auth ~endpoint auth_config =
  if not (http_auth_strict_enabled ()) then
    Ok auth_config
  else if not auth_config.Masc_domain.enabled then
    Error (strict_http_auth_error endpoint)
  else if not auth_config.require_token then
    Error (strict_http_auth_error endpoint)
  else
    Ok auth_config

let bearer_token_from_header value =
  let prefix_len = 7 in (* String.length "Bearer " *)
  if String.length value > prefix_len
     && String_util.starts_with_ci ~prefix:"Bearer " value
  then Some (String.sub value prefix_len (String.length value - prefix_len))
  else None

let authorization_header_name = "authorization"
let internal_token_header_name = "x-masc-internal-token"

let auth_token_from_request request =
  match
    Option.bind
      (Httpun.Headers.get request.Httpun.Request.headers authorization_header_name)
      bearer_token_from_header
  with
  | Some _ as token -> token
  | None ->
      trim_opt
        (Httpun.Headers.get request.Httpun.Request.headers internal_token_header_name)

let request_carries_auth_credential request =
  match
    ( Httpun.Headers.get request.Httpun.Request.headers authorization_header_name
    , Httpun.Headers.get request.Httpun.Request.headers internal_token_header_name )
  with
  | None, None -> false
  | None, Some _ | Some _, None | Some _, Some _ -> true

let observer_sse_query_token_from_request request =
  let path = Http_server_eio.Request.path request in
  let observer_stream_requested =
    match query_param request "sse_kind" with
    | Some raw ->
        String.equal "observer" (String.lowercase_ascii (String.trim raw))
    | None -> false
  in
  match request.Httpun.Request.meth with
  | `GET
    when (observer_stream_requested && String.equal path "/mcp")
         || String.equal path "/events/presence"
         || String.equal path "/api/v1/ide/cursors/stream" ->
      trim_opt (query_param request "token")
  | _ -> None

let observer_sse_auth_token_from_request request =
  match auth_token_from_request request with
  | Some _ as token -> token
  | None -> observer_sse_query_token_from_request request

let agent_from_request request =
  let hdr key = Httpun.Headers.get request.Httpun.Request.headers key in
  let qp key = query_param request key in
  let first_some xs = List.find_map Fun.id xs in
  first_some [ hdr "x-gate-agent"; hdr "x-masc-agent"; hdr "x-masc-agent-name"; qp "agent"; qp "agent_name" ]
  |> Option.map Uri.pct_decode

let strip_prefix ~prefix value =
  let prefix_len = String.length prefix in
  if String.length value > prefix_len
     && String.starts_with ~prefix value
  then
    String.sub value prefix_len (String.length value - prefix_len)
  else value

let strip_suffix ~suffix value =
  let suffix_len = String.length suffix in
  let value_len = String.length value in
  if value_len > suffix_len
     && String.ends_with ~suffix value
  then
    String.sub value 0 (value_len - suffix_len)
  else value

let internal_keeper_agent_from_request request =
  match Httpun.Headers.get request.Httpun.Request.headers "x-masc-keeper-name" with
  | None -> None
  | Some raw ->
      let normalized =
        raw
        |> Uri.pct_decode
        |> String.trim
        |> String.lowercase_ascii
        |> strip_prefix ~prefix:"keeper-"
        |> strip_suffix ~suffix:"-agent"
      in
      if normalized = ""
      then None
      else Some (Printf.sprintf "keeper-%s-agent" normalized)

let resolve_agent_name_for_auth_raw ~base_path request ~token :
    (string option, Masc_domain.masc_error) result =
  match token with
  | Some t when Auth.verify_internal_keeper_token base_path ~token:t -> (
      match internal_keeper_agent_from_request request with
      | Some agent_name -> Ok (Some agent_name)
      | None ->
          Error
            (Masc_domain.Auth
               (Masc_domain.Auth_error.Unauthorized
                  { reason = Missing_token
                  ; message = "Internal keeper auth requires x-masc-keeper-name header."
                  })))
  | Some t ->
      let+ agent_name = Auth.resolve_agent_from_token base_path ~token:t in
      Some agent_name
  | None -> (
      match agent_from_request request with
      | Some raw when String.trim raw <> "" -> Ok (Some (String.trim raw))
      | _ -> Ok None)

(** Verify Bearer token for MCP endpoints *)
let verify_mcp_auth ~base_path request =
  let auth_config = Auth.load_auth_config base_path in
  let* auth_config = ensure_strict_http_token_auth ~endpoint:"/mcp" auth_config in
  if not auth_config.Masc_domain.enabled then
    Ok None  (* Auth disabled - allow all *)
  else
    match auth_token_from_request request with
    | None when not auth_config.require_token ->
        Ok None  (* Token not required *)
    | None ->
        Error
          "Authentication required. Use 'Authorization: Bearer <token>' header."
    | Some token -> (
        let* agent_name =
          resolve_agent_name_for_auth_raw ~base_path request ~token:(Some token)
          |> Result.map_error Masc_domain.masc_error_to_string
        in
        match agent_name with
        | None ->
            (* Fail-closed: dead branch today (resolver:154-157 returns
               [Ok (Some _)] or [Error] for [Some token]) but kept
               explicit so a future [Anonymous] case cannot silently
               rewrite to "dashboard". Spec:
               [specs/auth/AuthIdentityFSM.tla] invariant
               [NoSilentRewrite] (I2). *)
            Error
              "Authentication required. Bearer token did not resolve to \
               any agent."
        | Some agent_name ->
            Auth.check_permission base_path ~agent_name ~token:(Some token)
              ~permission:Masc_domain.CanReadState
            |> Result.map_error Masc_domain.masc_error_to_string
            |> Result.map (fun () -> None))

let verify_mcp_observer_stream_auth ~base_path request =
  let auth_config = Auth.load_auth_config base_path in
  let* auth_config = ensure_strict_http_token_auth ~endpoint:"/mcp" auth_config in
  if not auth_config.Masc_domain.enabled then
    Ok None
  else
    match observer_sse_auth_token_from_request request with
    | None when not auth_config.require_token ->
        Ok None
    | None ->
        Error
          "Authentication required. Use 'Authorization: Bearer <token>' header \
           or 'token' query param for the observer/presence/cursor SSE stream."
    | Some token -> (
        let* agent_name =
          resolve_agent_name_for_auth_raw ~base_path request ~token:(Some token)
          |> Result.map_error Masc_domain.masc_error_to_string
        in
        match agent_name with
        | None ->
            (* Fail-closed: see verify_mcp_auth above. *)
            Error
              "Authentication required. Bearer token did not resolve to \
               any agent."
        | Some agent_name ->
            Auth.check_permission base_path ~agent_name ~token:(Some token)
              ~permission:Masc_domain.CanReadState
            |> Result.map_error Masc_domain.masc_error_to_string
            |> Result.map (fun () -> None))

let verify_operator_mcp_auth ~base_path request =
  let auth_config = Auth.load_auth_config base_path in
  if not auth_config.Masc_domain.enabled then
    Error
      "/mcp/operator requires workspace auth enabled with require_token=true."
  else if not auth_config.require_token then
    Error "/mcp/operator requires bearer token auth (require_token=true)."
  else
    match auth_token_from_request request with
    | None ->
        Error "Authentication required. Use 'Authorization: Bearer <token>' header."
    | Some token -> (
        let* agent_name =
          resolve_agent_name_for_auth_raw ~base_path request ~token:(Some token)
          |> Result.map_error Masc_domain.masc_error_to_string
        in
        match agent_name with
        | None ->
            (* Fail-closed: see verify_mcp_auth above. *)
            Error
              "Authentication required. Bearer token did not resolve to \
               any agent."
        | Some agent_name ->
            Auth.check_permission base_path ~agent_name ~token:(Some token)
              ~permission:Masc_domain.CanAdmin
            |> Result.map_error Masc_domain.masc_error_to_string
            |> Result.map (fun () -> None))

let request_actor_hint request =
  match agent_from_request request with
  | Some raw ->
      let agent_name = String.trim raw in
      if String.equal agent_name "" then None else Some agent_name
  | None -> None

let sanitize_dashboard_actor_name raw =
  let value = String.trim raw in
  let buf = Buffer.create (String.length value) in
  String.iter
    (fun c ->
      match c with
      | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' | '-' ->
          Buffer.add_char buf c
      | _ -> ())
    value;
  Buffer.contents buf

(* Consolidates the two prior [silent:dashboard_actor_fallback] warn sites
   (Ok None / Error err arms in [dashboard_actor_for_request]) onto a single
   helper. The message rendering and otel_metric_store labels are owned by
   [Auth_error_kind] so the contract is round-tripped through a typed
   record rather than two parallel inline format strings.

   Log dedup: a stale dashboard token triggers this path on *every* HTTP
   request the browser makes.  Without a cooldown, 140+ identical WARN
   lines/day accumulate for the same token hash prefix.  The Otel_metric_store
   counter is always incremented (metrics remain accurate); the log line
   is emitted at most once per [warn_cooldown_sec] per token prefix. *)
let warn_cooldown_sec = 300.0

(* Ceiling on distinct token-hash prefixes retained for log dedup. The prefix
   is derived from client bearer tokens (16^8 keyspace), so without a cap the
   table grows with every rotated/invalid token over process lifetime. The
   cooldown gates log frequency per prefix, not table size. *)
let stale_token_warn_log_max_entries = 1024

let stale_token_warn_log : (string, float) Hashtbl.t = Hashtbl.create 16
let stale_token_warn_mu = Eio.Mutex.create ()

let record_dashboard_actor_fallback
    (fb : Auth_error_kind.dashboard_actor_fallback) =
  let now = Time_compat.now () in
  let should_log =
    Eio.Mutex.use_ro stale_token_warn_mu @@ fun () ->
    match Hashtbl.find_opt stale_token_warn_log fb.token_hash_prefix with
    | Some last_ts -> now -. last_ts >= warn_cooldown_sec
    | None -> true
  in
  if should_log then begin
    Eio.Mutex.use_rw ~protect:true stale_token_warn_mu @@ fun () ->
    (* Re-check under the write lock; another fiber may have just logged. *)
    let really_should_log =
      match Hashtbl.find_opt stale_token_warn_log fb.token_hash_prefix with
      | Some last_ts -> now -. last_ts >= warn_cooldown_sec
      | None -> true
    in
    if really_should_log then (
      (* Bound the dedup table before inserting a new prefix. Guard on absence
         so refreshing an existing prefix after cooldown does not evict an
         unrelated entry. Reuses the same helper as the dashboard caches. *)
      (if not (Hashtbl.mem stale_token_warn_log fb.token_hash_prefix) then
         Server_utils.evict_oldest_if_full
           ~max_entries:stale_token_warn_log_max_entries ~age_of:Fun.id
           stale_token_warn_log);
      Hashtbl.replace stale_token_warn_log fb.token_hash_prefix now;
      Log.Auth.warn "%s"
        (Auth_error_kind.dashboard_actor_fallback_log_message fb));
  end;
  Otel_metric_store.inc_counter
    Otel_metric_store.metric_silent_dashboard_actor_fallback
    ~labels:(Auth_error_kind.dashboard_actor_fallback_metric_labels fb)
    ()

(* Exposed for testing: current size of the dedup table, used to assert the
   bound holds under churn. *)
let stale_token_warn_log_entry_count () =
  Eio.Mutex.use_ro stale_token_warn_mu @@ fun () ->
  Hashtbl.length stale_token_warn_log

let dashboard_actor_for_request ~base_path request =
  match auth_token_from_request request with
  | Some token -> (
      (* First 8 hex chars of the bearer token's SHA-256. Lets operators
         correlate a token-mismatch fallback with the keeper credential
         that holds the matching hash (see [auth.ml:677] credential
         storage). The hash itself is one-way; the prefix alone is
         insufficient to reconstruct the token but unique enough to
         pinpoint a specific credential rotation event in production
         logs (2026-04-27 incident: same hash prefix observed firing
         twice in the same second, masking which keeper was affected). *)
      let token_hash_prefix =
        String.sub (Auth.sha256_hash token) 0 8
      in
      match resolve_agent_name_for_auth_raw ~base_path request ~token:(Some token) with
      | Ok (Some agent_name) -> Some agent_name
      | Ok None ->
          (* PR-I: surface the silent fallback. Token did not resolve to any
             agent, so we drop to the request actor hint (header / query
             param), masking identity drift in the HTTP transport.

             WORKAROUND-CARRYOVER: the fallback path itself is retained as a
             production safety net — the dashboard cannot go dark on token
             churn — but the two warn sites here and at the [Error] arm now
             flow through [Auth_error_kind.dashboard_actor_fallback], giving
             callers a typed handle on *why* the fallback fired. The
             string emitted by [dashboard_actor_fallback_log_message] is
             byte-equivalent to the prior inline format so otel_metric_store log
             alerts keyed on the literal prefix continue to fire.
             Reference: Reverse Engineering Design Map §개선 #2. *)
          let fb : Auth_error_kind.dashboard_actor_fallback =
            { outcome = Auth_error_kind.Outcome_none; token_hash_prefix }
          in
          record_dashboard_actor_fallback fb;
          request_actor_hint request
      | Error err ->
          (* The previous warn line elided the actual error string and the
             request actor hint, leaving operators with a counter that only
             told them *something* errored — not what.  Production logs
             showed the warn firing 1–2 times/second with no diagnostic
             surface, so the WARN was loud noise without root-cause
             attribution.  Surface both the error class and the hint via
             the typed [Auth_error_kind.Outcome_error] arm — the
             [Token_mismatch] remediation tail is embedded in
             [dashboard_actor_fallback_log_message]. *)
          let fb : Auth_error_kind.dashboard_actor_fallback =
            { outcome =
                Auth_error_kind.Outcome_error
                  { err
                  ; err_kind = Auth_error_kind.classify err
                  ; actor_hint = request_actor_hint request
                  }
            ; token_hash_prefix
            }
          in
          record_dashboard_actor_fallback fb;
          request_actor_hint request)
  | None -> request_actor_hint request

let is_verified_internal_keeper_request ~base_path request =
  match auth_token_from_request request with
  | Some token when Auth.verify_internal_keeper_token base_path ~token ->
      Option.is_some (internal_keeper_agent_from_request request)
  | _ -> false

let sanitized_dashboard_actor_for_request ~base_path request =
  match dashboard_actor_for_request ~base_path request with
  | Some raw ->
      let sanitized = sanitize_dashboard_actor_name raw in
      if String.equal sanitized "" then None else Some sanitized
  | None -> None

let split_csv_nonempty raw =
  raw |> String.split_on_char ',' |> List.filter_map String_util.trim_nonempty

type browser_origin_admission =
  | Same_origin
  | Allowed_dev_origin
  | Rejected

type request_origin_admission =
  | Missing_origin
  | Single_origin of
      { origin : string
      ; admission : browser_origin_admission
      }
  | Multiple_origins
  | Malformed_origin

(* Re-reads the env var on each call so MASC_ALLOW_ANONYMOUS_MUTATIONS
   can be toggled without restarting the server process. *)
let allow_anonymous_mutations () =
  match Sys.getenv_opt "MASC_ALLOW_ANONYMOUS_MUTATIONS" with
  | Some ("1" | "true") -> true
  | _ -> false

let default_loopback_dev_mutation_origins =
  Masc_network_defaults.vite_dev_default_origins

let configured_loopback_dev_mutation_origins () =
  match Sys.getenv_opt "MASC_HTTP_DEV_MUTATION_ORIGINS" with
  | Some raw -> split_csv_nonempty raw
  | None -> default_loopback_dev_mutation_origins

let parse_configured_dev_origins () =
  let rec parse_all parsed = function
    | [] -> Ok (List.rev parsed)
    | raw :: rest ->
      (match Server_request_authority.parse_serialized_origin raw with
       | Ok origin -> parse_all (origin :: parsed) rest
       | Error `Malformed -> Error raw)
  in
  parse_all [] (configured_loopback_dev_mutation_origins ())
;;

let allowlisted_dev_origin_matches_request ~request_authority origin =
  let request_host = Server_request_authority.host request_authority in
  let origin_host = Server_request_authority.serialized_origin_host origin in
  if not (is_loopback_host request_host && is_loopback_host origin_host)
  then false
  else
    match parse_configured_dev_origins () with
    | Ok configured ->
      List.exists
        (Server_request_authority.serialized_origin_equal origin)
        configured
    | Error malformed ->
      Log.Auth.warn
        "rejecting dev Origin because MASC_HTTP_DEV_MUTATION_ORIGINS contains a malformed serialized origin: %S"
        malformed;
      false
;;

let admission_of_serialized_origin ~request_authority origin =
  if
    Server_request_authority.serialized_origin_matches_authority
      origin
      request_authority
  then Same_origin
  else if allowlisted_dev_origin_matches_request ~request_authority origin
  then Allowed_dev_origin
  else Rejected
;;

let classify_request_origin ~request_authority request =
  match Httpun.Headers.get_multi request.Httpun.Request.headers "origin" with
  | [] -> Missing_origin
  | [ raw ] ->
    (match Server_request_authority.parse_serialized_origin raw with
     | Error `Malformed -> Malformed_origin
     | Ok parsed ->
       Single_origin
         { origin = raw
         ; admission =
             admission_of_serialized_origin ~request_authority parsed
         })
  | _ -> Multiple_origins
;;

let browser_origin_matches_request_authority ~request_authority origin =
  match Server_request_authority.parse_serialized_origin origin with
  | Error `Malformed -> false
  | Ok parsed ->
    (match admission_of_serialized_origin ~request_authority parsed with
     | Same_origin | Allowed_dev_origin -> true
     | Rejected -> false)
;;

let ascii_is_whitespace = function
  | ' ' | '\t' | '\r' | '\n' -> true
  | _ -> false
;;

let serialized_origin_of_referer referer =
  if
    String.equal referer ""
    || not (String.equal referer (String.trim referer))
    || String.exists ascii_is_whitespace referer
  then None
  else
    let uri = Uri.of_string referer in
    match
      Uri.scheme uri |> Option.map String.lowercase_ascii,
      Uri.userinfo uri,
      Uri.host uri,
      Uri.fragment uri
    with
    | Some ("http" | "https" as scheme), None, Some host, None ->
      let rendered_host =
        match Ipaddr.V6.of_string host with
        | Ok _ -> "[" ^ host ^ "]"
        | Error _ -> host
      in
      let rendered_port =
        Option.fold ~none:"" ~some:(Printf.sprintf ":%d") (Uri.port uri)
      in
      (match
         Server_request_authority.parse_serialized_origin
           (Printf.sprintf "%s://%s%s" scheme rendered_host rendered_port)
       with
       | Ok origin -> Some origin
       | Error `Malformed -> None)
    | Some _, _, _, _ | None, _, _, _ -> None
;;

let referer_matches_request_authority ~request_authority referer =
  match serialized_origin_of_referer referer with
  | Some origin ->
    Server_request_authority.serialized_origin_matches_authority
      origin
      request_authority
  | None -> false
;;

(* Browsers omit Origin for some same-origin requests. Referer is parsed by a
   separate URL parser because it legitimately carries a path/query; it never
   goes through the serialized-Origin grammar. The admitted request authority
   is already parsed at request entry, so this path never re-reads Host. *)
let ensure_same_origin_browser_request ~request_authority request :
    (unit, Masc_domain.masc_error) result =
  match classify_request_origin ~request_authority request with
  | Missing_origin ->
    (match Httpun.Headers.get_multi request.Httpun.Request.headers "referer" with
     | [ referer ]
       when referer_matches_request_authority ~request_authority referer ->
       Ok ()
     | [] | [ _ ] | _ :: _ :: _ ->
       if allow_anonymous_mutations () then Ok ()
       else
         Error (Masc_domain.Auth (Masc_domain.Auth_error.Unauthorized
           { reason = Missing_token
           ; message = "Authentication required: provide a bearer token or Origin header. \
                        Set MASC_ALLOW_ANONYMOUS_MUTATIONS=true for local development."
           })))
  | Single_origin
      { admission = (Same_origin | Allowed_dev_origin); _ } ->
    Ok ()
  | Single_origin { origin; admission = Rejected } ->
    Log.Auth.debug
      "same-origin check failed: origin=%S scheme=%s authority=%S trust=%s"
      origin
      (Server_request_authority.scheme request_authority
       |> Server_request_authority.scheme_to_string)
      (Server_request_authority.rendered request_authority)
      (match Server_request_authority.trust_class request_authority with
       | Server_request_authority.Configured_bind -> "configured_bind"
       | Server_request_authority.Explicit_trusted_host ->
         "explicit_trusted_host");
    Error
      (Masc_domain.Auth
         (Masc_domain.Auth_error.Forbidden
            { agent = "browser"; action = "cross-origin HTTP mutation" }))
  | Multiple_origins | Malformed_origin ->
    Error
      (Masc_domain.Auth
         (Masc_domain.Auth_error.Forbidden
            { agent = "browser"; action = "malformed Origin header" }))

(* Mirrors [Masc_error.code] (the typed SSOT in lib/types/masc_error.ml).
   Previously the catch-all [_ -> `Internal_server_error] silently demoted
   [RateLimitExceeded _] to 500 (should be 429), [Task/Agent (NotFound _)]
   to 500 (should be 404), and the 400-class validation errors to 500.
   Operators reading the access log could not distinguish rate limiting
   from a real server fault. The match is now exhaustive; adding a new
   [Masc_error.t] outer variant will trip Warning 8 here and force an
   explicit HTTP-status decision. *)
(* Type annotation kept row-polymorphic (no [Httpun.Status.t] ascription)
   so callers in both [server_h2_gateway] (H2.Status.t) and the Httpun
   handlers can narrow to their respective protocol enums.  The .mli
   pins the six tags this function actually returns. *)
let http_status_of_auth_error = function
  | Masc_domain.Auth
      (Masc_domain.Auth_error.Unauthorized _
      | Masc_domain.Auth_error.InvalidToken _
      | Masc_domain.Auth_error.TokenExpired _) -> `Unauthorized
  | Masc_domain.Auth (Masc_domain.Auth_error.Forbidden _) -> `Forbidden
  | Masc_domain.Task (Masc_domain.Task_error.NotFound _) -> `Not_found
  | Masc_domain.Agent (Masc_domain.Agent_error.NotFound _) -> `Not_found
  | Masc_domain.Task
      (Masc_domain.Task_error.AlreadyClaimed _
      | Masc_domain.Task_error.NotClaimed _
      | Masc_domain.Task_error.InvalidState _
      | Masc_domain.Task_error.InvalidId _) -> `Bad_request
  | Masc_domain.Agent (Masc_domain.Agent_error.InvalidName _) -> `Bad_request
  | Masc_domain.System _ -> `Bad_request
  | Masc_domain.RateLimitExceeded _ -> `Too_many_requests
  | Masc_domain.CacheError _ -> `Internal_server_error

(** Server state - initialized at startup *)
let server_state : Mcp_server.server_state option ref = ref None

(** CORS origin *)
exception Invalid_origin_header

let get_origin (request : Httpun.Request.t) =
  match Httpun.Headers.get_multi request.headers "origin" with
  | [] -> "*"
  | [ origin ] ->
    (match Server_request_authority.parse_serialized_origin origin with
     | Ok _ -> origin
     | Error `Malformed -> raise Invalid_origin_header)
  | _ -> raise Invalid_origin_header

let public_read_cors_origin_opt ~request_authority (request : Httpun.Request.t) =
  match classify_request_origin ~request_authority request with
  | Single_origin
      { origin; admission = (Same_origin | Allowed_dev_origin) } ->
    Some origin
  | Missing_origin
  | Single_origin { admission = Rejected; _ }
  | Multiple_origins
  | Malformed_origin ->
    None

(** CORS headers *)
let cors_allow_headers_value =
  "Content-Type, Accept, Origin, Authorization, Idempotency-Key, Mcp-Session-Id, \
   Mcp-Protocol-Version, Last-Event-Id, X-Gate-Agent, X-MASC-Agent, X-MASC-Agent-Name"

let cors_expose_headers_value =
  "Mcp-Session-Id, Mcp-Protocol-Version, X-RateLimit-Limit, X-RateLimit-Remaining"

let cors_headers origin =
  let base = [
    ("access-control-allow-origin", origin);
    ("access-control-allow-methods", "GET, POST, DELETE, OPTIONS");
    ("access-control-allow-headers", cors_allow_headers_value);
    ("access-control-expose-headers", cors_expose_headers_value);
    ("vary", "Origin");
  ] in
  (* CORS spec: Access-Control-Allow-Credentials must not be paired with
     wildcard "*" origin.  Only include it when reflecting a real origin. *)
  if origin <> "*" then
    ("access-control-allow-credentials", "true") :: base
  else
    base

let respond_json_with_cors ?(status = `OK) request reqd body =
  let origin = get_origin request in
  Http_server_eio.Response.json ~status ~request
    ~extra_headers:(cors_headers origin) body reqd

let respond_json_value_with_cors ?(status = `OK) request reqd value =
  let origin = get_origin request in
  Http_server_eio.Response.json_value ~status ~request
    ~extra_headers:(cors_headers origin) value reqd

let public_read_cors_headers request =
  match Httpun.Headers.get_multi request.Httpun.Request.headers "origin" with
  | [] -> [ ("vary", "Origin") ]
  | [ _ ] ->
    let request_authority = Server_request_authority.current_exn () in
    (match public_read_cors_origin_opt ~request_authority request with
     | Some origin -> cors_headers origin
     | None -> [ ("vary", "Origin") ])
  | _ -> raise Invalid_origin_header

let respond_public_read_json ?(status = `OK) request reqd body =
  Http_server_eio.Response.json ~status
    ~request ~extra_headers:(public_read_cors_headers request) body reqd

let respond_public_read_json_value ?(status = `OK) request reqd value =
  Http_server_eio.Response.json_value ~status
    ~request ~extra_headers:(public_read_cors_headers request) value reqd

(* The 401/403 body carries the typed [auth_error_code] alongside the
   human-readable [error] string. Clients (dashboard keeper stream retry
   gate) dispatch on the typed code instead of substring-matching the
   message. The code is the same SSOT mapping the dashboard shell
   summary uses ([Masc_domain.dashboard_auth_error_code]). The legacy
   [error] field is retained for human display and backward compat. *)
let auth_error_json err =
  let base = [ ("error", `String (Masc_domain.masc_error_to_string err)) ] in
  let fields =
    match Masc_domain.dashboard_auth_error_code err with
    | Some code -> base @ [ ("auth_error_code", `String code) ]
    | None -> base
  in
  Yojson.Safe.to_string (`Assoc fields)

let respond_auth_error request reqd err =
  let status = http_status_of_auth_error err in
  let origin = get_origin request in
  let body = auth_error_json err in
  let headers = Httpun.Headers.of_list (
    ("content-length", string_of_int (String.length body))
    :: cors_headers origin
  ) in
  let response = Httpun.Response.create ~headers (status :> Httpun.Status.t) in
  Httpun.Reqd.respond_with_string reqd response body

(** Respond with 429 Too Many Requests when the per-agent rate limit is
    exceeded.  Includes standard rate-limit headers and CORS so browser
    clients can inspect the response. *)
let respond_agent_rate_limited ~rl_key request reqd =
  let origin = get_origin request in
  let body = Rate_limit.too_many_agent_requests_body () in
  let rl_headers = Rate_limit.headers_agent_global ~key:rl_key in
  let headers = Httpun.Headers.of_list (
    ("content-type", "application/json") ::
    ("content-length", string_of_int (String.length body)) ::
    rl_headers @
    cors_headers origin
  ) in
  Httpun.Reqd.respond_with_string reqd
    (Httpun.Response.create ~headers `Too_many_requests) body

(** Extract a per-agent rate-limit key from the request.  Prefers the bearer
    token (keyed by a short SHA-256 prefix) over the declared agent-name
    header so that token-bearing clients cannot evade per-agent limits by
    rotating their agent-name header. *)
let agent_rl_key_of_request request =
  let token = auth_token_from_request request in
  let agent_name = agent_from_request request in
  Rate_limit.agent_key_of_token_or_name ?token ?agent_name ()

(** Check the per-agent rate limit for a request.  Returns [Ok ()] when the
    request is allowed.  Returns [Error ()] and sends a 429 response when the
    per-agent limit is exceeded.  Anonymous requests (no token, no agent
    header) are always allowed through — the per-IP limit in
    [bin/main_eio.ml:try_rate_limit_block] covers that case. *)
let check_agent_rate_limit request reqd =
  match agent_rl_key_of_request request with
  | None -> Ok ()  (* anonymous — covered by per-IP limit *)
  | Some rl_key ->
      if Rate_limit.check_agent_global ~key:rl_key then
        Ok ()
      else begin
        respond_agent_rate_limited ~rl_key request reqd;
        Error ()
      end

(** Admin-only access - requires MASC_ADMIN_TOKEN.
    Uses timing-safe comparison (XOR-based constant-time) to prevent
    timing side-channel attacks that could leak token bytes. *)
let with_admin_auth handler request reqd =
  match !server_state with
  | None -> Http_server_eio.Response.json {|{"error":"not initialized"}|} reqd
  | Some state ->
      let admin_token = Env_config_core.admin_token_opt () in
      let provided = auth_token_from_request request in
      match admin_token, provided with
      | None, _ ->
          Http_server_eio.Response.json ~status:`Forbidden
            {|{"error":"MASC_ADMIN_TOKEN not configured"}|} reqd
      | Some _, None ->
          Http_server_eio.Response.json ~status:`Unauthorized
            {|{"error":"Admin token required"}|} reqd
      | Some expected, Some given ->
          (* Constant-time comparison: always XOR max(len_a, len_b) bytes.
             Length difference is folded into the diff accumulator so both
             length and content mismatches cost the same wall-clock time. *)
          let len_a = String.length expected in
          let len_b = String.length given in
          let max_len = max len_a len_b in
          let diff = ref (len_a lxor len_b) in
          for i = 0 to max_len - 1 do
            let a = if i < len_a then Char.code expected.[i] else 0 in
            let b = if i < len_b then Char.code given.[i] else 0 in
            diff := !diff lor (a lxor b)
          done;
          if !diff = 0 then
            handler state request reqd
          else
            Http_server_eio.Response.json ~status:`Forbidden
              {|{"error":"Invalid admin token"}|} reqd

(** Public read access - no auth required (dashboard, health) *)
let is_public_read_path path =
  String.equal path "/health"
  (* Issue #8403: derive probe whitelist from Server_health_paths SSOT
     so adding/renaming a probe automatically refreshes the auth filter
     instead of leaking an auth-required probe through. *)
  || Server_health_paths.is_public path
  || String.equal path "/api/v1/gate/health"
  || String.equal path "/api/v1/gate/status"
  || String.equal path "/api/v1/gate/connectors"
  || String.equal path "/api/v1/gate/connector/status"
  || String.equal path "/api/v1/gate/events"
  || String.equal path "/"
  || String.equal path "/dashboard"
  || String.equal path "/dashboard/"
  || String.equal path "/favicon.ico"
  || String.equal path "/favicon.svg"
  || String.starts_with ~prefix:"/dashboard/" path
  || String.starts_with ~prefix:"/static/" path
  || String.starts_with ~prefix:"/graphiql/" path
  (* Tier F2 dashboard reads — multimodal artifact gallery + detail
     panel. The Bonsai dashboard issues these via [Brr_io.Fetch.url]
     with no credentials, mirroring the rest of the dashboard's
     read-only surface. Routes themselves are wrapped in
     [with_public_read] in [server_routes_http_routes_multimodal];
     this whitelist entry is what makes that wrapper actually
     public when [http_auth_strict_enabled] is on. *)
  || String.starts_with ~prefix:"/api/v1/multimodal/list" path
  || String.starts_with ~prefix:"/api/v1/multimodal/get/" path
  || String.starts_with ~prefix:"/api/v1/multimodal/provenance/" path
  (* Voice TTS audio clips: unguessable token filenames act as the
     capability, and the browser <audio> element cannot send a bearer
     token in its request headers. *)
  || String.starts_with ~prefix:"/api/v1/voice/audio/" path

let resolve_agent_name_for_auth ~base_path request ~token :
    (string option, Masc_domain.masc_error) result =
  resolve_agent_name_for_auth_raw ~base_path request ~token

let authorize_permission_request ~base_path ~permission request :
    (unit, Masc_domain.masc_error) result =
  let auth_cfg = Auth.load_auth_config base_path in
  let token = auth_token_from_request request in
  let* auth_cfg =
    ensure_strict_http_token_auth ~endpoint:"HTTP read access" auth_cfg
    |> Result.map_error (fun msg ->
          Masc_domain.Auth
            (Masc_domain.Auth_error.Unauthorized
               { reason = Generic; message = msg }))
  in
  let* agent_name_opt = resolve_agent_name_for_auth ~base_path request ~token in
  (* NDT-OK: pre-existing dashboard fallback for non-token dashboard reads.
     Token-bound requests without a resolved agent fail closed in the guard below. *)
  let agent_name = Option.value ~default:"dashboard" agent_name_opt in
  if
    auth_cfg.enabled && auth_cfg.require_token && token <> None
    && agent_name_opt = None
  then
    Error
      (Masc_domain.Auth
         (Masc_domain.Auth_error.Unauthorized
            { reason = Missing_token
            ; message =
                "Agent name required (X-Gate-Agent / X-MASC-Agent or \
                 token-bound credential)"
            }))
  else
    Auth.check_permission base_path ~agent_name ~token ~permission

let authorize_read_request ~base_path request : (unit, Masc_domain.masc_error) result =
  authorize_permission_request ~base_path ~permission:Masc_domain.CanReadState request

let authorize_tool_request_with_actor ~base_path ~tool_name ~request_authority request :
    (string, Masc_domain.masc_error) result =
  let auth_cfg = Auth.load_auth_config base_path in
  let token = auth_token_from_request request in
  let* () =
    if Option.is_some token then Ok ()
    else ensure_same_origin_browser_request ~request_authority request
  in
  let* auth_cfg =
    ensure_strict_http_token_auth
      ~endpoint:("HTTP tool access for " ^ tool_name) auth_cfg
    |> Result.map_error (fun msg ->
          Masc_domain.Auth
            (Masc_domain.Auth_error.Unauthorized
               { reason = Generic; message = msg }))
  in
  let* agent_name_opt = resolve_agent_name_for_auth ~base_path request ~token in
  (* NDT-OK: pre-existing dashboard fallback for non-token dashboard tool requests.
     Token-bound requests without a resolved agent fail closed in the guard below. *)
  let agent_name = Option.value ~default:"dashboard" agent_name_opt in
  if
    auth_cfg.enabled && auth_cfg.require_token && token <> None
    && agent_name_opt = None
  then
    Error
      (Masc_domain.Auth
         (Masc_domain.Auth_error.Unauthorized
            { reason = Missing_token
            ; message =
                "Agent name required (X-Gate-Agent / X-MASC-Agent or \
                 token-bound credential)"
            }))
  else (
    let* () = Auth.authorize_tool_v2 base_path ~agent_name ~token ~tool_name in
    Ok agent_name)

let authorize_tool_request ~base_path ~tool_name ~request_authority request :
    (unit, Masc_domain.masc_error) result =
  authorize_tool_request_with_actor
    ~base_path
    ~tool_name
    ~request_authority
    request
  |> Result.map (fun _agent_name -> ())

let authorize_token_bound_permission_request ~base_path ~permission request :
    (string, Masc_domain.masc_error) result =
  let auth_cfg = Auth.load_auth_config base_path in
  if not auth_cfg.enabled then
    Error
      (Masc_domain.Auth
         (Masc_domain.Auth_error.Unauthorized
            { reason = Missing_token
            ; message = "HTTP mutation requires workspace auth enabled with require_token=true."
            }))
  else if not auth_cfg.require_token then
    Error
      (Masc_domain.Auth
         (Masc_domain.Auth_error.Unauthorized
            { reason = Missing_token
            ; message = "HTTP mutation requires bearer token auth (require_token=true)."
            }))
  else
    match auth_token_from_request request with
    | None ->
        Error
          (Masc_domain.Auth
             (Masc_domain.Auth_error.Unauthorized
                { reason = Missing_token
                ; message =
                    "Authentication required. Use 'Authorization: Bearer <token>' header."
                }))
    | Some token ->
        let* cred = Auth.find_credential_by_token base_path ~token in
        if Masc_domain.has_permission (Auth.effective_credential_role cred) permission then
          Ok cred.agent_name
        else
          Error
            (Masc_domain.Auth
               (Masc_domain.Auth_error.Forbidden
                  { agent = cred.agent_name
                  ; action = Masc_domain.show_permission permission
                  }))

let authorize_optional_token_bound_permission_request
    ~base_path
    ~permission
    request =
  if request_carries_auth_credential request
  then
    authorize_token_bound_permission_request ~base_path ~permission request
    |> Result.map Option.some
  else Ok None

let is_dashboard_bootstrap_path path =
  String.starts_with ~prefix:"/api/v1/dashboard/" path

let not_initialized_response path =
  if is_dashboard_bootstrap_path path then
    {|{"status":"initializing","message":"Server is warming up"}|}
  else
    {|{"error":"not initialized"}|}

let rec with_public_read handler request reqd =
  let strict = http_auth_strict_enabled () in
  let path = Http_server_eio.Request.path request in
  if strict && not (is_public_read_path path) then
    with_read_auth handler request reqd
  else
    match !server_state with
    | None -> Http_server_eio.Response.json (not_initialized_response path) reqd
    | Some state -> handler state request reqd

and with_observer_sse_read_auth handler request reqd =
  let strict = http_auth_strict_enabled () in
  let path = Http_server_eio.Request.path request in
  if strict && not (is_public_read_path path) then
    match !server_state with
    | None -> Http_server_eio.Response.json (not_initialized_response path) reqd
    | Some state ->
      let base_path = (Mcp_server.workspace_config state).base_path in
      (match verify_mcp_observer_stream_auth ~base_path request with
       | Ok _ ->
         (match check_agent_rate_limit request reqd with
          | Ok () -> handler state request reqd
          | Error () -> ())
       | Error msg ->
         Http_server_eio.Response.json
           ~status:`Unauthorized
           (Yojson.Safe.to_string (`Assoc [ "error", `String msg ]))
           reqd)
  else
    with_public_read handler request reqd

and with_read_auth handler request reqd =
  match !server_state with
  | None -> Http_server_eio.Response.json {|{"error":"not initialized"}|} reqd
  | Some state ->
      let base_path = (Mcp_server.workspace_config state).base_path in
      (match authorize_read_request ~base_path request with
      | Ok () ->
          (match check_agent_rate_limit request reqd with
          | Ok () -> handler state request reqd
          | Error () -> ())
      | Error err -> respond_auth_error request reqd err)

and with_permission_auth ~permission handler request reqd =
  match !server_state with
  | None -> Http_server_eio.Response.json {|{"error":"not initialized"}|} reqd
  | Some state ->
      let base_path = (Mcp_server.workspace_config state).base_path in
      (match authorize_permission_request ~base_path ~permission request with
      | Ok () ->
          (match check_agent_rate_limit request reqd with
          | Ok () -> handler state request reqd
          | Error () -> ())
      | Error err -> respond_auth_error request reqd err)

and with_tool_auth ~tool_name handler request reqd =
  match !server_state with
  | None -> Http_server_eio.Response.json {|{"error":"not initialized"}|} reqd
  | Some state ->
      let base_path = (Mcp_server.workspace_config state).base_path in
      let request_authority = Server_request_authority.current_exn () in
      (match
         authorize_tool_request
           ~base_path
           ~tool_name
           ~request_authority
           request
       with
      | Ok () ->
          (match check_agent_rate_limit request reqd with
          | Ok () -> handler state request reqd
          | Error () -> ())
      | Error err -> respond_auth_error request reqd err)

and with_tool_actor_auth ~tool_name handler request reqd =
  match !server_state with
  | None -> Http_server_eio.Response.json {|{"error":"not initialized"}|} reqd
  | Some state ->
    let base_path = (Mcp_server.workspace_config state).base_path in
    let request_authority = Server_request_authority.current_exn () in
    (match
       authorize_tool_request_with_actor
         ~base_path
         ~tool_name
         ~request_authority
         request
     with
     | Ok agent_name ->
       (match check_agent_rate_limit request reqd with
        | Ok () -> handler state agent_name request reqd
        | Error () -> ())
     | Error err -> respond_auth_error request reqd err)

and with_token_permission_auth ~permission handler request reqd =
  match !server_state with
  | None -> Http_server_eio.Response.json {|{"error":"not initialized"}|} reqd
  | Some state ->
      let base_path = (Mcp_server.workspace_config state).base_path in
      (match authorize_token_bound_permission_request ~base_path ~permission request with
      | Ok agent_name ->
          (match check_agent_rate_limit request reqd with
          | Ok () -> handler state agent_name request reqd
          | Error () -> ())
      | Error err -> respond_auth_error request reqd err)
