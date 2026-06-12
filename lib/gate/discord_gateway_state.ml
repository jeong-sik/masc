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
      ; guild_id : string option
      ; message_id : string
      ; author_id : string
      ; author_name : string option
      ; content : string
      ; mention_user_ids : string list
            (* RFC-0232 §3.3: the structured [mentions] member ids are
               kept at decode instead of being reduced to a bot bool;
               the gate maps what its bindings can resolve. *)
      ; mentions_bot : bool
      ; explicit_mentions_bot : bool
      ; message_reference_channel_id : string option
      ; message_reference_message_id : string option
      ; referenced_message_author_id : string option
      }
  | Reaction_add of
      { channel_id : string
      ; message_id : string
      ; user_id : string
      ; emoji : string
      }
  | Thread_tracked of
      { thread_id : string
      ; parent_channel_id : string
      }
      (** Discord thread discovered via THREAD_CREATE dispatch. The I/O
          layer uses this to populate binding-resolution registries;
          the state machine stores it in [thread_parents] for
          [Mention_or_thread] trigger policy evaluation. *)
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
  | Emit_ambient of dispatched_event
  | Log of { level : [ `Info | `Warn | `Error ]; message : string }

(* ── Config ────────────────────────────────────────────────────── *)

type trigger_policy =
  | Mention_only
  | Mention_or_thread
      (** Mention in regular channels, auto-respond in Discord threads.
          Threads are identified by the [thread_parents] registry in [t]. *)
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
  | "mention_or_thread" -> Ok Mention_or_thread
  | "all" -> Ok All
  | _ when String.length s > 10 && String.sub s 0 10 = "user_only:" ->
      let id = String.sub s 10 (String.length s - 10) in
      if id = "" then Error "user_only:<id> requires non-empty id"
      else Ok (User_only id)
  | _ ->
      Error
        (Printf.sprintf
           "unknown trigger policy %S — expected mention_only | mention_or_thread | user_only:<id> | all"
           s)

(* ── Opaque state ──────────────────────────────────────────────── *)

let gateway_url = "wss://gateway.discord.gg/?v=10&encoding=json"

module StringMap = Map.Make (String)

type t =
  { state : connection_state
  ; config : config
  ; reconnect_attempts : int        (* Exponential backoff exponent. *)
  ; last_seq : int option           (* Latest dispatch sequence number. *)
  ; heartbeat_interval_ms : int option  (* From Op_hello, used by Heartbeat_tick. *)
  ; resume_gateway_url : string option  (* From READY, used by Resuming. *)
  ; resume_context : (string * int option) option
    (* (session_id, last_seq_at_disconnect). Set when leaving Connected
       via a resumable disconnect; cleared on fresh identify path. Lets
       handle_hello choose Identify vs Resume after Awaiting_hello. *)
  ; thread_parents : string StringMap.t
    (* thread_id -> parent_channel_id. Populated by THREAD_CREATE
       dispatches. Used by [Mention_or_thread] trigger policy to
       auto-accept messages in known threads without @mention. *)
  }

let create ~config =
  { state = Disconnected
  ; config
  ; reconnect_attempts = 0
  ; last_seq = None
  ; heartbeat_interval_ms = None
  ; resume_gateway_url = None
  ; resume_context = None
  ; thread_parents = StringMap.empty
  }

let state t = t.state
let config t = t.config

(* ── JSON helpers (internal) ───────────────────────────────────── *)

let assoc_opt = Json_util.assoc_member_opt

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

let contains_substring ~needle haystack =
  let needle_len = String.length needle in
  let haystack_len = String.length haystack in
  if needle_len = 0 then true
  else if needle_len > haystack_len then false
  else
    let rec loop i =
      if i + needle_len > haystack_len then false
      else if String.sub haystack i needle_len = needle then true
      else loop (i + 1)
    in
    loop 0

let content_mentions_user ~user_id content =
  let user_id = String.trim user_id in
  user_id <> ""
  && (contains_substring ~needle:("<@" ^ user_id ^ ">") content
      || contains_substring ~needle:("<@!" ^ user_id ^ ">") content)

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

let decode_message_create ~bot_user_id ~payload =
  let channel_id = field_string_opt "channel_id" payload in
  let guild_id = field_string_opt "guild_id" payload in
  let message_id = field_string_opt "id" payload in
  let content =
    match field_string_opt "content" payload with
    | Some s -> s
    | None -> ""
  in
  let author = assoc_opt "author" payload in
  let author_id =
    match author with
    | Some a -> field_string_opt "id" a
    | None -> None
  in
  (* RFC-0223 P1: [global_name] is the user-facing display name and is
     nullable; [username] is the unique handle and always present on
     real payloads. Prefer the display name. *)
  let author_name =
    match author with
    | None -> None
    | Some a -> (
        match field_string_opt "global_name" a with
        | Some _ as name -> name
        | None -> field_string_opt "username" a)
  in
  let mention_user_ids =
    match assoc_opt "mentions" payload with
    | Some (`List items) ->
        List.filter_map (fun item -> field_string_opt "id" item) items
    | Some _ | None -> []
  in
  let mentions_bot =
    match bot_user_id with
    | None -> false
    | Some bot_id -> List.exists (String.equal bot_id) mention_user_ids
  in
  let explicit_mentions_bot =
    match bot_user_id with
    | None -> false
    | Some bot_id -> content_mentions_user ~user_id:bot_id content
  in
  let message_reference = assoc_opt "message_reference" payload in
  let message_reference_channel_id =
    match message_reference with
    | Some json -> field_string_opt "channel_id" json
    | None -> None
  in
  let message_reference_message_id =
    match message_reference with
    | Some json -> field_string_opt "message_id" json
    | None -> None
  in
  let referenced_message_author_id =
    match assoc_opt "referenced_message" payload with
    | Some referenced -> (
        match assoc_opt "author" referenced with
        | Some author -> field_string_opt "id" author
        | None -> None)
    | None -> None
  in
  match channel_id, message_id, author_id with
  | Some channel_id, Some message_id, Some author_id ->
      Ok
        (Message_create
           { channel_id
           ; message_id
           ; guild_id
           ; author_id
           ; author_name
           ; content
           ; mention_user_ids
           ; mentions_bot
           ; explicit_mentions_bot
           ; message_reference_channel_id
           ; message_reference_message_id
           ; referenced_message_author_id
           })
  | _ ->
      Error "MESSAGE_CREATE payload: missing channel_id / id / author.id"

let decode_reaction_add ~payload =
  let channel_id = field_string_opt "channel_id" payload in
  let message_id = field_string_opt "message_id" payload in
  let user_id = field_string_opt "user_id" payload in
  let emoji =
    match assoc_opt "emoji" payload with
    | None -> None
    | Some emoji_json ->
        let name = field_string_opt "name" emoji_json in
        let id = field_string_opt "id" emoji_json in
        (match name, id with
         | Some n, None -> Some n
         | Some n, Some i -> Some (Printf.sprintf "%s:%s" n i)
         | None, _ -> None)
  in
  match channel_id, message_id, user_id, emoji with
  | Some channel_id, Some message_id, Some user_id, Some emoji ->
      Ok (Reaction_add { channel_id; message_id; user_id; emoji })
  | _ ->
      Error
        "MESSAGE_REACTION_ADD payload: missing channel_id / message_id / \
         user_id / emoji.name"

let decode_thread_create ~payload =
  let thread_id = field_string_opt "id" payload in
  let parent_channel_id = field_string_opt "parent_id" payload in
  match thread_id, parent_channel_id with
  | Some thread_id, Some parent_channel_id ->
      if String.equal (String.trim thread_id) ""
         || String.equal (String.trim parent_channel_id) ""
      then Ok (Ignored "THREAD_CREATE: empty id or parent_id")
      else Ok (Thread_tracked { thread_id; parent_channel_id })
  | _ -> Ok (Ignored "THREAD_CREATE: missing id or parent_id")

let decode_dispatch ~bot_user_id ~event_name ~payload =
  match event_name with
  | "READY" -> decode_ready ~payload
  | "MESSAGE_CREATE" -> decode_message_create ~bot_user_id ~payload
  | "MESSAGE_REACTION_ADD" -> decode_reaction_add ~payload
  | "THREAD_CREATE" | "THREAD_UPDATE" -> decode_thread_create ~payload
  | other -> Ok (Ignored other)

(* ── Trigger policy filters ────────────────────────────────────────

   Two functions, one per event type. Each exhaustively matches over
   [trigger_policy]; adding a new policy variant breaks both bodies
   at compile time. Reactions in [Mention_only] are deliberately
   suppressed (the "quiet, mention-triggered bot" default), per
   RFC-0203 §Shape interpretation. *)

(* Self-skip guard: an inbound event whose actor is the bot itself
   is always suppressed, regardless of trigger policy. [Mention_only]
   is naturally safe — the bot doesn't @itself — but [All] accepts
   everything and [User_only id] can collide with [bot_user_id] (the
   operator pastes the wrong snowflake), so the guard is unconditional
   to make the self-reply-loop class of bug structurally impossible. *)
let is_self ~bot_user_id actor_id =
  match bot_user_id with
  | Some self -> String.equal self actor_id
  | None -> false

let message_passes_policy policy ~bot_user_id ~author_id ~explicit_mentions_bot
      ~is_thread =
  if is_self ~bot_user_id author_id then false
  else
    match policy with
    | All -> true
    | Mention_only -> explicit_mentions_bot
    | Mention_or_thread -> explicit_mentions_bot || is_thread
    | User_only id -> String.equal author_id id

let reaction_passes_policy policy ~bot_user_id ~user_id =
  if is_self ~bot_user_id user_id then false
  else
    match policy with
    | All -> true
    | Mention_only -> false
    | Mention_or_thread -> false
    | User_only id -> String.equal user_id id

(* ── Outbound frame builders (internal) ────────────────────────── *)

let identify_frame ~config =
  let intents = intents_bitmask config.intents in
  let properties =
    `Assoc
      [ ("os", `String "linux")
      ; ("browser", `String "masc")
      ; ("device", `String "masc")
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

let resume_frame ~config ~session_id ~last_seq =
  let payload =
    `Assoc
      [ ("token", `String config.token)
      ; ("session_id", `String session_id)
      ; ("seq", (match last_seq with Some n -> `Int n | None -> `Int 0))
      ]
  in
  { op = Op_resume; s = None; t = None; d = payload }

(* Discord close codes that prohibit reconnect. Source: Discord
   Developer Docs — Gateway Close Event Codes. *)
let is_fatal_close_code = function
  | 4004 (* authentication failed *)
  | 4010 (* invalid shard *)
  | 4011 (* sharding required *)
  | 4012 (* invalid API version *)
  | 4013 (* invalid intents *)
  | 4014 (* disallowed intents *) -> true
  | _ -> false

(* Exponential backoff capped at 60s. attempts=0 -> 1s, 1 -> 2s, ... 6+
   capped. Intentionally deterministic (no jitter) so the state
   machine remains testable; jitter belongs in the I/O layer if added
   later. *)
let backoff_ms ~attempts =
  let base = 1_000 in
  let cap = 60_000 in
  let shift = min attempts 6 in
  min cap (base * Int.shift_left 1 shift)

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
           (* Branch on resume_context: if set, send Op_resume and
              enter Resuming; else send Op_identify and enter
              Identifying. Both paths schedule the same heartbeat. *)
           let outbound_frame, next_state, log_msg =
             match t.resume_context with
             | Some (session_id, last_seq) ->
                 ( resume_frame ~config:t.config ~session_id ~last_seq
                 , Resuming
                 , Printf.sprintf
                     "received Hello, resuming session %s (heartbeat=%dms)"
                     session_id interval_ms )
             | None ->
                 ( identify_frame ~config:t.config
                 , Identifying
                 , Printf.sprintf
                     "received Hello, identifying (heartbeat=%dms)"
                     interval_ms )
           in
           ( { t with
               state = next_state
             ; heartbeat_interval_ms = Some interval_ms
             }
           , [ Schedule_heartbeat { interval_ms }
             ; Send_frame outbound_frame
             ; Log { level = `Info; message = log_msg }
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
             ; resume_context = None
             }
           , [ Emit_event
                 (Ready { session_id; resume_gateway_url; bot_user_id })
             ; Log
                 { level = `Info
                 ; message = Printf.sprintf "READY (bot_user_id=%s)" bot_user_id
                 }
             ] )
       | Ok (Message_create { channel_id; author_id; explicit_mentions_bot; _ } as ev) ->
           let is_thread = StringMap.mem channel_id t'.thread_parents in
           if
             message_passes_policy t'.config.trigger_policy
               ~bot_user_id:t'.config.bot_user_id ~author_id
               ~explicit_mentions_bot ~is_thread
           then (t', [ Emit_event ev ])
           else if is_self ~bot_user_id:t'.config.bot_user_id author_id
           then
             (* The bot's own echo: its outbound is persisted at send
                time (keeper_surface_post / gate reply); recording the
                gateway echo would double-record by another route. *)
             no_op t'
           else
             (* RFC-0226: policy decides turn start only. A message
                that fails the trigger policy is still conversation
                in a channel the bot sits in — deliver it for
                record-only handling. *)
             (t', [ Emit_ambient ev ])
       | Ok (Reaction_add { user_id; _ } as ev) ->
           if
             reaction_passes_policy t'.config.trigger_policy
               ~bot_user_id:t'.config.bot_user_id ~user_id
           then (t', [ Emit_event ev ])
           else no_op t'
       | Ok (Thread_tracked { thread_id; parent_channel_id } as ev) ->
           let thread_parents' =
             StringMap.add thread_id parent_channel_id t'.thread_parents
           in
           ( { t' with thread_parents = thread_parents' }
           , [ Emit_event ev
             ; Log
                 { level = `Info
                 ; message =
                     Printf.sprintf
                       "thread tracked: %s -> parent %s"
                       thread_id parent_channel_id
                 }
             ] )
       | Ok (Ignored "RESUMED") ->
           (* Successful resume — server has replayed missed events
              and signalled completion. Recover session_id from
              resume_context and return to Connected. *)
           (match t'.state, t'.resume_context with
            | Resuming, Some (session_id, _) ->
                ( { t' with
                    state = Connected { session_id; last_seq = frame.s }
                  ; reconnect_attempts = 0
                  ; resume_context = None
                  }
                , [ Log
                      { level = `Info
                      ; message =
                          Printf.sprintf "RESUMED session %s" session_id
                      }
                  ] )
            | (Disconnected | Awaiting_hello | Identifying | Resuming
              | Connected _ | Reconnect_pending _ | Failed _), _ ->
                log_warn t'
                  "RESUMED dispatch outside Resuming state; ignoring")
       | Ok (Ignored _) ->
           no_op t')

let handle_server_heartbeat_demand t =
  ( t
  , [ Send_frame (heartbeat_frame ~last_seq:t.last_seq)
    ; Log
        { level = `Info; message = "server requested immediate heartbeat" }
    ] )

(* ── Reconnect / resume helpers ───────────────────────────────────

   Builds a Reconnect_pending state + Schedule_backoff effect with
   the right resume_context. Used by every "we need to reconnect now"
   handler (Wss_closed, Heartbeat_ack_timeout, Op_reconnect,
   Op_invalid_session). *)

let make_reconnect_pending t ~now_mono ~delay_ms ~resumable ~resume_context =
  let backoff_until_mono = now_mono +. (float_of_int delay_ms /. 1000.0) in
  { t with
    state = Reconnect_pending { backoff_until_mono; resumable }
  ; reconnect_attempts = t.reconnect_attempts + 1
  ; resume_context
  }

(* Captures session context (if any) when leaving Connected. Pre-
   connection states have no session yet, so we fall back to [None]. *)
let capture_resume_context t =
  match t.state with
  | Connected { session_id; last_seq } -> Some (session_id, last_seq)
  | Resuming -> t.resume_context  (* preserve in-flight resume context *)
  | Disconnected | Awaiting_hello | Identifying
  | Reconnect_pending _ | Failed _ -> None

let handle_wss_closed t ~now_mono ~code ~reason =
  match t.state with
  | Disconnected | Reconnect_pending _ | Failed _ ->
      log_warn t
        (Printf.sprintf
           "Wss_closed (%d %s) in non-connection state; ignoring"
           code reason)
  | Awaiting_hello | Identifying | Resuming | Connected _ ->
      if is_fatal_close_code code then
        ( { t with
            state =
              Failed
                (Printf.sprintf "Discord fatal close %d: %s" code reason)
          ; resume_context = None
          }
        , [ Log
              { level = `Error
              ; message =
                  Printf.sprintf
                    "Discord fatal close %d (%s); not reconnecting"
                    code reason
              }
          ] )
      else
        let resume_context = capture_resume_context t in
        let resumable = Option.is_some resume_context in
        let delay_ms = backoff_ms ~attempts:t.reconnect_attempts in
        let t' =
          make_reconnect_pending t ~now_mono ~delay_ms ~resumable
            ~resume_context
        in
        ( t'
        , [ Schedule_backoff { delay_ms }
          ; Log
              { level = `Warn
              ; message =
                  Printf.sprintf
                    "WSS closed %d (%s); reconnect in %dms (resumable=%b)"
                    code reason delay_ms resumable
              }
          ] )

let handle_heartbeat_ack_timeout t ~now_mono =
  match t.state with
  | Connected _ ->
      let resume_context = capture_resume_context t in
      let delay_ms = backoff_ms ~attempts:t.reconnect_attempts in
      let t' =
        make_reconnect_pending t ~now_mono ~delay_ms ~resumable:true
          ~resume_context
      in
      ( t'
      , [ Close_wss { code = 4000; reason = "heartbeat ack timeout" }
        ; Schedule_backoff { delay_ms }
        ; Log
            { level = `Warn
            ; message =
                Printf.sprintf
                  "heartbeat ack timeout; closing and resuming in %dms"
                  delay_ms
            }
        ] )
  | Disconnected | Awaiting_hello | Identifying | Resuming
  | Reconnect_pending _ | Failed _ ->
      log_warn t
        "Heartbeat_ack_timeout outside Connected state; ignoring"

let handle_backoff_elapsed t =
  match t.state with
  | Reconnect_pending { resumable = true; _ } ->
      (* Resumable path. Need a resume URL; if missing, defensively
         fall through to fresh identify. *)
      (match t.resume_gateway_url, t.resume_context with
       | Some url, Some _ ->
           ( { t with state = Awaiting_hello }
           , [ Open_wss { url }
             ; Log
                 { level = `Info
                 ; message =
                     Printf.sprintf "backoff elapsed; resuming via %s" url
                 }
             ] )
       | _ ->
           ( { t with state = Awaiting_hello; resume_context = None }
           , [ Open_wss { url = gateway_url }
             ; Log
                 { level = `Warn
                 ; message =
                     "backoff elapsed; resumable but missing context, \
                      starting fresh identify"
                 }
             ] ))
  | Reconnect_pending { resumable = false; _ } ->
      ( { t with state = Awaiting_hello; resume_context = None }
      , [ Open_wss { url = gateway_url }
        ; Log
            { level = `Info
            ; message = "backoff elapsed; starting fresh identify"
            }
        ] )
  | Disconnected | Awaiting_hello | Identifying | Resuming
  | Connected _ | Failed _ ->
      log_warn t "Backoff_elapsed outside Reconnect_pending; ignoring"

let handle_op_reconnect t ~now_mono =
  match t.state with
  | Identifying | Resuming | Connected _ ->
      let resume_context = capture_resume_context t in
      let resumable = Option.is_some resume_context in
      let delay_ms = backoff_ms ~attempts:t.reconnect_attempts in
      let t' =
        make_reconnect_pending t ~now_mono ~delay_ms ~resumable
          ~resume_context
      in
      ( t'
      , [ Close_wss { code = 1000; reason = "server requested reconnect" }
        ; Schedule_backoff { delay_ms }
        ; Log
            { level = `Info
            ; message =
                Printf.sprintf
                  "server requested reconnect; closing and reconnecting in %dms"
                  delay_ms
            }
        ] )
  | Disconnected | Awaiting_hello | Reconnect_pending _ | Failed _ ->
      log_warn t "Op_reconnect in unexpected state; ignoring"

let handle_op_invalid_session t ~now_mono (frame : frame) =
  let resumable_payload =
    match frame.d with
    | `Bool b -> b
    | _ -> false
  in
  match t.state with
  | Identifying | Resuming | Connected _ ->
      let resume_context =
        if resumable_payload then capture_resume_context t else None
      in
      let resumable = Option.is_some resume_context in
      (* Discord docs: when invalid_session(resumable=true), back off
         1-5s before sending Resume. We pick a deterministic mid-range
         1500ms so the state machine stays test-driveable. *)
      let delay_ms =
        if resumable then 1_500
        else backoff_ms ~attempts:t.reconnect_attempts
      in
      let attempts_next =
        if resumable then t.reconnect_attempts else 0
      in
      let backoff_until_mono =
        now_mono +. (float_of_int delay_ms /. 1000.0)
      in
      ( { t with
          state = Reconnect_pending { backoff_until_mono; resumable }
        ; reconnect_attempts = attempts_next
        ; resume_context
        }
      , [ Close_wss { code = 1000; reason = "invalid session" }
        ; Schedule_backoff { delay_ms }
        ; Log
            { level = `Warn
            ; message =
                Printf.sprintf
                  "invalid_session (server resumable=%b); reconnect in %dms (resumable=%b)"
                  resumable_payload delay_ms resumable
            }
        ] )
  | Disconnected | Awaiting_hello | Reconnect_pending _ | Failed _ ->
      log_warn t "Op_invalid_session in unexpected state; ignoring"

(* Sub-handler: incoming frame. Outer dispatch is by opcode (8-arm,
   no wildcard). State-sensitive opcodes delegate to per-opcode
   handlers that enumerate every state variant. *)
let step_frame t ~now_mono (frame : frame) =
  match frame.op with
  | Op_hello -> handle_hello t frame
  | Op_dispatch -> handle_dispatch t frame
  | Op_heartbeat_ack -> no_op t
  | Op_heartbeat -> handle_server_heartbeat_demand t
  | Op_reconnect -> handle_op_reconnect t ~now_mono
  | Op_invalid_session -> handle_op_invalid_session t ~now_mono frame
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
  | Wss_closed { code; reason } ->
      handle_wss_closed t ~now_mono ~code ~reason
  | Heartbeat_tick -> handle_heartbeat_tick t
  | Heartbeat_ack_timeout -> handle_heartbeat_ack_timeout t ~now_mono
  | Backoff_elapsed -> handle_backoff_elapsed t
