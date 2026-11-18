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
      (** [GET /health], the identity probe each refresh starts and ends
          with. A sampler that reads the same route reports here too, so one
          notice says that [/health] is failing. *)
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
(** The oldest run first, then in declaration order: a failure that repeats
    keeps its place, so the notice drawn first stays the same. *)

val notice_text : ko:bool -> now:float -> failure -> string
(** [서버 상태 읽기 실패 · 3회 연속 · 6s]. The length of the run notes when
    it next reads differently ({!Masc_tui_value.Redraw}). *)
