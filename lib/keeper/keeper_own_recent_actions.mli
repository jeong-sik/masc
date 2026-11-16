(** The keeper's own tool calls from its recent turns.

    An autonomous turn assembles a briefing of current world state and no
    record of what this keeper already did. Nothing in that briefing says a
    task was finished, or that the same call was rejected one turn ago, so the
    keeper repeats both. This module reads back the durable tool-call log and
    groups it into turns so the prompt can state it. *)

type outcome =
  | Ok_call
  | Failed_call of string option
      (** The refusal text verbatim, [None] when the tool refused without
          describing why. A successful call carries no output: that it landed
          is the fact, and the returned body is where the bytes are. *)
  | Deferred_call
      (** Accepted, but its effect has not happened
          ({!Tool_result.Recorded_deferred}). Not a success: the keeper must
          not read the work as done. *)
  | Unrecorded_call
      (** The log row does not say how the call ended
          ({!Tool_result.Recorded_unsettled} or
          {!Tool_result.Recorded_malformed}). It is neither a success nor a
          refusal: rendering it as either tells the keeper something the
          record does not. *)

type provenance = { task_id : string option; trace_id : string option }
(** Missing, blank or malformed attribution remains [None], never inferred. *)

type task_relation = Selected_task | Other_task | Unknown_task

val task_relation : current_task_id:string option -> provenance -> task_relation
val provenance_to_json : current_task_id:string option -> provenance -> Yojson.Safe.t
(** Relation is to the turn's selected task identity, not task lifecycle status. *)

type input =
  | Arguments of string
      (** The argument object as the log persisted it, which may already
          have shortened long values or replaced an oversized object with a
          preview string; this module cuts nothing further. The prompt
          renders it on a refusal only: recognising the call it got refused
          for is what the keeper needs it for, and on a success the fact that
          the call landed is the whole of what this section is there to say. *)
  | Artifact_reference
      (** The row states {!Keeper_tool_call_log.Artifact_reference_input}:
          the input carried the reserved [_blob] key. Nothing of the input is
          carried, sibling fields included: the key is the stored form of an
          earlier call, and a refusal row that replays it shows the keeper
          that object as the shape of its own call again. *)
  | Unstated_input
      (** The row states no form {!Keeper_tool_call_log.recorded_input_form}
          reads: an earlier build wrote it, or it is damaged. Its input cannot
          be told from a stored reference (the persisted input may be a
          preview string), so it is not read as arguments; nothing of it is
          carried, and the prompt says the record does not state the form. *)

type call =
  { tool : string
  ; input : input
  ; provenance : provenance
  ; source_position : int
      (** Original zero-based row position within this read window, not a
          global journal identity. Preserved when calls are grouped into turns. *)
  ; outcome : outcome
  }

type turn =
  { turn_id : int
  ; calls : call list  (** Persisted order: oldest call of the turn first. *)
  }

val turns_of_rows
  :  keeper_name:string
  -> max_turns:int
  -> window_saturated:bool
  -> Yojson.Safe.t list
  -> turn list
(** Groups already-read log rows into the newest [max_turns] turns belonging to
    [keeper_name], oldest turn first. A turn identity includes the persisted
    trace id, so equal turn numbers in different executions stay separate.
    With no trace id, only contiguous equal-number rows form an occurrence. Rows without a turn id are dropped: they
    cannot be attributed to a turn the keeper would recognise. A row without a
    {!Keeper_tool_call_log.recorded_input_form} is kept, as {!Unstated_input}.

    [window_saturated] states that the caller's read filled its window, which
    means it began mid-turn and the oldest group is missing that turn's
    earliest calls; that group is then discarded rather than rendered
    incomplete. [max_turns <= 0] returns the empty list. Pure. *)

val collect
  :  keeper_name:string
  -> max_turns:int
  -> (turn list, Keeper_tool_call_log.index_error) result
(** Reads the durable tool-call log and applies {!turns_of_rows}. Every turn
    returned is whole: a saturated tail read begins mid-turn, so its oldest
    group is discarded rather than rendered with calls silently missing. A
    short read window therefore costs turns, never parts of one. A log the
    index cannot read is the [Error]: it is not "no turns", and the prompt
    states it so the keeper knows its own history is missing. [max_turns <= 0]
    is [Ok []] without a read. *)

type failure_digest =
  { failure_tool : string
  ; failure_input : input
  ; failure_count : int
  ; failure_detail : string option
        (** The newest occurrence's refusal text, [None] when unexplained. *)
  ; failure_provenance : provenance
  ; failure_last_turn : int
  }

val digest_failures : ?limit:int -> turn list -> failure_digest list
(** Collapses the window's refusals into one row per distinct rejected
    (tool, input, task, trace), counted, newest occurrence first, capped at [limit]
    (default 8). Unknown task or trace identities are separated by turn occurrence, rather than
    assumed to be the same execution. Pure. Empty when every call in the window succeeded. *)

val externalize_failures :
  base_path:string -> keeper_name:string ->
  tools:Agent_core.Tool.t list -> turn list -> turn list
(** Transmission view of failed calls, preserving tool, outcome and turn.
    A call with an {!Artifact_reference} or {!Unstated_input} input stays as
    it is: neither its input nor its refusal text is rendered, so nothing is
    stored for it.
    Only a genuinely offered canonical artifact reader permits references.
    Original rows are unchanged; missing readers and storage failures
    retain exact input and detail. Performs blob I/O at the request boundary. *)
