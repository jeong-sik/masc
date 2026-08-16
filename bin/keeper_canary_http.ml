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

let trim_nonempty value =
  let trimmed = String.trim value in
  if trimmed = "" then None else Some trimmed

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
   decide "this turn did not produce a usable reply." *)
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
    if status < 200 || status >= 300
    then
      Error
        (Printf.sprintf "POST %s returned HTTP %d: %s" url status response_body)
    else Masc.Tui_decode.parse_keeper_chat_response response_body
