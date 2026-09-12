(** Ephemeral activity for the running Keeper turn. Reset at turn entry;
    the turns route also rejects observations older than its running turn.
    Provider attempts, stream events, and tool hooks write this projection. *)

type activity = Preparing | Awaiting_response | Receiving_response | Failed

type t =
  { text_tail : string
        (** Last {!tail_bytes} of the newest response text, cut on a UTF-8
            boundary. [""] when the turn has produced no text yet. *)
  ; current_tool : string option
        (** The tool call in flight ([PreToolUse] sets it, [PostToolUse]
            clears it), or [None] between calls. *)
  ; updated_at : float
  ; runtime_id : string option
  ; activity : activity
  ; last_failure : string option
  }

val tail_bytes : int

val current : keeper_name:string -> t option

val note_text : keeper_name:string -> now:float -> string -> unit
(** Record the newest response text's tail. Blank text is ignored — a
    tool-only turn must not erase the last visible words. *)

val note_tool : keeper_name:string -> now:float -> string option -> unit

val reset : keeper_name:string -> now:float -> unit
val note_attempt : keeper_name:string -> now:float -> runtime_id:string -> unit
val note_failure : keeper_name:string -> now:float -> runtime_id:string -> string -> unit
val note_stream : keeper_name:string -> now:float -> Agent_core.Types.sse_event -> unit
val status_text : t -> string
