(** Words for the Keepers fleet header, in the screen language: [~ko] picks
    Korean. The comments below quote the English wording. *)

val status_text : ko:bool -> Masc.Keeper_fleet_grade.t -> string
(** The grade in the screen language. The English word is the grade's wire
    name. *)

val status_is_ok : Masc.Keeper_fleet_grade.t -> bool
(** Whether the fleet header draws in the healthy colour: only [ok] does. *)

val blocker_text : ko:bool -> Masc.Fleet_stream.fleet -> string option
(** The first reason the fleet scan names, without a number. A row that also
    draws the task-owner count takes {!cause_rows} instead, so the phrase and
    the count are one row. [None] when the scan names no blocker. *)

val interval_text : Masc.Fleet_stream.Proactive_interval.t -> string
(** The interval in the largest unit that divides it exactly: [1h] for 3600
    seconds, [5m] for 300. Any other value is
    {!Masc_tui_message_layout.span_text}: [1m30s], [45s]. Never rounded, since
    it names a setting. *)

val proactive_text : ko:bool -> Masc.Fleet_stream.fleet -> string
(** [proactive every <interval>]: how far apart each Keeper's periodic turns
    start, one value for the fleet, as {!interval_text}. *)

val failing_text : ko:bool -> Masc.Fleet_stream.fleet -> string option
(** [failing N] with the classes that hold a failing Keeper, each class only
    when it holds one. [None] when nothing is failing. *)

val failure_text : ko:bool -> Masc_tui_fleet_stream.failure -> string
(** Why there is no fleet reading to draw, on one line. *)

val unavailable_text :
  ko:bool -> now:float -> degradation:Masc.Fleet_stream.degradation ->
  disconnected_since:float option -> string
(** A failed first scan and, if present, the separate connection loss. *)

val unreachable_text : ko:bool -> now:float -> since:float -> string
(** No reading was ever told and the stream is down: [not observed · stream
    lost <age> ago]. The age is left out when [now] is behind [since]. *)

val trouble_text : ko:bool -> now:float -> Masc_tui_fleet_stream.trouble -> string
(** What is wrong with the reading drawn beside it: [stale · scans failing for
    <age> (<reason>)] while the server's scans fail, [stale · stream lost <age>
    ago] while the connection is down. The age is counted from [now], and
    left out when [now] is behind the time it counts from. *)

(** How many task owners the scan found with no fiber that can run a turn.
    Private: only {!owner_count} builds one, so [Exactly 0] and an
    [At_least] with no unread source cannot be written. *)
type owner_count = private
  | Exactly of int
      (** The scan read every source, and this many owners, more than zero,
          have no fiber. *)
  | At_least of { owners : int; unread : int }
      (** [unread] sources, more than zero, could not be read. Their tasks
          are missing from [owners], so it is a lower bound and may be
          zero. *)

val owner_count : Masc.Fleet_stream.fleet -> owner_count option
(** [None] when the count is zero and the scan read everything: there is
    nothing to say. *)

(** One row of a card body that says why the fleet is short of what it is
    configured to run. Each row says its facts and no other row says them. *)
type cause_row =
  | Blocker_alone of Masc.Keeper_fleet_blocker.t
      (** The blocker's phrase, with no count. *)
  | Blocker_with_owners of owner_count
      (** The task-owner blocker and the owner count on one row: the
          blocker's phrase names the Keepers the count counts. *)
  | Owners_alone of owner_count
      (** The owner count, beside a blocker that names another reason or
          with no blocker. *)

val cause_rows :
  blocker:Masc.Keeper_fleet_blocker.t option -> owner_count option -> cause_row list
(** The blocker and the owner count, each once. The task-owner blocker with a
    count is one {!Blocker_with_owners} row. Any other blocker is its phrase
    alone, followed by the count when there is one. With no blocker the count
    stands alone. *)

val cause_row_text : ko:bool -> cause_row -> string
(** The row in the screen language: the blocker's phrase, or for a row that
    carries the count the task-owner blocker's phrase with it,
    [task owner without fiber N], or [N+ (M sources unread)] for a lower
    bound. *)

(** One row that says a fleet reading on screen is an earlier one, and why.
    A reading is retained while the stream is in trouble or the workspace
    identity is unconfirmed. *)
type retained_row =
  | Stale_with_trouble of Masc_tui_fleet_stream.trouble
      (** Stale, and the stream trouble that keeps it so: {!trouble_text}. *)
  | Stale_with_identity_unconfirmed
      (** Stale because the workspace identity is unconfirmed. *)
  | Identity_unconfirmed_too
      (** Under a {!Stale_with_trouble} row: the identity is unconfirmed as
          well. It does not say "stale" again. *)

val retained_rows :
  trouble:Masc_tui_fleet_stream.trouble option -> identity_confirmed:bool -> retained_row list
(** Empty for a current reading. Otherwise the first row says the reading is
    stale and why, and a second reason has a row of its own. *)

val retained_row_text : ko:bool -> now:float -> retained_row -> string
