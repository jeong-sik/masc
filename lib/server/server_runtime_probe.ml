open Dashboard_http_helpers

let runtime_inventory_source = "runtime.toml"


type dashboard_runtime_provider_probe =
  { runtime_id : string
  ; json : Yojson.Safe.t
  ; status : string
  ; reachable : bool option
  ; skipped : bool
  }

let take = Server_dashboard_http_runtime_info_json.take
type dashboard_runtime_probe_cache_entry =
  { probe : Yojson.Safe.t
  ; refreshed_at : float
  }

let dashboard_runtime_probe_cache : dashboard_runtime_probe_cache_entry option Atomic.t =
  Atomic.make None
;;

let dashboard_runtime_probe_cache_ttl_sec = 30.0
let dashboard_runtime_probe_force_min_refresh_sec = 10.0
(* Metadata-probe timeout. The dashboard probe hits provider metadata endpoints
   only ([/api/tags] for Ollama, [/models] for messages/chat — see
   {!dashboard_runtime_probe_url}); it never sends a completion request, so there
   is no warm-KV inference to wait for. A dead/dropping runtime therefore fails
   fast (RST) and a slow one is bounded here. 15s matched the completion-probe
   timeout and let one unreachable runtime stall the whole dashboard for the
   full window ("runtime-probe 한 번 잡히면 모든 게 다 느려짐"); 5s is a ~10x margin
   over observed metadata latency (<500ms) while cutting the worst-case stall
   by 3x. The completion-probe ([tool_local_runtime_probe]) keeps its own
   longer timeout because it does run inference.

   Caveat: this 5s is a total-request cap that also bounds remote provider
   [/models] endpoints (Messages/Chat APIs reached over the public internet),
   not just loopback Ollama. A legitimately-slow-but-alive cloud endpoint that
   the prior 15s tolerated can now be cut to [network_error]/unreachable;
   because the probe runs off the hot path and the next poll retries this
   self-heals, but the <500ms margin is evidenced for the local path only. *)
let dashboard_runtime_probe_timeout_sec = 5
(* Soft-TTL for stale-while-revalidate. A cache value is served as fresh for the
   full [dashboard_runtime_probe_cache_ttl_sec], but once its age crosses this
   threshold the request path schedules a non-blocking background refresh so the
   *next* poll (default 30s) sees a fresh value instead of a post-expiry miss.
   Set to half the TTL so a value refreshed on poll N is pre-warmed before
   poll N+1 -- this is what closes the TTL==poll-interval hit-rate-0 trap
   (cache expiry landing right at the next poll). *)
let dashboard_runtime_probe_soft_refresh_sec = 15.0
(* Concurrency cap for the parallel runtime-probe fan-out
   ([dashboard_runtime_probe_payload_json_of_runtimes]). The configured runtime
   fleet is small (a handful of providers), so this is a safety bound against
   unbounded fork rather than a tuned throughput knob; it mirrors
   [Dashboard_execution.dashboard_enrich_max_fibers] (8). *)
let dashboard_runtime_probe_max_fibers = 8
let dashboard_runtime_probe_refresh_in_flight = Atomic.make false

let dashboard_runtime_probe_runner_hook : (unit -> Yojson.Safe.t) option Atomic.t =
  Atomic.make None
;;

let dashboard_runtime_provider_http_get_hook :
  (url:string ->
   headers:(string * string) list ->
   timeout_sec:float ->
   (int * (string * string) list * string, string) result)
    option
    Atomic.t
  =
  Atomic.make None
;;

let set_dashboard_runtime_probe_runner_for_tests hook =
  Atomic.set dashboard_runtime_probe_runner_hook (Some hook)
;;

let clear_dashboard_runtime_probe_runner_for_tests () =
  Atomic.set dashboard_runtime_probe_runner_hook None
;;

let set_dashboard_runtime_provider_http_get_for_tests hook =
  Atomic.set dashboard_runtime_provider_http_get_hook (Some hook)
;;

let clear_dashboard_runtime_provider_http_get_for_tests () =
  Atomic.set dashboard_runtime_provider_http_get_hook None
;;

let clear_dashboard_runtime_probe_cache_for_tests () =
  Atomic.set dashboard_runtime_probe_cache None;
  Atomic.set dashboard_runtime_probe_refresh_in_flight false
;;

let set_dashboard_runtime_probe_cache_for_tests ~probe ~age_sec () =
  (* Seed the probe cache with a value [age_sec] seconds old so tests can drive
     the fresh / recent-window / stale branches of [dashboard_runtime_probe_http_json]
     deterministically. Unit tests have no Eio switch to fork a real background
     refresh into, so the cache must be seeded directly. The [age_sec] is
     translated to an absolute [refreshed_at] here so callers do not depend on
     [Time_compat]. *)
  Atomic.set
    dashboard_runtime_probe_cache
    (Some { probe; refreshed_at = Time_compat.now () -. age_sec })
;;

type git_upstream_status = Server_git_probe.git_upstream_status =
  { branch : string option
  ; upstream_ref : string option
  ; upstream_head_commit : string option
  ; ahead_count : int option
  ; behind_count : int option
  }


let dashboard_runtime_probe_timeout_sec_float =
  Float.of_int dashboard_runtime_probe_timeout_sec
;;

let dashboard_runtime_trim_trailing_slashes raw =
  let raw = String.trim raw in
  let rec loop idx =
    if idx < 0
    then ""
    else if Char.equal raw.[idx] '/'
    then loop (idx - 1)
    else String.sub raw 0 (idx + 1)
  in
  loop (String.length raw - 1)
;;

let dashboard_runtime_append_probe_path base ~suffix =
  let base = dashboard_runtime_trim_trailing_slashes base in
  if String.equal base "" || String.ends_with ~suffix base
  then base
  else base ^ suffix
;;

let dashboard_runtime_probe_url ~(api_format : Runtime_schema.api_format) base_url =
  match api_format with
  | Runtime_schema.Ollama_api ->
    let base = dashboard_runtime_trim_trailing_slashes base_url in
    if String.ends_with ~suffix:"/api/tags" base
    then base
    else if String.ends_with ~suffix:"/api" base
    then base ^ "/tags"
    else base ^ "/api/tags"
  | Runtime_schema.Messages_api | Runtime_schema.Chat_completions_api ->
      dashboard_runtime_append_probe_path base_url ~suffix:"/models"
;;

let dashboard_runtime_url_for_json raw =
  let uri = Uri.of_string raw in
  Uri.with_uri ~userinfo:None ~query:None ~fragment:None uri |> Uri.to_string
;;

let dashboard_runtime_http_url_valid url =
  let uri = Uri.of_string url in
  match Option.map String.lowercase_ascii (Uri.scheme uri), Uri.host uri with
  | Some ("http" | "https"), Some host when String.trim host <> "" -> true
  | _ -> false
;;

let dashboard_runtime_provider_auth_kind = function
  | None -> "none"
  | Some (Runtime_schema.Env key) -> "env:" ^ key
  | Some (Runtime_schema.File path) -> "file:" ^ path
  | Some (Runtime_schema.Inline _) -> "inline"
;;

let dashboard_runtime_header_is_auth name =
  match String.lowercase_ascii (String.trim name) with
  | "authorization" | "x-api-key" | "api-key" | "x-auth-token" -> true
  | _ -> false
;;

let dashboard_runtime_non_auth_headers (provider : Runtime_schema.provider) =
  match provider.headers with
  | None -> []
  | Some headers ->
    List.filter (fun (name, _) -> not (dashboard_runtime_header_is_auth name)) headers
;;

let dashboard_runtime_credential_value = function
  | Runtime_schema.Env key ->
    (match Option.bind (Sys.getenv_opt key) String_util.trim_to_option with
     | Some value -> Ok value
     | None -> Error (Printf.sprintf "env credential %s is empty or unset" key))
  | Runtime_schema.File path ->
    (try
       match Fs_compat.load_file path |> String_util.trim_to_option with
       | Some value -> Ok value
       | None -> Error (Printf.sprintf "credential file %s is empty" path)
     with
     | Eio.Cancel.Cancelled _ as e -> raise e
     | exn -> Error (Printf.sprintf "credential file %s: %s" path (Printexc.to_string exn)))
  | Runtime_schema.Inline value ->
    (match String_util.trim_to_option value with
     | Some value -> Ok value
     | None -> Error "inline credential is empty")
;;

let dashboard_runtime_probe_headers (provider : Runtime_schema.provider) =
  let base_headers =
    [ "Accept", "application/json" ] @ dashboard_runtime_non_auth_headers provider
  in
  match provider.credentials with
  | None -> Ok (false, base_headers)
  | Some credential ->
    (match dashboard_runtime_credential_value credential with
     | Ok value -> Ok (true, ("Authorization", "Bearer " ^ value) :: base_headers)
     | Error _ as error -> error)
;;

let dashboard_runtime_probe_transport_kind = function
  | Runtime_schema.Cli _ -> "cli"
  | Runtime_schema.Http url
    when Uri.of_string url |> Uri.host |> Masc_network_defaults.is_loopback_host_opt ->
    "local"
  | Runtime_schema.Http _ -> "http"
;;

let dashboard_runtime_probe_http_get ~url ~headers ~timeout_sec =
  match Atomic.get dashboard_runtime_provider_http_get_hook with
  | Some hook -> hook ~url ~headers ~timeout_sec
  | None ->
    let clock = Eio_context.get_clock_opt () in
    (match Masc_http_client.get_response_sync ?clock ~timeout_sec ~url ~headers () with
     | Ok response -> Ok (response.status, response.headers, response.body)
     | Error _ as error -> error)
;;

let dashboard_runtime_header_value name headers =
  let name = String.lowercase_ascii name in
  headers
  |> List.find_map (fun (k, v) ->
    if String.equal name (String.lowercase_ascii k) then Some v else None)
;;

let dashboard_runtime_list_member_len key json =
  match Json_util.assoc_member_opt key json with
  | Some (`List items) -> Some (List.length items)
  | _ -> None
;;

let dashboard_runtime_model_count_of_body ~(api_format : Runtime_schema.api_format) body =
  try
    let json = Yojson.Safe.from_string body in
    match api_format with
    | Runtime_schema.Ollama_api -> dashboard_runtime_list_member_len "models" json
    | Runtime_schema.Messages_api | Runtime_schema.Chat_completions_api ->
      (match dashboard_runtime_list_member_len "data" json with
       | Some _ as value -> value
       | None -> dashboard_runtime_list_member_len "models" json)
  with
  | Yojson.Json_error _ -> None
;;

let dashboard_runtime_status_of_http_status = function
  | Some code when code >= 200 && code < 300 -> "reachable"
  | Some 401 | Some 403 -> "auth_failed"
  | Some 404 -> "endpoint_not_found"
  | Some code when code >= 500 -> "server_error"
  | Some _ -> "http_error"
  | None -> "unknown_http_status"
;;

let dashboard_runtime_provider_probe_json
    ?(http_get = dashboard_runtime_probe_http_get)
    (rt : Runtime.t)
  =
  let runtime_kind = dashboard_runtime_probe_transport_kind rt.provider.transport in
  let auth_kind = dashboard_runtime_provider_auth_kind rt.provider.credentials in
  let credential_required = Option.is_some rt.provider.credentials in
  let endpoint_url =
    match rt.provider.transport with
    | Runtime_schema.Http url -> Some (dashboard_runtime_url_for_json url)
    | Runtime_schema.Cli _ -> None
  in
  let base_fields
        ?probe_url
        ?http_status
        ?latency_ms
        ?model_count
        ?content_type
        ?downloaded_bytes
        ?error
        ~auth_present
        ~status
        ~reachable
        ()
    =
    [ "runtime_id", `String rt.id
    ; "provider_id", `String rt.provider.id
    ; "provider_display_name", `String rt.provider.display_name
    ; "model_id", `String rt.model.id
    ; "model_api_name", `String rt.model.api_name
    ; "protocol", `String rt.provider.protocol
    ; "runtime_kind", `String runtime_kind
    ; "transport", `String (match rt.provider.transport with Runtime_schema.Http _ -> "http" | Runtime_schema.Cli _ -> "cli")
    ; "auth_kind", `String auth_kind
    ; "credential_required", `Bool credential_required
    ; "auth_present", `Bool auth_present
    ; "status", `String status
    ; "reachable", (match reachable with Some value -> `Bool value | None -> `Null)
    ; "http_status", Json_util.int_opt_to_json http_status
    ; "latency_ms", Json_util.float_opt_to_json latency_ms
    ; "model_count", Json_util.int_opt_to_json model_count
    ; "content_type", Json_util.string_opt_to_json content_type
    ; "downloaded_bytes", Json_util.int_opt_to_json downloaded_bytes
    ; "endpoint_url", Json_util.string_opt_to_json endpoint_url
    ; "probe_url", Json_util.string_opt_to_json probe_url
    ; "error", Json_util.string_opt_to_json error
    ; "checked_at", `String (Masc_domain.now_iso ())
    ]
  in
  let make ?probe_url ?http_status ?latency_ms ?model_count ?content_type
      ?downloaded_bytes ?error ~auth_present ~status ~reachable ~skipped () =
    { json =
        `Assoc
          (base_fields
             ?probe_url
             ?http_status
             ?latency_ms
             ?model_count
             ?content_type
             ?downloaded_bytes
             ?error
             ~auth_present
             ~status
             ~reachable
             ())
    ; runtime_id = rt.id
    ; status
    ; reachable
    ; skipped
    }
  in
  match rt.provider.transport with
  | Runtime_schema.Cli _ ->
    make
      ~auth_present:false
      ~status:"skipped_cli"
      ~reachable:None
      ~skipped:true
      ~error:"CLI runtimes do not expose an HTTP reachability endpoint"
      ()
  | Runtime_schema.Http endpoint_url ->
    let probe_url = dashboard_runtime_probe_url ~api_format:rt.provider.api_format endpoint_url in
    let probe_url_json = dashboard_runtime_url_for_json probe_url in
    if not (dashboard_runtime_http_url_valid probe_url)
    then
      make
        ~probe_url:probe_url_json
        ~auth_present:false
        ~status:"invalid_endpoint"
        ~reachable:(Some false)
        ~skipped:false
        ~error:"runtime endpoint is not an absolute http(s) URL"
        ()
    else (
      match dashboard_runtime_probe_headers rt.provider with
      | Error error ->
        make
          ~probe_url:probe_url_json
          ~auth_present:false
          ~status:"missing_auth"
          ~reachable:(Some false)
          ~skipped:false
          ~error
          ()
      | Ok (auth_present, headers) ->
        let started_at = Time_compat.now () in
        (match
           http_get ~url:probe_url ~headers
             ~timeout_sec:dashboard_runtime_probe_timeout_sec_float
         with
         | Ok (http_status, response_headers, body) ->
           let latency_ms = (Time_compat.now () -. started_at) *. 1000.0 in
           let status = dashboard_runtime_status_of_http_status (Some http_status) in
           let reachable = http_status >= 200 && http_status < 300 in
           let model_count =
             if reachable
             then dashboard_runtime_model_count_of_body ~api_format:rt.provider.api_format body
             else None
           in
           make
             ~probe_url:probe_url_json
             ~http_status
             ~latency_ms
             ?model_count
             ?content_type:(dashboard_runtime_header_value "content-type" response_headers)
             ?downloaded_bytes:(Some (String.length body))
             ~auth_present
             ~status
             ~reachable:(Some reachable)
             ~skipped:false
             ()
         | Error error ->
           let latency_ms = (Time_compat.now () -. started_at) *. 1000.0 in
           make
             ~probe_url:probe_url_json
             ~latency_ms
             ~auth_present
             ~status:"network_error"
             ~reachable:(Some false)
             ~skipped:false
             ~error
             ()))
;;

let dashboard_runtime_probe_payload_json_of_runtimes ?default_id runtimes =
  (* Probe each runtime concurrently when a server switch is reachable (the
     production background-refresh fiber / boot warm, or a switch-bearing
     test). Each probe is an independent runtime/URL/HTTP connection with no
     shared mutable state, so the work is embarrassingly parallel and latency
     collapses from [sum latencies] to [max latencies] -- a dead runtime no
     longer serializes the probes after it.

     Concurrency goes through [Eio.Fiber.List.map], the established in-repo
     idiom for bounded parallel dashboard fan-out (see
     [Dashboard_execution]'s enrich_keeper_with_diagnostic). It (a) preserves
     input order, so the count / summary / errors invariants below stay
     byte-identical to the sequential branch; (b) runs the bodies on its OWN
     internal switch and re-raises any non-[Cancelled] exception at THIS call
     site, NOT on the ambient (server root) switch. That distinction matters
     because the probe body is NOT total: [dashboard_runtime_provider_probe_json]
     reaches [Masc_http_client]'s pool init ([Pool.create] / [register_pool]),
     which can raise [Invalid_argument] / [Eio.Mutex.Poisoned]. A bare
     [Eio.Fiber.fork ~sw] onto the root switch would let such a raise call
     [Switch.fail sw] and cancel sibling server background fibers; routing
     through [Fiber.List.map] instead degrades the whole batch to the caller's
     failure envelope ([maybe_fork_dashboard_runtime_probe_refresh]'s
     [| exception exn -> record_failure]) -- the same outcome the sequential
     [List.map] already produces, so the parallel path is no worse than
     sequential under a rogue exn. [Eio.Cancel.Cancelled] (server shutdown)
     still propagates. Bounded at [dashboard_runtime_probe_max_fibers].

     Without a switch (unit tests, no Eio scheduler) it falls back to a
     sequential [List.map] so deterministic ordering and test seams hold. *)
  let probes =
    match Eio_context.get_switch_opt () with
    | None -> List.map dashboard_runtime_provider_probe_json runtimes
    | Some _sw ->
      Eio.Fiber.List.map
        ~max_fibers:dashboard_runtime_probe_max_fibers
        dashboard_runtime_provider_probe_json
        runtimes
  in
  let count pred = probes |> List.filter pred |> List.length in
  let skipped = count (fun p -> p.skipped) in
  let reachable = count (fun p -> Option.equal Bool.equal p.reachable (Some true)) in
  let failed = count (fun p -> Option.equal Bool.equal p.reachable (Some false)) in
  let probed = List.length probes - skipped in
  let status =
    if failed = 0 && probed > 0
    then "reachable"
    else if failed = 0
    then "no_http_runtimes"
    else if reachable > 0
    then "degraded"
    else "unreachable"
  in
  let errors =
    probes
    |> List.filter_map (fun probe ->
      match probe.reachable with
      | Some false ->
        Some (Printf.sprintf "%s: %s" probe.runtime_id probe.status)
      | _ -> None)
  in
  `Assoc
    [ "source", `String runtime_inventory_source
    ; "status", `String status
    ; "probe_ok", `Bool (failed = 0)
    ; "checked_at", `String (Masc_domain.now_iso ())
    ; ( "summary"
      , `Assoc
          [ "runtimes", `Int (List.length runtimes)
          ; "probed", `Int probed
          ; "reachable", `Int reachable
          ; "failed", `Int failed
          ; "skipped", `Int skipped
          ; "default_runtime_id", Json_util.string_opt_to_json default_id
          ] )
    ; "providers", `List (List.map (fun p -> p.json) probes)
    ; "errors", Json_util.json_string_list errors
    ; ( "observations"
      , Json_util.json_string_list
          [ Printf.sprintf
              "runtime.toml provider reachability: %d reachable, %d failed, %d skipped"
              reachable
              failed
              skipped
          ] )
    ; "limitations"
      , Json_util.json_string_list
          [ "Probe checks provider metadata endpoints only; it does not send a completion request."
          ; "CLI runtimes are listed but not executed by the dashboard probe."
          ]
    ]
;;

let dashboard_runtime_probe_payload_json_for_tests ?default_id runtimes =
  dashboard_runtime_probe_payload_json_of_runtimes ?default_id runtimes
;;

let run_dashboard_runtime_probe () =
  match Atomic.get dashboard_runtime_probe_runner_hook with
  | Some hook -> hook ()
  | None ->
    let runtimes = Runtime.get_runtimes () in
    let default_id =
      Runtime.get_default_runtime () |> Option.map (fun (rt : Runtime.t) -> rt.id)
    in
    dashboard_runtime_probe_payload_json_of_runtimes ?default_id runtimes
;;

let dashboard_runtime_probe_degraded_envelope
      ~status ~error ~observation ~limitation () =
  (* Degraded probe envelope shared by the warming-up (cold start, no prior
     cache value) and unreachable paths. Keeps [probe_ok] false and every
     summary count zero so the dashboard surfaces a clear "no data yet" state
     rather than stalling the HTTP response. *)
  `Assoc
    [ "source", `String runtime_inventory_source
    ; "status", `String status
    ; "probe_ok", `Bool false
    ; "checked_at", `String (Masc_domain.now_iso ())
    ; ( "summary"
      , `Assoc
          [ "runtimes", `Int 0
          ; "probed", `Int 0
          ; "reachable", `Int 0
          ; "failed", `Int 0
          ; "skipped", `Int 0
          ; "default_runtime_id", `Null
          ] )
    ; "providers", `List []
    ; "errors", `List [ `String error ]
    ; "observations", `List [ `String observation ]
    ; "limitations", `List [ `String limitation ]
    ]
;;

let dashboard_runtime_probe_failure_envelope_of_exn (exn : exn) =
  (* Failure envelope persisted to the cache when a background refresh raises,
     so the dashboard surfaces the cause instead of masking it as a stale or
     warming-up value (failure-visibility contract). [Printexc.to_string]
     carries the exception message into the [errors] array; the next refresh
     after TTL expiry retries the probe. Pure function so the envelope shape is
     unit-testable independent of the cache/atomic plumbing. *)
  dashboard_runtime_probe_degraded_envelope
    ~status:"unreachable"
    ~error:(Printexc.to_string exn)
    ~observation:
      "Runtime probe background refresh failed; the value below is a failure \
       snapshot cached for the cache TTL window so the dashboard surfaces the \
       cause. The next refresh after TTL expiry retries the probe."
    ~limitation:"Cached failure envelope; a successful refresh replaces it."
    ()

let dashboard_runtime_probe_record_failure exn =
  (* Write the failure envelope to the cache (so subsequent reads within the
     TTL window see the cause) and release the single-flight CAS. [Atomic.set]
     never yields. *)
  Atomic.set
    dashboard_runtime_probe_cache
    (Some
       { probe = dashboard_runtime_probe_failure_envelope_of_exn exn
       ; refreshed_at = Time_compat.now ()
       });
  Atomic.set dashboard_runtime_probe_refresh_in_flight false
;;

let maybe_fork_dashboard_runtime_probe_refresh () =
  (* Trigger a background refresh of the runtime probe cache without ever
     blocking the caller. Single-flight via the
     [dashboard_runtime_probe_refresh_in_flight] CAS: if a refresh is already
     running, this is a no-op. On domains where a background [Eio.Fiber.fork]
     is not permitted (Domain_pool worker domains, or when no server switch is
     reachable), release the CAS and skip -- a subsequent request on the main
     domain will pick it up. [Atomic.set] never yields, so the in-flight flag
     is always cleared even when the forked fiber raises or is cancelled.

     This replaces the previous synchronous wait (up to
     [dashboard_runtime_probe_timeout_sec], i.e. 15s) that stalled the whole
     dashboard shell on every cache-miss poll and every force=1 request.
     Mirrors the git-rev-parse background-refresh pattern
     ([maybe_refresh_git_rev_parse_short_in_background]) already in this
     module. *)
  if Atomic.compare_and_set dashboard_runtime_probe_refresh_in_flight false true
  then begin
    if Server_probe_cache.background_refresh_domain_unavailable () then
      Atomic.set dashboard_runtime_probe_refresh_in_flight false
    else
      match Eio_context.get_switch_opt () with
      | None -> Atomic.set dashboard_runtime_probe_refresh_in_flight false
      | Some sw ->
        let run () =
          match run_dashboard_runtime_probe () with
          | fresh ->
            let refreshed_at = Time_compat.now () in
            Atomic.set
              dashboard_runtime_probe_cache
              (Some { probe = fresh; refreshed_at });
            Atomic.set dashboard_runtime_probe_refresh_in_flight false
          | exception Eio.Cancel.Cancelled _ ->
            (* Switch cancelled (e.g. server shutdown): release CAS, do not
               cache. A shutdown is not a probe failure. *)
            Atomic.set dashboard_runtime_probe_refresh_in_flight false
          | exception exn ->
            (* Persist a failure envelope so the dashboard surfaces the cause
               instead of masking it as a stale or warming-up value
               (failure-visibility contract). Cached for the TTL window; the
               next refresh after expiry retries. Covers [Eio.Mutex.Poisoned]
               and any other exn -- [dashboard_runtime_probe_record_failure]
               writes the envelope and releases the CAS atomically. *)
            Log.Dashboard.warn
              "runtime probe background refresh failed: %s"
              (Printexc.to_string exn);
            dashboard_runtime_probe_record_failure exn
        in
        (try Eio.Fiber.fork ~sw run with
         | exn when Server_probe_cache.eio_switch_fork_unavailable exn ->
           Server_probe_cache.background_refresh_mark_domain_unavailable ();
           Atomic.set dashboard_runtime_probe_refresh_in_flight false
         | exn ->
           Atomic.set dashboard_runtime_probe_refresh_in_flight false;
           raise exn)
  end
;;

let dashboard_runtime_probe_cached_value () =
  match Atomic.get dashboard_runtime_probe_cache with
  | Some entry -> Some (entry.probe, entry.refreshed_at)
  | None -> None
;;

let dashboard_runtime_probe_fresh_value ~now =
  match dashboard_runtime_probe_cached_value () with
  | Some (probe, refreshed_at)
    when now -. refreshed_at <= dashboard_runtime_probe_cache_ttl_sec ->
    Some (probe, refreshed_at)
  | _ -> None
;;

let dashboard_runtime_probe_recent_value ~now =
  match dashboard_runtime_probe_cached_value () with
  | Some (probe, refreshed_at)
    when now -. refreshed_at <= dashboard_runtime_probe_force_min_refresh_sec ->
    Some (probe, refreshed_at)
  | _ -> None
;;

(* Why this exists: force=1 callers (the dashboard "Live probe" button) expect an
   immediate fresh value, but the route is non-blocking — a cache miss schedules
   a background refresh and returns the best value available now. This tag makes
   that contract explicit in the response so the client can tell "this is the
   refreshed value" from "a refresh was scheduled; the next poll carries the new
   value", instead of inferring it from [cache_hit] alone. Closed sum so adding a
   freshness branch forces an exhaustive update of the serializer. *)
type dashboard_runtime_probe_refresh_state =
  | Refresh_fresh (* TTL-fresh cache hit (non-force); no background refresh triggered. *)
  | Refresh_recent
  (* force=1 within [dashboard_runtime_probe_force_min_refresh_sec]: the recent
     value is served and no new refresh is triggered (force rate limit). *)
  | Refresh_served_stale
  (* Cache miss with a stale value: the stale value is returned and a background
     refresh was scheduled; the next poll carries the fresh value. *)
  | Refresh_warming_up
(* Cold start (no cache value): a warming-up placeholder is returned and a
     background refresh was scheduled; the next poll carries the fresh value. *)

let dashboard_runtime_probe_refresh_state_to_string = function
  | Refresh_fresh -> "fresh"
  | Refresh_recent -> "recent"
  | Refresh_served_stale -> "served_stale"
  | Refresh_warming_up -> "warming_up"
;;

let dashboard_runtime_probe_http_json ?(force = false) () =
  let now = Time_compat.now () in
  let probe, cache_hit, refreshed_at, refresh_state =
    match
      if force
      then dashboard_runtime_probe_recent_value ~now
      else dashboard_runtime_probe_fresh_value ~now
    with
    | Some (cached, cached_at) ->
      (* Cache hit: a force=1 hit inside the recent-value window is rate-limited
         (no new refresh) and tagged [recent]; a plain TTL-fresh hit is [fresh].
         Stale-while-revalidate: even on a TTL-fresh (non-force) hit, once the
         cached value's age crosses the soft-TTL
         [dashboard_runtime_probe_soft_refresh_sec] we schedule a non-blocking
         background refresh. The single-flight CAS inside
         {!maybe_fork_dashboard_runtime_probe_refresh} makes this a no-op when a
         refresh is already running. This pre-warms the cache so the *next* poll
         sees a fresh value instead of letting cache expiry land on a poll (the
         TTL==poll-interval hit-rate-0 trap). The current response still serves
         the fresh value; the refresh is invisible to the client. *)
      let age = now -. cached_at in
      if (not force) && age > dashboard_runtime_probe_soft_refresh_sec
      then maybe_fork_dashboard_runtime_probe_refresh ();
      cached, true, cached_at, (if force then Refresh_recent else Refresh_fresh)
    | None ->
      (* Cache miss (or forced refresh past the recent window): trigger a
         non-blocking background refresh and return the best value available
         right now (stale cache, or a warming-up envelope on cold start). This
         removes the synchronous up-to-[dashboard_runtime_probe_timeout_sec]
         wait that previously stalled the dashboard shell on every cache-miss
         poll and on every force=1 request. [refresh_state] tells the client a
         refresh was scheduled, so a force=1 caller does not mistake the
         stale/warming-up value for an immediate fresh probe. *)
      maybe_fork_dashboard_runtime_probe_refresh ();
      (match dashboard_runtime_probe_cached_value () with
       | Some (stale, stale_at) -> stale, false, stale_at, Refresh_served_stale
       | None ->
         ( dashboard_runtime_probe_degraded_envelope
             ~status:"warming_up"
             ~error:"background probe in progress"
             ~observation:
               "Runtime probe is running in the background after a cold \
                start or cache expiry; the next poll returns the refreshed \
                value."
             ~limitation:
               "First response with no prior cache value returns this \
                placeholder until the background probe completes."
             (),
           false,
           0.0,
           Refresh_warming_up ))
  in
  let response_now = Time_compat.now () in
  let refreshed_at_json, cache_age_json =
    if refreshed_at > 0.0
    then `Float refreshed_at, `Float (max 0.0 (response_now -. refreshed_at))
    else `Null, `Null
  in
  `Assoc
    [ "generated_at", `String (Masc_domain.now_iso ())
    ; "refreshed_at_unix", refreshed_at_json
    ; "cache_ttl_sec", `Float dashboard_runtime_probe_cache_ttl_sec
    ; "cache_age_sec", cache_age_json
    ; "cache_hit", `Bool cache_hit
    ; ( "refresh_state"
      , `String (dashboard_runtime_probe_refresh_state_to_string refresh_state) )
    ; "probe", probe
    ]
;;

