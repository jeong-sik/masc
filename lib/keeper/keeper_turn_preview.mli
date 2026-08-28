(** Live preview of the turn a keeper is running.

    The [@] Answering overlay asks "what is it doing right now?"; the durable
    stores cannot answer until the turn commits. This plane holds, per
    keeper, the tail of the latest agent-core response text and the tool call
    in flight — written by the agent-core hooks, read by the turns
    projection. Process memory (a glance, not truth): entries survive turn
    end unread, because the consumer only projects a preview while the Owner
    reports a running turn. *)

type t =
  { text_tail : string
        (** Last {!tail_bytes} of the newest response text, cut on a UTF-8
            boundary. [""] when the turn has produced no text yet. *)
  ; current_tool : string option
        (** The tool call in flight ([PreToolUse] sets it, [PostToolUse]
            clears it), or [None] between calls. *)
  ; updated_at : float
  }

val tail_bytes : int

val current : keeper_name:string -> t option

val note_text : keeper_name:string -> now:float -> string -> unit
(** Record the newest response text's tail. Blank text is ignored — a
    tool-only turn must not erase the last visible words. *)

val note_tool : keeper_name:string -> now:float -> string option -> unit
