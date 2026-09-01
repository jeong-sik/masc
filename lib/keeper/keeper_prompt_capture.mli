(** The extra system context a keeper's last turn actually assembled.

    A turn record says a block was 435 bytes with a given digest. It does not
    say what those bytes were, so an operator asking "what is this keeper being
    told" has had no answer short of reading the provider's wire log.

    {1 Why the last turn is the preview}

    The blocks are stable across turns — measured on a live fleet, the same
    keeper renders identical system-prompt, recall, and dynamic-context bytes
    after turn while only the conversation grows. The assembled context of the
    turn that just ran is therefore what the next turn will assemble, minus the
    conversation. That is why this store needs no arming step: capturing every
    turn and keeping only the last one is both always fresh and bounded.

    {1 Bounded by construction}

    One file per keeper, overwritten each turn. Storage is one turn's context,
    not a history — a history of prompts would grow at the rate the keeper runs,
    which is the cost this whole subsystem exists to bound.

    {1 What is not here}

    The base system prompt is assembled on a different path and is not part of
    this capture. This store holds the extra system context: the typed
    blocks appended to that base. *)

type block =
  { id : Prompt_block_id.t
  ; text : string
  }

type capture =
  { captured_at : float
  ; trace_id : string
  ; absolute_turn : int
  ; blocks : block list
        (** In assembly order, which is the order they reach the provider. *)
  ; assembled : string option
        (** The complete extra system context as sent. [None] when the turn
            assembled no blocks — distinct from an empty string, which would be
            a block that rendered to nothing. *)
  }

val path_for : Workspace.config -> string -> string

(** Overwrite this keeper's capture with the turn just assembled. Failure to
    write degrades to a warning: the capture is an observation of a turn that is
    already proceeding, and losing it must not fail the turn. Cancellation is
    never absorbed. *)
val write :
  config:Workspace.config
  -> keeper:string
  -> trace_id:string
  -> absolute_turn:int
  -> blocks:(Prompt_block_id.t * string) list
  -> assembled:string option
  -> unit

type read_error =
  | Unknown_keeper of string
  | Not_captured
  | Malformed of string

val read_error_to_string : read_error -> string

(** The last captured turn. [Not_captured] when the keeper has not run since
    this store existed — absence of a capture is not a malformed one. *)
val read : config:Workspace.config -> keeper:string -> (capture, read_error) result

val to_json : capture -> Yojson.Safe.t

(** Decode the capture object emitted by {!to_json}. Extra envelope fields are
    ignored so the same decoder can read the dashboard route, which adds the
    keeper name and surface identity around this object. *)
