(** Response text finalization for keeper agent runs. *)

type finalized = {
  response_text : string;
      (** What the keeper said, trimmed. Blank only when the model produced no
          text.

          A turn whose text is kept out of replay still carries it here.
          Blanking it was one decision standing for two different questions --
          whether the words re-enter model history, and whether the operator
          who asked ever sees them -- and the second answer was wrong for a
          direct question: the asker got an empty row while the raw trace still
          held up to 1,354 characters of reply (masc #32727, #32660). Replay is
          answered by [withheld_from_replay] and by the stop reason, neither of
          which reads this string. *)
  withheld_from_replay : bool;
      (** This turn's words must not re-enter model history. *)
}

(** [true] for typed control checkpoints and no-output execution observations
    that must not put this turn's words back into model history. Their state
    remains observable through typed stop/event surfaces. *)
val stop_reason_suppresses_visible_response : Runtime_agent.stop_reason -> bool

val finalize :
  stop_reason:Runtime_agent.stop_reason ->
  raw_response_text:string ->
  ?suppress_response_text:bool ->
  unit ->
  finalized
(** [suppress_response_text] overrides the stop-reason answer for a turn whose
    external effect already went out under a [Completed] stop. It selects
    [withheld_from_replay]; it does not erase [response_text]. *)
