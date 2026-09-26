(** Ephemeral activity for the running Keeper turn. Reset at turn entry;
    the turns route also rejects observations older than its running turn.
    Provider attempts, stream events, and tool hooks write this projection. *)

type activity = Preparing | Awaiting_response | Receiving_response | Tool_observed | Failed

type t =
  { text_tail : string
        (** Last {!tail_bytes} of the newest response text, cut on a UTF-8
            boundary. [""] when the turn has produced no text yet. *)
  ; last_tool : string option
        (** Most recently observed tool name, including requests before validation
            and returned calls. This does not claim a tool is executing. *)
  ; updated_at : float
  ; runtime_id : string option
  ; activity : activity
  ; last_failure : string option
  }

val tail_bytes : int

val current : keeper_name:string -> t option

val note_text : keeper_name:string -> now:float -> string -> unit
(** Record the newest response text's tail, redacted with the snapshot
    {!reset} armed. Blank text is ignored — a tool-only turn must not erase
    the last visible words. Before any {!reset} for this keeper no text is
    recorded. *)

val note_tool : keeper_name:string -> now:float -> string -> unit

val reset : keeper_name:string -> now:float -> redaction:Keeper_secret_redaction.t -> unit
(** Start the turn's preview. Every response text the turn records passes
    through [redaction] first; streamed deltas pass through one
    {!Keeper_stream_text_redaction} per provider attempt, so the tail grows a
    line at a time and a secret split between deltas never reaches it. *)

val note_attempt : keeper_name:string -> now:float -> runtime_id:string -> unit
val note_failure : keeper_name:string -> now:float -> runtime_id:string -> string -> unit
val note_stream : keeper_name:string -> now:float -> Agent_core.Types.sse_event -> unit
val status_text : t -> string
