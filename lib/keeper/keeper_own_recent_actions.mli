(** The keeper's own tool calls from its recent turns.

    An autonomous turn assembles a briefing of current world state and no
    record of what this keeper already did. Nothing in that briefing says a
    task was finished, or that the same call was rejected one turn ago, so the
    keeper repeats both. This module reads back the durable tool-call log and
    groups it into turns so the prompt can state it. *)

type outcome =
  | Ok_call
  | Failed_call of string
      (** Bounded head of the failure text the tool returned. *)

type call =
  { tool : string
  ; input : string  (** Bounded rendering of the argument object. *)
  ; outcome : outcome
  }

type turn =
  { turn_id : int
  ; calls : call list  (** Persisted order: oldest call of the turn first. *)
  }

val turns_of_rows : keeper_name:string -> max_turns:int -> Yojson.Safe.t list -> turn list
(** Groups already-read log rows into the newest [max_turns] turns belonging to
    [keeper_name], oldest turn first. Rows without a turn id are dropped: they
    cannot be attributed to a turn the keeper would recognise. [max_turns <= 0]
    returns the empty list. Pure. *)

val collect : keeper_name:string -> max_turns:int -> turn list
(** Reads the durable tool-call log and applies {!turns_of_rows}. The read
    window is sized from [max_turns]; a turn that ran more calls than the
    window covers is returned truncated rather than dropped. *)
