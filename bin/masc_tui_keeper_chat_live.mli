(** Incremental reader for the keeper chat stream, for the live view.

    {!Masc_tui_keeper_chat_projection} decodes the same stream once it has
    ended: it validates every field and identity, and returns the turn's
    outcome. It reads none of the payloads on the way — text deltas, tool call
    names, and thinking fragments are checked for shape and dropped. A turn
    that read six files and edited two therefore reaches the screen looking
    exactly like one answered from memory, and nothing at all reaches it until
    the whole turn is over.

    This reads the payloads, from chunks, as they arrive.

    {2 Which one is authoritative}

    This one is not. It is lenient by construction: a line it cannot read
    becomes an {!Undecodable} delta, never an error, and the turn keeps going.
    The turn's recorded outcome still comes from the strict whole-body decode
    that runs when the stream ends, over the same bytes. So a defect here
    shows up as a wrong or missing row in the live pane, and cannot change
    what the transcript ends up holding.

    {2 Chunk boundaries}

    [feed] takes bytes, not lines. A chunk may end mid-line, and the next one
    may carry the rest. Deltas are only ever built from lines that have been
    seen whole. *)

type args_fragment =
  | Args_delta of string
      (** Argument text to append to what this call has accumulated. *)
  | Args_snapshot of string
      (** Argument text that replaces it — some providers send a snapshot
          instead of, not in addition to, their deltas. *)

(** One thing that happened in the turn, as far as the live view is concerned. *)
type delta =
  | Run_started
  | Text of string  (** Assistant text to append. *)
  | Thinking of string  (** Reasoning text to append. *)
  | Tool_started of
      { call_id : string
      ; tool_name : string
      }
  | Tool_args of
      { call_id : string
      ; fragment : args_fragment
      }
  | Tool_ended of { call_id : string }
  | Tool_result of { call_id : string }
  | Approval_requested of
      { call_id : string
      ; tool_name : string
      ; args : string
      ; question : string
      ; because : string
      }
      (** The turn is held at this call until it is answered. [because] is
          why it was held; the pane draws it under the question. *)
  | Approval_settled of
      { call_id : string
      ; outcome : string
      }
      (** How the wait ended -- the answer, or that none came. Drawn so a
          prompt stops being shown, including on the paths where nobody
          answered. *)
  | Checkpoint  (** The turn is continuing past a context checkpoint. *)
  | External_effect_completed
  | Run_failed of { message : string }
  | Run_finished
  | Undecodable of string
      (** A line that could not be read, and why. Reported rather than
          skipped: a live pane that silently drops what it does not
          understand looks like a keeper that did nothing.

          Event types this reader does not display — but which the strict
          decode accepts — are not reported here; they produce no delta at
          all. An event type neither knows is [Undecodable] here and an error
          there, so the two stay consistent about what the stream may
          contain. *)

type t

val create : unit -> t

val feed : t -> string -> delta list
(** [feed t chunk] adds [chunk] to what has been read and returns the deltas
    completed by it, in stream order. Bytes of a line that is still
    incomplete are held until the rest arrives. *)
