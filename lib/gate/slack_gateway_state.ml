(* Slack Socket Mode — pure state machine. See slack_gateway_state.mli.
   Zero I/O. The I/O layer (Slack_socket_client, follow-up) reads envelopes off
   the WSS connection built on Discord_wss_connection, feeds them as [input],
   and runs the returned [gateway_effect] list. *)

(* Reconnect backoff: Slack recommends exponential with a cap. We start at 1s,
   double, and cap at 30s — same shape as Discord_gateway_state. *)
let base_backoff_ms = 1_000
let max_backoff_ms = 30_000

let next_backoff_ms attempts =
  let n = ref base_backoff_ms in
  for _ = 1 to max 0 (min attempts 5) do
    n := !n * 2
  done;
  min !n max_backoff_ms
;;

type envelope_kind =
  | Hello_env
  | Events_api_env
  | Disconnect_env of { reason : string }
  | Reconnect_env
  | Ignored_env of string

type slack_event =
  | Message_create of
      { channel_id : string
      ; thread_ts : string option
      ; user_id : string
      ; user_name : string option
      ; text : string
      ; ts : string
      ; mentions_bot : bool
      ; bot_id : string option
      }
  | App_mention of
      { channel_id : string
      ; thread_ts : string option
      ; user_id : string
      ; text : string
      ; ts : string
      }
  | Reaction_added of
      { channel_id : string
      ; message_ts : string
      ; user_id : string
      ; reaction : string
      }
  | Ignored_event of string

type envelope =
  { kind : envelope_kind
  ; envelope_id : string option
  ; event : slack_event option
  }

type connection_state =
  | Disconnected
  | Awaiting_hello
  | Connected
  | Reconnect_pending of { backoff_until_mono : float; reason : string }
  | Failed of string

type input =
  | Connect_requested
  | Apps_connections_open_succeeded of { url : string }
  | Apps_connections_open_failed of { reason : string }
  | Envelope_received of envelope
  | Envelope_parse_error of string
  | Wss_closed of { reason : string }
  | Backoff_elapsed

type gateway_effect =
  | Apps_connections_open
  | Open_wss of { url : string }
  | Close_wss
  | Send_ack of { envelope_id : string }
  | Emit_event of slack_event
  | Schedule_backoff of { delay_ms : int }
  | Log of { level : [ `Info | `Warn | `Error ]; message : string }

type trigger_policy =
  | Mention_only
  | Mention_or_thread
  | User_only of string
  | All

let trigger_policy_to_string = function
  | Mention_only -> "mention_only"
  | Mention_or_thread -> "mention_or_thread"
  | User_only id -> "user_only:" ^ id
  | All -> "all"
;;

let parse_trigger_policy raw =
  match String.trim raw with
  | "mention_only" -> Ok Mention_only
  | "mention_or_thread" -> Ok Mention_or_thread
  | "all" -> Ok All
  | s when String.starts_with ~prefix:"user_only:" s ->
    let prefix_len = String.length "user_only:" in
    let id = String.sub s prefix_len (String.length s - prefix_len) in
    if String.length id > 0 then Ok (User_only id) else Error "user_only:<id> requires a non-empty id"
  | other -> Error (Printf.sprintf "unknown trigger_policy: %S" other)
;;

type config = { trigger_policy : trigger_policy; bot_user_id : string option }

type t =
  { state : connection_state
  ; config : config
  ; reconnect_attempts : int
  }

let create ~config = { state = Disconnected; config; reconnect_attempts = 0 }
let state t = t.state
let config t = t.config

(* Does an event pass the trigger policy and earn an [Emit_event]? *)
let passes_policy (cfg : config) = function
  | Message_create m -> (
      match cfg.trigger_policy with
      | All -> true
      | Mention_only -> m.mentions_bot
      | Mention_or_thread -> m.mentions_bot || Option.is_some m.thread_ts
      | User_only id -> String.equal m.user_id id)
  | App_mention _ -> true  (* An app_mention is, by definition, a mention. *)
  | Reaction_added _ -> false  (* Reactions are ambient; not turn-starters yet. *)
  | Ignored_event _ -> false
;;

let ack_effect env =
  match env.envelope_id with Some id -> [ Send_ack { envelope_id = id } ] | None -> []
;;

let rec step t ~now_mono input =
  let log lvl msg = [ Log { level = lvl; message = msg } ] in
  match (t.state, input) with
  | (Disconnected | Reconnect_pending _), Connect_requested ->
    let t = { t with state = Awaiting_hello; reconnect_attempts = 0 } in
    (t, [ Apps_connections_open ])
  | Awaiting_hello, Apps_connections_open_succeeded { url } ->
    (t, [ Open_wss { url } ])
  | Awaiting_hello, Apps_connections_open_failed { reason } ->
    let delay = next_backoff_ms t.reconnect_attempts in
    let t =
      { t with
        state = Reconnect_pending { backoff_until_mono = now_mono; reason }
      ; reconnect_attempts = t.reconnect_attempts + 1
      }
    in
    (t, Schedule_backoff { delay_ms = delay } :: log `Warn ("apps.connections.open failed: " ^ reason))
  | Awaiting_hello, Envelope_received { kind = Hello_env; _ } ->
    ({ t with state = Connected }, log `Info "slack socket mode connected")
  | Connected, Envelope_received ({ kind = Events_api_env; event; envelope_id; _ } as env) ->
    let ack = ack_effect env in
    let emit =
      match event with
      | Some e when passes_policy t.config e -> [ Emit_event e ]
      | _ -> []
    in
    (t, ack @ emit)
  | Connected, Envelope_received ({ kind = Hello_env; envelope_id; _ } as env) ->
    (* A mid-stream hello is unexpected; ack it and log, do not change state. *)
    (t, ack_effect env @ log `Warn "unexpected hello envelope while connected")
  | Connected, Envelope_received ({ kind = Disconnect_env { reason }; envelope_id; _ } as env) ->
    let delay = next_backoff_ms t.reconnect_attempts in
    let t =
      { t with
        state = Reconnect_pending { backoff_until_mono = now_mono; reason }
      ; reconnect_attempts = t.reconnect_attempts + 1
      }
    in
    ( t
    , ack_effect env @ [ Close_wss; Schedule_backoff { delay_ms = delay } ]
      @ log `Info ("slack disconnect envelope: " ^ reason) )
  | Connected, Envelope_received ({ kind = Reconnect_env; envelope_id; _ } as env) ->
    let delay = next_backoff_ms t.reconnect_attempts in
    let t =
      { t with
        state = Reconnect_pending { backoff_until_mono = now_mono; reason = "reconnect envelope" }
      ; reconnect_attempts = t.reconnect_attempts + 1
      }
    in
    (t, ack_effect env @ [ Close_wss; Schedule_backoff { delay_ms = delay } ])
  | Connected, Envelope_received ({ kind = Ignored_env _; envelope_id } as env) ->
    (* Envelope type we don't surface (slash_commands, interactive): ack only. *)
    (t, ack_effect env)
  | (Disconnected | Awaiting_hello | Connected | Reconnect_pending _), Envelope_parse_error msg ->
    (t, log `Warn ("envelope parse error: " ^ msg))
  | Connected, Wss_closed { reason } ->
    let delay = next_backoff_ms t.reconnect_attempts in
    let t =
      { t with
        state = Reconnect_pending { backoff_until_mono = now_mono; reason }
      ; reconnect_attempts = t.reconnect_attempts + 1
      }
    in
    (t, [ Schedule_backoff { delay_ms = delay } ] @ log `Info ("wss closed: " ^ reason))
  | Awaiting_hello, Wss_closed { reason } ->
    let delay = next_backoff_ms t.reconnect_attempts in
    let t =
      { t with
        state = Reconnect_pending { backoff_until_mono = now_mono; reason }
      ; reconnect_attempts = t.reconnect_attempts + 1
      }
    in
    (t, [ Schedule_backoff { delay_ms = delay } ] @ log `Warn ("wss closed before hello: " ^ reason))
  | Reconnect_pending _, Backoff_elapsed ->
    let t = { t with state = Awaiting_hello } in
    (t, [ Apps_connections_open ])
  | ( Disconnected
    , ( Apps_connections_open_succeeded _ | Apps_connections_open_failed _ | Envelope_received _
      | Wss_closed _ | Backoff_elapsed ) )
  | ( Connected
    , ( Connect_requested | Apps_connections_open_succeeded _ | Apps_connections_open_failed _
      | Backoff_elapsed ) )
  | (Awaiting_hello, (Connect_requested | Envelope_received _ | Backoff_elapsed))
  | ( Reconnect_pending _
    , ( Apps_connections_open_succeeded _ | Apps_connections_open_failed _ | Envelope_received _
      | Wss_closed _ ) )
  | ( Failed _
    , ( Connect_requested | Apps_connections_open_succeeded _ | Apps_connections_open_failed _
      | Envelope_received _ | Envelope_parse_error _ | Wss_closed _ | Backoff_elapsed ) ) ->
    (t, log `Warn "slack gateway: input unexpected in current state")

and input_label = function
  | Connect_requested -> "connect_requested"
  | Apps_connections_open_succeeded _ -> "apps_connections_open_succeeded"
  | Apps_connections_open_failed _ -> "apps_connections_open_failed"
  | Envelope_received _ -> "envelope_received"
  | Envelope_parse_error _ -> "envelope_parse_error"
  | Wss_closed _ -> "wss_closed"
  | Backoff_elapsed -> "backoff_elapsed"

and state_label = function
  | Disconnected -> "disconnected"
  | Awaiting_hello -> "awaiting_hello"
  | Connected -> "connected"
  | Reconnect_pending _ -> "reconnect_pending"
  | Failed msg -> "failed"
;;

(* ---- JSON parsing ---- *)

let assoc key json =
  match json with
  | `Assoc fields -> List.assoc_opt key fields
  | _ -> None
;;

let as_string = function `String s -> Some s | _ -> None

let string_field key json =
  match Option.bind (assoc key json) as_string with
  | Some s -> s
  | None -> ""
;;

let string_field_opt key json = Option.bind (assoc key json) as_string

let object_field key json =
  match assoc key json with
  | Some (`Assoc _ as obj) -> Ok obj
  | Some _ -> Error (key ^ " must be an object")
  | None -> Error (key ^ " missing")
;;

let text_mentions_bot ~bot_user_id text =
  match bot_user_id with
  | None -> false
  | Some id ->
    let needle = "<@" ^ id ^ ">" in
    let len = String.length needle in
    let tlen = String.length text in
    let rec loop i =
      if i + len > tlen then false
      else if String.sub text i len = needle then true
      else loop (i + 1)
    in
    loop 0
;;

let decode_event ~bot_user_id ~event_type ~payload =
  match event_type with
  | "message" ->
    let channel_id = string_field "channel" payload in
    let user_id = string_field "user" payload in
    let text = string_field "text" payload in
    let ts = string_field "ts" payload in
    let thread_ts = string_field_opt "thread_ts" payload in
    let bot_id = string_field_opt "bot_id" payload in
    let user_name = string_field_opt "username" payload in
    let mentions_bot = text_mentions_bot ~bot_user_id text in
    if String.equal channel_id "" || String.equal ts "" then
      Error "message event missing channel/ts"
    else
      Ok
        (Message_create
           { channel_id
           ; thread_ts
           ; user_id
           ; user_name
           ; text
           ; ts
           ; mentions_bot
           ; bot_id
           })
  | "app_mention" ->
    let channel_id = string_field "channel" payload in
    let user_id = string_field "user" payload in
    let text = string_field "text" payload in
    let ts = string_field "ts" payload in
    let thread_ts = string_field_opt "thread_ts" payload in
    if String.equal channel_id "" || String.equal ts "" then
      Error "app_mention event missing channel/ts"
    else Ok (App_mention { channel_id; thread_ts; user_id; text; ts })
  | "reaction_added" ->
    let user_id = string_field "user" payload in
    let reaction = string_field "reaction" payload in
    (match object_field "item" payload with
     | Error _ -> Error "reaction_added event missing item.channel/ts"
     | Ok item ->
       let channel_id = string_field "channel" item in
       let message_ts = string_field "ts" item in
       if String.equal channel_id "" || String.equal message_ts "" then
         Error "reaction_added event missing item.channel/ts"
       else Ok (Reaction_added { channel_id; message_ts; user_id; reaction }))
  | other -> Ok (Ignored_event other)
;;

let decode_events_api_payload ~bot_user_id payload =
  match string_field "type" payload with
  | "event_callback" -> (
      match object_field "event" payload with
      | Error e -> Error ("events_api payload " ^ e)
      | Ok event ->
        let event_type = string_field "type" event in
        decode_event ~bot_user_id ~event_type ~payload:event)
  | "" -> Error "events_api payload missing {type}"
  | other -> Ok (Ignored_event other)
;;

(* A Slack Socket Mode envelope is { type; envelope_id?; payload? }. For
   events_api, [payload] is the normal Events API wrapper and [payload.event]
   is the real event object. *)
let parse_envelope ~bot_user_id json =
  let type_str = string_field "type" json in
  let envelope_id = string_field_opt "envelope_id" json in
  match type_str with
  | "hello" -> Ok { kind = Hello_env; envelope_id; event = None }
  | "disconnect" -> (
      match object_field "payload" json with
      | Error e -> Error ("disconnect envelope " ^ e)
      | Ok payload ->
        let reason = string_field "reason" payload in
        Ok { kind = Disconnect_env { reason }; envelope_id; event = None })
  | "reconnect" -> Ok { kind = Reconnect_env; envelope_id; event = None }
  | "events_api" -> (
      match object_field "payload" json with
      | Error e -> Error ("events_api envelope " ^ e)
      | Ok payload ->
        (match decode_events_api_payload ~bot_user_id payload with
         | Error e -> Error ("events_api decode failed: " ^ e)
         | Ok event -> Ok { kind = Events_api_env; envelope_id; event = Some event }))
  | "slash_commands" | "interactive" -> Ok { kind = Ignored_env type_str; envelope_id; event = None }
  | "" -> Error "envelope missing {type}"
  | other -> Error (Printf.sprintf "unknown envelope type: %S" other)
;;
