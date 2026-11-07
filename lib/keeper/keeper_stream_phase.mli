(** The phases of one provider message stream, and what each phase allows.

    A provider message accepts content until its first stop reason. The stop
    reason is recorded once and may be replayed. [MessageStop] ends the message.
    The SSE bridge and the tool accumulator read the same events and enforce the
    same order, so the order is written here once. *)

type t =
  | Accepting_content
  | Stop_reason_seen of Agent_core.Types.stop_reason
  | Message_stopped

val admits_new_content : t -> bool
(** [MessageStart], [ContentBlockStart] and [ContentBlockDelta] are accepted
    only before the first stop reason. *)

val admits_trailing_events : t -> bool
(** [ContentBlockStop] and tool progress are accepted until the message stops,
    so a block that was open at the stop reason can still close. *)

(** What a [MessageDelta] means in the current phase. *)
type stop_reason_event =
  | Stop_reason_unchanged
      (** No stop reason in the delta, or the recorded one replayed. *)
  | Stop_reason_first of Agent_core.Types.stop_reason
      (** The first stop reason. The phase becomes [Stop_reason_seen]. *)
  | Stop_reason_conflict
      (** A different stop reason, or any stop reason after the message
          stopped. *)

val on_stop_reason : t -> Agent_core.Types.stop_reason option -> stop_reason_event

(** What a [MessageStop] means in the current phase. *)
type message_stop_event =
  | Message_stop_replayed  (** The message had already stopped. *)
  | Message_stop_without_reason
      (** The message stopped before any stop reason arrived. *)
  | Message_stop_after_reason  (** The usual end, after a recorded stop reason. *)

val on_message_stop : t -> message_stop_event
