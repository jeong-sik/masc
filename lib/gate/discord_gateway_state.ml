(* RFC-0203 Phase 1.1b — pure state machine.

   This file defines the typed surface and the *shape* of the
   transition function. Concrete transitions are filled in by
   Phase 1.2 (hello/heartbeat), 1.3 (identify), 1.4 (resume/reconnect),
   and 1.5 (dispatch decode).

   Until each phase lands, the corresponding [step] arm returns a
   typed [Failed] state with a phase tag. This is intentional: an
   incomplete transition surfaces as an explicit, named failure
   rather than a silent no-op or catch-all swallow. *)

let protocol_version = 10

(* ── Opcodes ────────────────────────────────────────────────────── *)

type opcode =
  | Op_dispatch
  | Op_heartbeat
  | Op_identify
  | Op_resume
  | Op_reconnect
  | Op_invalid_session
  | Op_hello
  | Op_heartbeat_ack

let opcode_to_int = function
  | Op_dispatch -> 0
  | Op_heartbeat -> 1
  | Op_identify -> 2
  | Op_resume -> 6
  | Op_reconnect -> 7
  | Op_invalid_session -> 9
  | Op_hello -> 10
  | Op_heartbeat_ack -> 11

let opcode_of_int = function
  | 0 -> Ok Op_dispatch
  | 1 -> Ok Op_heartbeat
  | 2 -> Ok Op_identify
  | 6 -> Ok Op_resume
  | 7 -> Ok Op_reconnect
  | 9 -> Ok Op_invalid_session
  | 10 -> Ok Op_hello
  | 11 -> Ok Op_heartbeat_ack
  | n -> Error (Printf.sprintf "unknown gateway opcode: %d" n)

(* ── Intents ───────────────────────────────────────────────────── *)

type intent =
  | Guilds
  | Guild_messages
  | Message_content
  | Guild_message_reactions
  | Direct_messages
  | Direct_message_reactions

let intent_bit = function
  | Guilds -> 1 lsl 0
  | Guild_messages -> 1 lsl 9
  | Guild_message_reactions -> 1 lsl 10
  | Direct_messages -> 1 lsl 12
  | Direct_message_reactions -> 1 lsl 13
  | Message_content -> 1 lsl 15

let intents_bitmask intents =
  List.fold_left (fun acc i -> acc lor (intent_bit i)) 0 intents

(* ── Dispatched events ─────────────────────────────────────────── *)

type dispatched_event =
  | Ready of
      { session_id : string
      ; resume_gateway_url : string
      ; bot_user_id : string
      }
  | Message_create of
      { channel_id : string
      ; message_id : string
      ; author_id : string
      ; content : string
      ; mentions_bot : bool
      }
  | Reaction_add of
      { channel_id : string
      ; message_id : string
      ; user_id : string
      ; emoji : string
      }
  | Ignored of string

(* ── Frame ─────────────────────────────────────────────────────── *)

type frame =
  { op : opcode
  ; s : int option
  ; t : string option
  ; d : Yojson.Safe.t
  }

(* ── Connection state ──────────────────────────────────────────── *)

type connection_state =
  | Disconnected
  | Awaiting_hello
  | Identifying
  | Resuming
  | Connected of { session_id : string; last_seq : int option }
  | Reconnect_pending of { backoff_until_mono : float; resumable : bool }
  | Failed of string

(* ── Inputs and effects ────────────────────────────────────────── *)

type input =
  | Connect_requested
  | Frame_received of frame
  | Frame_parse_error of string
  | Wss_closed of { code : int; reason : string }
  | Heartbeat_tick
  | Heartbeat_ack_timeout
  | Backoff_elapsed

type gateway_effect =
  | Open_wss of { url : string }
  | Close_wss of { code : int; reason : string }
  | Send_frame of frame
  | Schedule_heartbeat of { interval_ms : int }
  | Schedule_backoff of { delay_ms : int }
  | Emit_event of dispatched_event
  | Log of { level : [ `Info | `Warn | `Error ]; message : string }

(* ── Config ────────────────────────────────────────────────────── *)

type trigger_policy =
  | Mention_only
  | User_only of string
  | All

type config =
  { token : string
  ; intents : intent list
  ; bot_user_id : string option
  ; trigger_policy : trigger_policy
  }

let parse_trigger_policy s =
  match s with
  | "mention_only" -> Ok Mention_only
  | "all" -> Ok All
  | _ when String.length s > 10 && String.sub s 0 10 = "user_only:" ->
      let id = String.sub s 10 (String.length s - 10) in
      if id = "" then Error "user_only:<id> requires non-empty id"
      else Ok (User_only id)
  | _ ->
      Error
        (Printf.sprintf
           "unknown trigger policy %S — expected mention_only | user_only:<id> | all"
           s)

(* ── Opaque state ──────────────────────────────────────────────── *)

let gateway_url = "wss://gateway.discord.gg/?v=10&encoding=json"

type t =
  { state : connection_state
  ; config : config
  ; reconnect_attempts : int        (* Exponential backoff in Phase 1.4. *)
  ; last_seq : int option           (* Latest dispatch sequence number. *)
  ; heartbeat_interval_ms : int option  (* From Op_hello, used by Heartbeat_tick. *)
  ; resume_gateway_url : string option  (* From READY, used by Resuming in Phase 1.4. *)
  }

let create ~config =
  { state = Disconnected
  ; config
  ; reconnect_attempts = 0
  ; last_seq = None
  ; heartbeat_interval_ms = None
  ; resume_gateway_url = None
  }

let state t = t.state
let config t = t.config

(* ── JSON helpers (internal) ───────────────────────────────────── *)

let assoc_opt name = function
  | `Assoc fields -> List.assoc_opt name fields
  | _ -> None

let field_int_opt name json =
  match assoc_opt name json with
  | Some (`Int n) -> Some n
  | Some (`Intlit s) -> int_of_string_opt s
  | _ -> None

let field_string_opt name json =
  match assoc_opt name json with
  | Some (`String s) -> Some s
  | _ -> None

let field_bool_opt name json =
  match assoc_opt name json with
  | Some (`Bool b) -> Some b
  | _ -> None

(* ── Frame parse / encode ──────────────────────────────────────── *)

let parse_frame (json : Yojson.Safe.t) =
  match json with
  | `Assoc fields ->
      (match List.assoc_opt "op" fields with
       | None -> Error "frame: missing 'op' field"
       | Some (`Int op_int) ->
           (match opcode_of_int op_int with
            | Error e -> Error e
            | Ok op ->
                let s =
                  match List.assoc_opt "s" fields with
                  | Some (`Int n) -> Some n
                  | _ -> None
                in
                let t = field_string_opt "t" json in
                let d =
                  match List.assoc_opt "d" fields with
                  | Some v -> v
                  | None -> `Null
                in
                Ok { op; s; t; d })
       | Some _ -> Error "frame: 'op' field is not an integer")
  | _ -> Error "frame: top-level is not a JSON object"

let encode_frame (f : frame) : Yojson.Safe.t =
  let base = [ ("op", `Int (opcode_to_int f.op)); ("d", f.d) ] in
  let with_s =
    match f.s with Some n -> ("s", `Int n) :: base | None -> base
  in
  let with_t =
    match f.t with Some s -> ("t", `String s) :: with_s | None -> with_s
  in
  `Assoc with_t

(* ── Dispatch decoder ──────────────────────────────────────────── *)

let decode_ready ~payload =
  let session_id = field_string_opt "session_id" payload in
  let resume_gateway_url = field_string_opt "resume_gateway_url" payload in
  let user = assoc_opt "user" payload in
  let bot_user_id =
    match user with
    | Some user_json -> field_string_opt "id" user_json
    | None -> None
  in
  match session_id, resume_gateway_url, bot_user_id with
  | Some session_id, Some resume_gateway_url, Some bot_user_id ->
      Ok (Ready { session_id; resume_gateway_url; bot_user_id })
  | _ ->
      Error
        "READY payload: missing session_id / resume_gateway_url / user.id"

let decode_dispatch ~bot_user_id:_ ~event_name ~payload =
  match event_name with
  | "READY" -> decode_ready ~payload
  | "MESSAGE_CREATE" -> Error "MESSAGE_CREATE: not implemented (Phase 1.5)"
  | "MESSAGE_REACTION_ADD" ->
      Error "MESSAGE_REACTION_ADD: not implemented (Phase 1.5)"
  | other -> Ok (Ignored other)

(* ── Outbound frame builders (internal) ────────────────────────── *)

let identify_frame ~config =
  let intents = intents_bitmask config.intents in
  let properties =
    `Assoc
      [ ("os", `String "linux")
      ; ("browser", `String "masc-mcp")
      ; ("device", `String "masc-mcp")
      ]
  in
  let payload =
    `Assoc
      [ ("token", `String config.token)
      ; ("intents", `Int intents)
      ; ("compress", `Bool false)
      ; ("properties", properties)
      ]
  in
  { op = Op_identify; s = None; t = None; d = payload }

let heartbeat_frame ~last_seq =
  let d =
    match last_seq with
    | Some n -> `Int n
    | None -> `Null
  in
  { op = Op_heartbeat; s = None; t = None; d }

(* ── Transition function ────────────────────────────────────────

   Every [input] variant is matched explicitly. No catch-all arm.
   Adding a new [input] constructor is a compile-time error (-w +4)
   until this match is updated — that is the point. *)

let pending t phase =
  let msg = Printf.sprintf "Discord_gateway_state.step: %s pending" phase in
  ({ t with state = Failed msg }, [ Log { level = `Error; message = msg } ])

let log_warn t msg = (t, [ Log { level = `Warn; message = msg } ])
let log_info t msg = (t, [ Log { level = `Info; message = msg } ])
let no_op t = (t, [])

(* ── Per-opcode handlers (state-sensitive cases enumerate every
      connection_state variant; no [_] wildcards, so adding a state
      breaks the build at every relevant site — RFC-0203 §Non-goals). *)

let handle_hello t (frame : frame) =
  match t.state with
  | Awaiting_hello ->
      (match field_int_opt "heartbeat_interval" frame.d with
       | None ->
           log_warn t "Op_hello missing heartbeat_interval; staying in Awaiting_hello"
       | Some interval_ms ->
           let identify = identify_frame ~config:t.config in
           ( { t with
               state = Identifying
             ; heartbeat_interval_ms = Some interval_ms
             }
           , [ Schedule_heartbeat { interval_ms }
             ; Send_frame identify
             ; Log
                 { level = `Info
                 ; message =
                     Printf.sprintf "received Hello, identifying (heartbeat=%dms)"
                       interval_ms
                 }
             ] ))
  | Disconnected | Identifying | Resuming
  | Connected _ | Reconnect_pending _ | Failed _ ->
      log_warn t "Op_hello received in unexpected state; ignoring"

let handle_dispatch t (frame : frame) =
  let t' = { t with last_seq = frame.s } in
  match frame.t with
  | None -> log_warn t' "dispatch frame missing 't' (event name)"
  | Some event_name ->
      (match
         decode_dispatch
           ~bot_user_id:t.config.bot_user_id
           ~event_name
           ~payload:frame.d
       with
       | Error reason ->
           log_warn t'
             (Printf.sprintf "dispatch %s decode failed: %s" event_name reason)
       | Ok (Ready { session_id; resume_gateway_url; bot_user_id }) ->
           let new_config =
             { t'.config with bot_user_id = Some bot_user_id }
           in
           ( { t' with
               state = Connected { session_id; last_seq = frame.s }
             ; config = new_config
             ; resume_gateway_url = Some resume_gateway_url
             ; reconnect_attempts = 0
             }
           , [ Emit_event
                 (Ready { session_id; resume_gateway_url; bot_user_id })
             ; Log
                 { level = `Info
                 ; message = Printf.sprintf "READY (bot_user_id=%s)" bot_user_id
                 }
             ] )
       | Ok (Message_create _ as ev)
       | Ok (Reaction_add _ as ev) ->
           (t', [ Emit_event ev ])
       | Ok (Ignored _) ->
           no_op t')

let handle_server_heartbeat_demand t =
  ( t
  , [ Send_frame (heartbeat_frame ~last_seq:t.last_seq)
    ; Log
        { level = `Info; message = "server requested immediate heartbeat" }
    ] )

(* Sub-handler: incoming frame. Outer dispatch is by opcode (8-arm,
   no wildcard). State-sensitive opcodes delegate to per-opcode
   handlers that enumerate every state variant. *)
let step_frame t ~now_mono:_ (frame : frame) =
  match frame.op with
  | Op_hello -> handle_hello t frame
  | Op_dispatch -> handle_dispatch t frame
  | Op_heartbeat_ack -> no_op t
  | Op_heartbeat -> handle_server_heartbeat_demand t
  | Op_reconnect -> pending t "RFC-0203 Phase 1.4 (Op_reconnect)"
  | Op_invalid_session ->
      pending t "RFC-0203 Phase 1.4 (Op_invalid_session)"
  | Op_identify ->
      log_warn t "Op_identify received from server (unexpected)"
  | Op_resume ->
      log_warn t "Op_resume received from server (unexpected)"

(* ── Per-input handlers for state-sensitive non-frame inputs ── *)

let handle_connect_requested t =
  match t.state with
  | Disconnected ->
      ( { t with state = Awaiting_hello }
      , [ Open_wss { url = gateway_url }
        ; Log
            { level = `Info; message = "connecting to Discord Gateway" }
        ] )
  | Awaiting_hello | Identifying | Resuming
  | Connected _ | Reconnect_pending _ | Failed _ ->
      log_warn t "Connect_requested in non-Disconnected state; ignoring"

let handle_heartbeat_tick t =
  match t.state with
  | Connected _ | Identifying | Resuming ->
      (t, [ Send_frame (heartbeat_frame ~last_seq:t.last_seq) ])
  | Disconnected | Awaiting_hello
  | Reconnect_pending _ | Failed _ ->
      log_info t "Heartbeat_tick in pre-connection state; skipping"

let step t ~now_mono input =
  match input with
  | Connect_requested -> handle_connect_requested t
  | Frame_received frame -> step_frame t ~now_mono frame
  | Frame_parse_error reason ->
      log_warn t (Printf.sprintf "frame parse error: %s" reason)
  | Wss_closed _ -> pending t "RFC-0203 Phase 1.4 (Wss_closed)"
  | Heartbeat_tick -> handle_heartbeat_tick t
  | Heartbeat_ack_timeout ->
      pending t "RFC-0203 Phase 1.4 (Heartbeat_ack_timeout)"
  | Backoff_elapsed -> pending t "RFC-0203 Phase 1.4 (Backoff_elapsed)"
