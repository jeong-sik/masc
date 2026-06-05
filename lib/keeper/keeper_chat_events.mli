(** Keeper_chat_events — channel-agnostic event bus for keeper chat turns.

    Decouples turn processing from delivery. Each turn gets its own
    event stream instance; adapters consume events and translate to
    channel-specific protocols (SSE, Discord REST, Slack REST).

    @since 2.145.0 *)

(** {1 Types} *)

type role = User | Assistant

type keeper_chat_event =
  | Run_started of { run_id : string; thread_id : string }
  | Text_message_start of { message_id : string; role : role }
  | Text_delta of string
  | Text_message_end
  | Run_finished of { run_id : string }
  | Error of { message : string }
  | Custom of { name : string; value : Yojson.Safe.t }

(** {1 Stream operations} *)

(** [create ()] returns a new bounded event stream.
    Each turn should create its own stream instance. *)
val create : unit -> keeper_chat_event Eio.Stream.t

(** [publish stream event] adds [event] to the stream.
    Non-blocking; raises if the stream is full (backpressure). *)
val publish : keeper_chat_event Eio.Stream.t -> keeper_chat_event -> unit

(** [subscribe stream] blocks until an event is available, then returns it. *)
val subscribe : keeper_chat_event Eio.Stream.t -> keeper_chat_event
