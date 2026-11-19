(** Background reads that keep failing, for zone 4
    (RFC tui-one-screen-grammar §2).

    A read that runs on every refresh whatever the screen -- the [/health]
    probe, the Keeper questions, the confirm queue -- said its failure only to
    the session event list, which Metrics alone draws. Reporting it as an
    action result instead would let a poll replace what the operator's last
    key did. This holds the failures apart from the action result, one per
    read, so zone 4 can rank them below it.

    A list a screen reads for itself (the board list, planning) is not here:
    that screen's body says its failure, and the read stops when the operator
    leaves, so a notice of it would outlive anything it could say. *)

type read =
  | Server_health
      (** [GET /health], the identity probe each full and navigation
          refresh starts and ends with. Another reader of the same route
          reports here, not as a read of its own, so one notice says that
          [/health] is failing. *)
  | Refresh_pass  (** The refresh as a whole, when it raised before it settled. *)
  | Asks  (** Keeper questions. *)
  | Confirmations  (** The operator confirm queue. *)

type failure = private {
  read : read;
  since : float;  (** Wall-clock time of the first failure in this run. *)
  count : int;  (** Failures in a row, at least one. *)
}

type t

val empty : t

val failed : t -> read -> at:float -> t
(** [read] failed at [at]. A read already failing keeps its [since] and its
    place and counts one more. *)

val succeeded : t -> read -> t
(** [read] answered, so it no longer fails. *)

val failures : t -> failure list
(** The reads of the whole server ([Server_health], [Refresh_pass]) first,
    since a question or confirm-queue read may fail because the server does;
    within each, the oldest run first, then in declaration order. A failure
    that repeats keeps its place, so the notice drawn first stays the same. *)

val notice_text : ko:bool -> now:float -> next_try:float option -> failure -> string
(** [서버 상태 읽기 실패 · 3회 연속 · 15:04 부터]. The run's start is a
    moment, not a length, so the text changes only when the read fails again
    and asks for no redraw of its own (RFC tui-one-screen-grammar §8).

    [next_try] is the wall-clock moment the pass that a failing [/health]
    owes starts ({!Masc_tui_refresh_pace.next_try}). The whole server's reads
    end with it, to the second:
    [서버 상태 읽기 실패 · 3회 연속 · 15:04 부터 · 다음 시도 15:04:32]. It is
    a moment too, never a countdown. Other reads do not wait for that pass,
    so they do not say it. *)
