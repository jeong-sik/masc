(* Slack_socket_client — I/O layer that drives {!Slack_gateway_state}.

   Mirrors {!Discord_gateway_client}: open a WSS connection (URL fetched
   via apps.connections.open), fork a reader, parse envelopes, feed them
   to {!Slack_gateway_state.step}, and run the returned effects. All
   correctness lives in the pure state machine; this module only
   translates between bytes and typed inputs/effects.

   Reuses {!Discord_wss_connection}: the ws-direct+TLS transport is
   protocol-neutral, and Slack Socket Mode WSS URLs are the same
   [wss://host/path?query] shape as a Discord gateway URL, so we open the
   connection with the Slack-issued URL. No separate transport module is
   needed.

   Differences from the Discord gateway client:
   - No heartbeat fiber / no resume / no presence: Slack auto-replies to
     RFC 6455 Ping at the endpoint and never resumes a session — reconnect
     is always a fresh [apps.connections.open].
   - [apps.connections.open]: the WSS URL is not constant. The FSM emits
     [Apps_connections_open]; this layer fetches the URL via
     [Masc_http_client.post_sync] and feeds
     [Apps_connections_open_succeeded] back into the drive loop.
   - Per-envelope ack: every envelope carrying [envelope_id] yields a
     [Send_ack] effect; this layer answers with a JSON text frame, or
     Slack retransmits and eventually drops the connection.
   - WSS connect failure maps to [Wss_closed]: the Slack FSM has no
     separate [Connect_failed] input — [Awaiting_hello, Wss_closed] routes
     to [Reconnect_pending] with the same backoff path, so a connect-time
     failure is indistinguishable from an early peer close, which is fine:
     both retry the same way.

   See: docs/rfc/RFC-0xxx-slack-builtin-gateway.md (and RFC-0203 for the
   Discord original this is modeled on). *)

(* Re-export the caller-facing types so callers don't reach into the state
   machine module directly. Matches the {!mli}. *)
type slack_event = Slack_gateway_state.slack_event
type trigger_policy = Slack_gateway_state.trigger_policy
type connection_state = Slack_gateway_state.connection_state

(* now_mono as float seconds. The state machine treats it as opaque; we only
   need it monotone-increasing. Identical to Discord_gateway_client. *)
let now_mono env =
  let m = Eio.Time.Mono.now (Eio.Stdenv.mono_clock env) in
  Int64.to_float (Mtime.to_uint64_ns m) /. 1e9

let log_effect level message =
  match level with
  | `Info -> Log.Slack.info "%s" message
  | `Warn -> Log.Slack.warn "%s" message
  | `Error -> Log.Slack.error "%s" message

(* The run loop's connection state, published so connector presence
   ([Channel_gate_slack_state]) can read it without a file indirection.
   One gateway per process (single app token); written only by [run]'s
   state-machine step, everyone else reads. Same shape as
   Discord_gateway_client.published_connection_state. *)
let published_connection_state : Slack_gateway_state.connection_state Atomic.t
  =
  Atomic.make Slack_gateway_state.Disconnected

let connection_state () = Atomic.get published_connection_state

(* Translate a ws-direct [inbound] event into a state-machine [input]. Slack
   envelopes are JSON text; the peer Close surfaces as [Wss_closed]. The
   FSM owns parsing ([parse_envelope]); this just routes Ok/Error into
   [Envelope_received] / [Envelope_parse_error]. *)
let envelope_to_input ~bot_user_id (inbound : Discord_wss_connection.inbound) =
  match inbound with
  | Discord_wss_connection.Message content -> (
      match Yojson.Safe.from_string content with
      | exception Yojson.Json_error msg ->
        Some (Slack_gateway_state.Envelope_parse_error ("json: " ^ msg))
      | json -> (
        match Slack_gateway_state.parse_envelope ~bot_user_id json with
        | Ok env -> Some (Slack_gateway_state.Envelope_received env)
        | Error msg -> Some (Slack_gateway_state.Envelope_parse_error msg)))
  | Discord_wss_connection.Closed { code; reason } ->
    let reason =
      Printf.sprintf "wss closed: code=%d%s" code
        (if String.equal reason "" then "" else " " ^ reason)
    in
    Some (Slack_gateway_state.Wss_closed { reason })

(* The reader stops only on [Wss_closed]: there is no socket to keep alive
   once the transport reports Close. Every other input is read off the same
   connection and the loop continues. *)
let reader_should_continue_after_input = function
  | Slack_gateway_state.Wss_closed _ -> false
  | Slack_gateway_state.Connect_requested
  | Slack_gateway_state.Apps_connections_open_succeeded _
  | Slack_gateway_state.Apps_connections_open_failed _
  | Slack_gateway_state.Envelope_received _
  | Slack_gateway_state.Envelope_parse_error _
  | Slack_gateway_state.Backoff_elapsed -> true

(* apps.connections.open → fresh WSS URL. POST with the app-level token
   ([xapp-...]). Returns [Ok url] on Slack [{ok:true,url:"..."}], [Error
   reason] otherwise. The app token leaves the process only in this one
   Authorization header. *)
let fetch_wss_url ?clock ?(timeout_sec = 10.0) ~app_token () =
  let url = "https://slack.com/api/apps.connections.open" in
  let headers =
    [ ("Authorization", "Bearer " ^ app_token)
    ; ("Content-Type", "application/x-www-form-urlencoded; charset=utf-8")
    ]
  in
  match Masc_http_client.post_sync ?clock ~timeout_sec ~url ~headers ~body:"" () with
  | Error e -> Error ("apps.connections.open transport: " ^ e)
  | Ok (200, body) -> (
      match Yojson.Safe.from_string body with
      | exception Yojson.Json_error msg ->
        Error ("apps.connections.open json: " ^ msg)
      | `Assoc fields ->
        let ok =
          match List.assoc_opt "ok" fields with
          | Some (`Bool b) -> b
          | _ -> false
        in
        if ok then
          (match List.assoc_opt "url" fields with
           | Some (`String u) -> Ok u
           | _ -> Error "apps.connections.open: missing url field")
        else
          let err =
            match List.assoc_opt "error" fields with
            | Some (`String e) -> e
            | _ -> "unknown"
          in
          Error ("apps.connections.open: slack error: " ^ err)
      | _ -> Error "apps.connections.open: response not an object")
  | Ok (code, body) ->
    Error (Printf.sprintf "apps.connections.open status %d: %s" code body)

(* Ack an envelope. Built with Yojson so an envelope id containing
   JSON-special characters (none in practice — they are UUIDs) cannot break
   the frame. *)
let ack_payload envelope_id =
  Yojson.Safe.to_string (`Assoc [ ("envelope_id", `String envelope_id) ])

let run ~sw ~env ~bot_user_id ~app_token ~trigger_policy ~on_event () =
  if String.equal app_token "" then
    (* No-op: a server without Slack configured must be unaffected. *)
    Log.Slack.info "slack socket mode disabled (empty app token)"
  else
    let config : Slack_gateway_state.config = { trigger_policy; bot_user_id } in
    let state = ref (Slack_gateway_state.create ~config) in
    let conn_ref : Discord_wss_connection.conn option ref = ref None in
    let input_mailbox = Eio.Stream.create 64 in
    let clock = Eio.Stdenv.clock env in

    let connection_is_current conn =
      match !conn_ref with Some current -> current == conn | None -> false
    in

    let enqueue_if_current conn input =
      if connection_is_current conn then begin
        Eio.Stream.add input_mailbox input;
        true
      end else begin
        Log.Slack.debug
          "dropping slack gateway input from inactive WSS connection";
        false
      end
    in

    let reader_loop conn =
      let rec loop () =
        if not (connection_is_current conn) then
          Log.Slack.debug "stopping inactive slack gateway reader"
        else
          (match Discord_wss_connection.read conn with
           | exception Eio.Cancel.Cancelled _ -> ()
           | exception End_of_file ->
             let (_ : bool) =
               enqueue_if_current conn
                 (Slack_gateway_state.Wss_closed { reason = "eof" })
             in
             ()
           | exception e ->
             let (_ : bool) =
               enqueue_if_current conn
                 (Slack_gateway_state.Wss_closed
                    { reason = Printexc.to_string e })
             in
             ()
           | inbound ->
             (match envelope_to_input ~bot_user_id inbound with
              | Some inp ->
                if
                  enqueue_if_current conn inp
                  && reader_should_continue_after_input inp
                then loop ()
              | None -> loop ()))
      in
      loop ()
    in

    let run_effect (eff : Slack_gateway_state.gateway_effect) =
      match eff with
      | Slack_gateway_state.Apps_connections_open ->
        (* Fetch off the drive loop: apps.connections.open is a network call
           (hundreds of ms), so run it in its own fiber and feed the result
           back as an input. Keeps the drive loop responsive for acks. *)
        Eio.Fiber.fork ~sw (fun () ->
            match fetch_wss_url ~clock ~app_token () with
            | Ok url ->
              Eio.Stream.add input_mailbox
                (Slack_gateway_state.Apps_connections_open_succeeded { url })
            | Error reason ->
              log_effect `Warn
                (Printf.sprintf "apps.connections.open failed: %s" reason);
              Eio.Stream.add input_mailbox
                (Slack_gateway_state.Apps_connections_open_failed { reason }))
      | Slack_gateway_state.Open_wss { url } ->
        (match !conn_ref with
         | Some old_conn ->
           (* Same defensive cleanup as Discord_gateway_client: the FSM may
              emit Open_wss while a stale conn is still tracked (e.g. a
              peer Close that bypassed our Close_wss path). [close] is
              idempotent, so calling it on an already-closed conn is safe. *)
           log_effect `Warn
             "Open_wss while conn_ref still Some; force-closing stale connection";
           Discord_wss_connection.close old_conn;
           conn_ref := None
         | None -> ());
        (match Discord_wss_connection.connect ~sw ~env ~url with
         | conn ->
           conn_ref := Some conn;
           Discord_wss_connection.spawn conn (fun () -> reader_loop conn)
         | exception (Eio.Cancel.Cancelled _ as e) -> raise e
         | exception exn ->
           (* DNS / connect / TLS handshake failure: feed [Wss_closed] so
              the FSM schedules a backoff reconnect rather than killing the
              gateway. *)
           let reason = Printexc.to_string exn in
           log_effect `Warn
             (Printf.sprintf "slack wss connect failed: %s" reason);
           Eio.Stream.add input_mailbox
             (Slack_gateway_state.Wss_closed
                { reason = "wss connect failed: " ^ reason }))
      | Slack_gateway_state.Close_wss ->
        (* Resolves the inner session switch's close signal, cancelling every
           fiber forked on it — including the reader (its blocking [read]
           raises [Cancelled]). Idempotent. *)
        (match !conn_ref with
         | Some c -> Discord_wss_connection.close c
         | None -> ());
        conn_ref := None
      | Slack_gateway_state.Send_ack { envelope_id } -> (
        match !conn_ref with
        | None ->
          log_effect `Warn "Send_ack while conn_ref is None; dropping"
        | Some conn ->
          Discord_wss_connection.send_text conn (ack_payload envelope_id))
      | Slack_gateway_state.Emit_event ev -> on_event ev
      | Slack_gateway_state.Schedule_backoff { delay_ms } ->
        Eio.Fiber.fork ~sw (fun () ->
            (* ±25% jitter, same shape as Discord_gateway_client. The FSM's
               delay_ms stays deterministic for testability; jitter belongs
               in the I/O layer per RFC-0203 to prevent thundering herd. *)
            let jitter_factor =
              let raw = Crypto_rng.generate 1 in
              let byte = Char.code raw.[0] in
              0.75 +. (0.5 *. (float_of_int byte /. 255.0))
            in
            let jittered_ms =
              int_of_float (float_of_int delay_ms *. jitter_factor)
            in
            Eio.Time.sleep clock (float_of_int jittered_ms /. 1000.0);
            Eio.Stream.add input_mailbox Slack_gateway_state.Backoff_elapsed)
      | Slack_gateway_state.Log { level; message } -> log_effect level message
    in

    let step_now input =
      let now = now_mono env in
      let (s', effects) = Slack_gateway_state.step !state ~now_mono:now input in
      state := s';
      Atomic.set published_connection_state (Slack_gateway_state.state s');
      List.iter run_effect effects
    in

    step_now Slack_gateway_state.Connect_requested;

    let rec drive () =
      let input = Eio.Stream.take input_mailbox in
      step_now input;
      drive ()
    in
    drive ()

module For_testing = struct
  let reader_should_continue_after_input = reader_should_continue_after_input
end
