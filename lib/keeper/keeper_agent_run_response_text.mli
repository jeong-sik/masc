(** Response text finalization for keeper agent runs. *)

type finalized = {
  response_text : string;
}

(** Deterministic acknowledgement emitted for a Gate-deferred external effect.
    This is a user-facing completion for the originating chat request; the
    effect result itself is delivered by the later durable resolution. *)
val external_effect_deferred_acknowledgement : string

(** [true] for typed control checkpoints and no-output execution observations
    that must not manufacture a chat reply. Their state remains observable
    through typed stop/event surfaces. *)
val stop_reason_suppresses_visible_response : Runtime_agent.stop_reason -> bool

val finalize :
  stop_reason:Runtime_agent.stop_reason ->
  raw_response_text:string ->
  ?suppress_response_text:bool ->
  unit ->
  finalized
