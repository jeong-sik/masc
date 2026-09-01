(* Minimal HTTP client for driving a live keeper's chat surface from outside
   the server process (fusion_run.ml drives Fusion in-process; this harness
   drives a real running keeper over the wire instead, because the thing
   under test is exactly the boundary fusion_run.ml doesn't cross — the
   server's turn dispatch, not a library call).

   Deliberately not a shared module: bin/masc_tui_http.ml already exists for
   the same endpoint family but is scoped to the masc_tui executable's own
   (modules ...) list and does not send [request_id] (would 400 against the
   current server — server_routes_http_keeper_stream.ml requires it). Rather
   than widen masc_tui's private surface or carry its stale client into this
   harness, this file is the same five-line auth-header pattern, kept local
   to this executable the same way masc_tui keeps its own local. *)

let default_agent_name = "keeper-canary-run"

(* A turn's whole exchange (request send through provider reply) can run
   well past masc_tui_http.ml's 10s default — that default is sized for
   dashboard reads, not a live generation turn. Callers override per run
   via --turn-timeout: turn latency is a property of the runtime under
   test (a local llama.cpp keeper with a long transcript measured ~110s
   for a one-line ack on 2026-08-16), not of this client. *)
let default_timeout_sec = 120.0

let sanitize_header_value value =
  value
  |> String.map (function
    | '\r' | '\n' -> ' '
    | c -> c)
  |> String.trim

let trim_nonempty = String_util.trim_nonempty

let auth_headers () =
  let agent_header = [ ("X-MASC-Agent", default_agent_name) ] in
  match Option.bind (Env_config_core.raw_value_opt "MASC_TOKEN") trim_nonempty with
  | Some token ->
    ("Authorization", "Bearer " ^ sanitize_header_value token) :: agent_header
  | None -> agent_header

let json_headers () = ("Content-Type", "application/json") :: auth_headers ()

let host_for_url host =
  if String.contains host ':' && not (String.starts_with ~prefix:"[" host)
  then "[" ^ host ^ "]"
  else host

let url_of ~host ~port ~path =
  Printf.sprintf "http://%s:%d%s" (host_for_url host) port path

(* Send one keeper chat turn and return the assembled reply text (SSE deltas
   concatenated, or the terminal completion — see Tui_decode.parse_keeper_chat_response
   for the exact fallback order). [request_id] must be unique per call: the
   server keys idempotent dedup on it, so a reused id across turns would
   collapse them into one durable operation.

   Returns [Error detail] uniformly for connection failure, non-2xx status,
   and unparseable SSE — the caller does not need to distinguish those to
   decide "this turn did not produce a usable reply." The one exception is
   HTTP 429: the loopback rate bucket is shared per IP and per admin token
   (#28730), so a burst from a parallel session can throttle a turn that
   would succeed seconds later. 429 retries with exponential backoff and
   the same request_id — the server keys idempotent dedup on it, so a
   retry can never double-send the turn. Every other non-2xx surfaces
   immediately: a blind retry of a 500/409 would hide a real failure. *)
let rate_limited_status = 429

(* Five attempts spaced 2s/4s/8s/16s cover ~30s of sustained throttling —
   the observed #28730 bursts (parallel session sweeps) drain within that;
   anything longer is a real outage the run should surface. *)
let max_rate_limit_attempts = 5
let rate_limit_backoff_base_s = 2.0

(* bin/keeper_canary_run.ml always publishes the Eio clock before any call
   lands here; the Unix.sleepf arm only exists so this helper stays total
   if that ever changes, and a blocking sleep is then the lesser harm. *)
let sleep_s seconds =
  if seconds > 0.0
  then (
    match Eio_context.get_clock_opt () with
    | Some clock -> Eio.Time.sleep clock seconds
    | None -> Unix.sleepf seconds)

(* Lifecycle/trajectory admin calls are small JSON exchanges, not
   generation turns — 30s covers a drain that measured 5ms and leaves
   room for a loaded server. *)
let admin_timeout_sec = 30.0

let admin_get ~host ~port ~path () : (int * string, string) result =
  let url = url_of ~host ~port ~path in
  match
    Masc_http_client.get_sync
      ?clock:(Eio_context.get_clock_opt ())
      ~timeout_sec:admin_timeout_sec
      ~url
      ~headers:(auth_headers ())
      ()
  with
  | Error detail -> Error (Printf.sprintf "GET %s failed: %s" url detail)
  | Ok (status, body) -> Ok (status, body)

let admin_post ~host ~port ~path ~body () : (int * string, string) result =
  let url = url_of ~host ~port ~path in
  match
    Masc_http_client.post_sync
      ?clock:(Eio_context.get_clock_opt ())
      ~timeout_sec:admin_timeout_sec
      ~url
      ~headers:(json_headers ())
      ~body
      ()
  with
  | Error detail -> Error (Printf.sprintf "POST %s failed: %s" url detail)
  | Ok (status, body) -> Ok (status, body)

let send_turn ?(timeout_sec = default_timeout_sec) ~host ~port ~keeper_name
    ~request_id ~message () : (string, string) result
  =
  let url = url_of ~host ~port ~path:"/api/v1/keepers/chat/stream" in
  let body =
    Yojson.Safe.to_string
      (`Assoc
        [ ("request_id", `String request_id)
        ; ("name", `String keeper_name)
        ; ("message", `String message)
        ])
  in
  let rec attempt n =
    match
      Masc_http_client.post_sync
        ?clock:(Eio_context.get_clock_opt ())
        ~timeout_sec
        ~url
        ~headers:(json_headers ())
        ~body
        ()
    with
    | Error detail -> Error (Printf.sprintf "POST %s failed: %s" url detail)
    | Ok (status, response_body) ->
      if status = rate_limited_status && n < max_rate_limit_attempts
      then (
        let delay = rate_limit_backoff_base_s *. Float.pow 2.0 (float_of_int (n - 1)) in
        Printf.eprintf
          "[keeper_canary_run] HTTP 429 (attempt %d/%d), retrying in %.0fs\n%!"
          n
          max_rate_limit_attempts
          delay;
        sleep_s delay;
        attempt (n + 1))
      else if status < 200 || status >= 300
      then
        Error
          (Printf.sprintf "POST %s returned HTTP %d: %s" url status response_body)
      else Masc.Tui_decode.parse_keeper_chat_response response_body
  in
  attempt 1
