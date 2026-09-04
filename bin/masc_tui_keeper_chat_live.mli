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

(** Where a request stood when the server accepted it. *)
type admission =
  | Queued  (** Accepted and waiting its turn in the keeper's queue. *)
  | Running  (** Accepted and started. *)
  | Settled
      (** Already finished when it was accepted: an idempotent replay of an
          operation the server had already run. *)

type tool_occurrence =
  { stream_scope : int
  ; block_index : int
  ; provider_message_id : string option
  ; tool_call_id : string option
  }
(** Server-owned live row identity plus optional provider correlations. *)

(** One thing that happened in the turn, as far as the live view is concerned. *)
type delta =
  | Run_started
  | Runtime_attempt_started
      (** New resolved-runtime attempt: discard unfinished text/thinking from
          the prior attempt while retaining tool evidence. *)
  | Text of string  (** Assistant text to append. *)
  | Thinking of string  (** Reasoning text to append. *)
  | Tool_started of
      { occurrence : tool_occurrence
      ; tool_name : string
      }
  | Tool_args of
      { occurrence : tool_occurrence
      ; fragment : args_fragment
      }
  | Tool_ended of { occurrence : tool_occurrence }
  | Tool_result of
      { occurrence : tool_occurrence
      ; execution_id : string
      }
      (** Exact server occurrence plus the canonical execution identity after
          the tool-call log commit. Provider ids remain optional correlation
          data. Missing occurrence coordinates or canonical identity is an
          {!Undecodable} event. *)
  | Stream_protocol_error of
      { quarantined_occurrence : tool_occurrence option
      ; detail : string
      }
      (** Typed server diagnostic. Only [quarantined_occurrence] authorizes a
          live tool row to enter the failed state; an absent occurrence remains
          a turn-level diagnostic. *)
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
  | Accepted of
      { admission : admission
      ; queue_length : int
            (** How many operations the keeper's chat queue held when the
                server accepted this one. The server counts the whole queue,
                so this is not "how many are ahead of this one" and must not
                be drawn as though it were. *)
      }
      (** The server took the request. Until this arrives, a pane can say the
          request went out and nothing more -- which is what left a wait of
          minutes reading as "waiting for the run to start" with no way to
          tell a busy keeper from a stuck one. *)
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

val feed : t -> string -> (int option * delta) list
(** [feed t chunk] adds [chunk] to what has been read and returns the deltas
    completed by it, in stream order, each with the journal seq of the frame
    that carried it: the value of the frame's [id:] line, or [None] for a
    frame without one (the acceptance event and the settle-time run_error
    never went through the bus). The id is held across a chunk boundary and
    dropped at the frame's end, so an id-less frame cannot inherit the seq of
    the frame before it. Bytes of a line that is still incomplete are held
    until the rest arrives. *)
