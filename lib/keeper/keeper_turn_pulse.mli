(** Autonomous turn outcomes per keeper, counted in half-hour slots over the
    last day (RFC-0515 §2.1).

    A slot starts on a multiple of {!slot_seconds} of Unix time and counts the
    turns that ended in it. Slots change only when a turn is recorded or the
    pulse is seeded: recording prunes the slots that lie more than
    {!window_seconds} before the newest slot and moves [known_since] up to that
    boundary, and reading computes nothing.
    So a keeper's row carries the same pulse until its next turn (RFC-0481),
    and the number of slots a keeper holds is set by time, not by how many
    turns it ran.

    The map is updated through a CAS loop so a reader on another domain sees an
    immutable snapshot. *)

type outcome =
  | Turn_ok
  | Turn_rested
  | Turn_failed

type tally = {
  ok : int;
  rested : int;
  failed : int;
}

type slot = {
  starts_at : int;  (** Unix seconds, a multiple of {!slot_seconds}. *)
  tally : tally;
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

val record : base_path:string -> keeper_name:string -> at:float -> outcome -> unit
(** Count one turn that ended at [at]. A keeper with no pulse yet knows its
    turns from [at] on. *)

val get : base_path:string -> keeper_name:string -> pulse option
(** [None] when the keeper was neither seeded nor recorded. *)

type sample = {
  at : float;
  outcome : outcome;
}

val seed_from_decision_log :
  ?now:float -> config:Workspace.config -> keeper_name:string -> unit -> unit
(** Fill a keeper's pulse from the tail of [decisions.jsonl], and from
    [decisions.jsonl.1] when the primary log is missing or was read whole
    without reaching the window start. Rows stamped after [now] are dropped.
    Seeding leaves a keeper that already has a pulse alone.

    [known_since] is the window start when a row older than the window was
    read. Otherwise it is the oldest row read, of any event, since the logs
    hold every turn after it; with no row read it is [now]. A log that exists
    but cannot be read leaves the keeper unseeded, so [get] stays [None]. *)

val seed_all_from_decision_logs : ?now:float -> config:Workspace.config -> unit -> unit

val reset_for_tests : unit -> unit
