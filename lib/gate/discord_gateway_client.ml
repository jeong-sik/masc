(* RFC-0203 Phase 1.1 — I/O wrapper around Discord_gateway_state.

   Implementation lives in Phase 1.2 onwards. The skeleton below
   only proves the types line up. *)

type intent = Discord_gateway_state.intent =
  | Guilds
  | Guild_messages
  | Message_content
  | Guild_message_reactions
  | Direct_messages
  | Direct_message_reactions

type gateway_event = Discord_gateway_state.dispatched_event =
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

type trigger_policy = Discord_gateway_state.trigger_policy =
  | Mention_only
  | User_only of string
  | All

let intents_bitmask = Discord_gateway_state.intents_bitmask

let run
    ~sw:_
    ~env:_
    ~token:_
    ~intents:_
    ~trigger_policy:_
    ~on_event:_
    () =
  failwith
    "Discord_gateway_client.run: not implemented (RFC-0203 Phase 1.2 — WSS handshake)"
