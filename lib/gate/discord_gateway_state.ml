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

type t =
  { state : connection_state
  ; config : config
  ; reconnect_attempts : int  (* For exponential backoff in Phase 1.4. *)
  }

let create ~config =
  { state = Disconnected; config; reconnect_attempts = 0 }

let state t = t.state
let config t = t.config

(* ── Transition function ────────────────────────────────────────

   Every [input] variant is matched explicitly. No catch-all arm.
   Adding a new [input] constructor is a compile-time error (-w +4)
   until this match is updated — that is the point. *)

let step t ~now_mono:_ input =
  let pending phase =
    let msg =
      Printf.sprintf "Discord_gateway_state.step: %s pending" phase
    in
    ( { t with state = Failed msg }
    , [ Log { level = `Error; message = msg } ] )
  in
  match input with
  | Connect_requested -> pending "RFC-0203 Phase 1.2"
  | Frame_received _ -> pending "RFC-0203 Phase 1.2 / 1.3 / 1.4 / 1.5"
  | Frame_parse_error reason ->
      ( t
      , [ Log
            { level = `Warn
            ; message = Printf.sprintf "frame parse error: %s" reason
            }
        ] )
  | Wss_closed _ -> pending "RFC-0203 Phase 1.4"
  | Heartbeat_tick -> pending "RFC-0203 Phase 1.2"
  | Heartbeat_ack_timeout -> pending "RFC-0203 Phase 1.4"
  | Backoff_elapsed -> pending "RFC-0203 Phase 1.4"

(* ── Frame parse / encode ──────────────────────────────────────── *)

let parse_frame (_json : Yojson.Safe.t) =
  Error "Discord_gateway_state.parse_frame: not implemented (Phase 1.2)"

let encode_frame (_f : frame) : Yojson.Safe.t =
  failwith "Discord_gateway_state.encode_frame: not implemented (Phase 1.2)"

let decode_dispatch ~bot_user_id:_ ~event_name:_ ~payload:_ =
  Error "Discord_gateway_state.decode_dispatch: not implemented (Phase 1.5)"
