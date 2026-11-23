(** Turn outcomes and what started each turn, per keeper, counted in
    half-hour slots over the last day (RFC-0515 §2.1, RFC-0511 D5).

    A slot starts on a multiple of {!slot_seconds} of Unix time and counts the
    turns that ended in it. Slots change only when a turn is recorded or the
    pulse is seeded: recording prunes the slots that lie more than
    {!window_seconds} before the newest slot and moves [known_since] up to that
    boundary, and reading computes nothing.
    So a keeper's row carries the same pulse until its next turn,
    and the number of slots a keeper holds is set by time, not by how many
    turns it ran.

    Both lanes count: the autonomous cycle and a direct request. A slot holds
    every turn twice, once by outcome and once by cause, so the two tallies of
    a slot add up to the same number.

    The map is updated through a CAS loop so a reader on another domain sees an
    immutable snapshot. *)

type outcome =
  | Turn_ok
  | Turn_rested
  | Turn_failed

(** What started a turn, read from what the turn took in. *)
type cause =
  | Scheduled  (** Every input the turn took was a due schedule. *)
  | Reacted  (** The turn took at least one input that was not a due schedule. *)
  | Chat  (** A direct request: someone wrote to the keeper. *)
  | Own
      (** The autonomous cycle took no input. A cadence tick and a broadcast
          wake that found the queue empty both land here: the turn log writes
          no input for either, so a seed could not tell them apart. *)

type tally = {
  ok : int;
  rested : int;
  failed : int;
}

type causes = {
  scheduled : int;
  reacted : int;
  chat : int;
  own : int;
  unknown : int;
      (** Seeded autonomous turns with no [Opened] line read: the line lies
          before the turn-log tail the seed reads, or the turn failed before
          it opened one. A recorded turn never lands here, so such a turn moves
          from its cause to [unknown] when the server restarts. *)
}

type slot = {
  starts_at : int;  (** Unix seconds, a multiple of {!slot_seconds}. *)
  tally : tally;
  causes : causes;
}

type pulse = {
  known_since : float;
      (** The server knows every turn that ended at or after this Unix time.
          A slot that starts before it may have lost turns. *)
  slots : slot list;  (** Newest first; a slot with no turn is not stored. *)
}

val slot_seconds : int
(** 1800: half an hour. *)

val window_seconds : int
(** 86400: the slots kept behind the newest recorded turn's slot. *)

val slot_start : float -> int
(** The start of the slot that holds Unix time [at]. *)

val cause_of_inputs : Keeper_event_queue.stimulus list -> cause
(** The cause of an autonomous turn from the queue entries it took. No entry is
    {!Own}. *)

val record :
  base_path:string -> keeper_name:string -> at:float -> cause:cause -> outcome -> unit
(** Count one turn that ended at [at]. A keeper with no pulse yet knows its
    turns from [at] on. *)

val get : base_path:string -> keeper_name:string -> pulse option
(** [None] when the keeper was neither seeded nor recorded. *)

val seed_from_decision_log :
  ?now:float -> config:Workspace.config -> keeper_name:string -> unit -> unit
(** Fill a keeper's pulse from the tail of [decisions.jsonl], and from
    [decisions.jsonl.1] when the primary log is missing or was read whole
    without reaching the window start. Rows stamped after [now] are dropped.
    Seeding leaves a keeper that already has a pulse alone.

    A [direct_turn] row is {!Chat}. An [autonomous_cycle] row takes its cause
    from the keeper's turn log: the [Opened] line whose turn ref is the row's
    [trace_id] and [turn_id] names what the turn took. A row with no such line
    read counts as [unknown]. The turn log's tail is read within the decision
    log's bounds, and only once an autonomous row needs a cause.

    [known_since] is the window start when a row older than the window was
    read. Otherwise it is the oldest row read, of any event, since the logs
    hold every turn after it; with no row read it is [now]. A decision log that
    exists but cannot be read leaves the keeper unseeded, so [get] stays
    [None]. *)

val seed_all_from_decision_logs : ?now:float -> config:Workspace.config -> unit -> unit

val reset_for_tests : unit -> unit
