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

type call =
  { tool : string
  ; input : string
      (** The argument object verbatim, never truncated. The prompt renders it
          on a refusal only: recognising the call it got refused for is what
          the keeper needs it for, and on a success the fact that the call
          landed is the whole of what this section is there to say. *)
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
    [keeper_name], oldest turn first. Rows without a turn id are dropped: they
    cannot be attributed to a turn the keeper would recognise.

    [window_saturated] states that the caller's read filled its window, which
    means it began mid-turn and the oldest group is missing that turn's
    earliest calls; that group is then discarded rather than rendered
    incomplete. [max_turns <= 0] returns the empty list. Pure. *)

val collect : keeper_name:string -> max_turns:int -> turn list
(** Reads the durable tool-call log and applies {!turns_of_rows}. Every turn
    returned is whole: a saturated tail read begins mid-turn, so its oldest
    group is discarded rather than rendered with calls silently missing. A
    short read window therefore costs turns, never parts of one. *)

type failure_digest =
  { failure_tool : string
  ; failure_input : string
  ; failure_count : int
  ; failure_detail : string option
        (** The newest occurrence's refusal text, [None] when unexplained. *)
  ; failure_last_turn : int
  }

val digest_failures : ?limit:int -> turn list -> failure_digest list
(** Collapses the window's refusals into one row per distinct rejected
    (tool, input), counted, newest occurrence first, capped at [limit]
    (default 8). Pure. Empty when every call in the window succeeded. *)
