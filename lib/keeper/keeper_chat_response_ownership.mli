(** Keeper_chat_response_ownership — which response owns streamed text bytes.

    The bridge tags every [Text_delta] with the response it belongs to.
    Connectors (Slack, Discord) accumulate accepted deltas into one channel
    message, so without the ownership rules the transcript applies
    (bin/masc_tui_keeper_chat_transcript.ml), a delayed delta from a
    superseded response is appended after a failover clear and reaches the
    delivered reply. This module is those rules, shared between the
    connectors so both drop the same bytes. *)

type t

type admission =
  | Admitted  (** owned bytes of the newest admitted response; append them *)
  | Preserved_unobserved
      (** bytes without a usable owner: append them without touching
          ownership *)
  | Stale  (** owned by a superseded response: drop the bytes *)

val create : unit -> t

val admit : t -> Keeper_chat_events.text_response -> admission

val retire_attempt : t -> unit
(** An advancing runtime attempt starts a newer response: the admitted owner
    is demoted to the stale floor (its identity and anything older can no
    longer append), and ownership tracking restarts empty. *)
