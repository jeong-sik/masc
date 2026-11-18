(** When the next refresh pass may read [/health] after it failed
    (RFC tui-one-screen-grammar §2).

    Every surface bundle, the full pass and a screen's own reads alike,
    starts with the [/health] probe. When the probe fails, the workspace
    confirmation is withdrawn; the observer recovery restores it from the
    stream handshake, and the reopened stream asks for a pass. Nothing in
    that ring waits, so with no record here the TUI read [/health] again at
    once, many times a second (#53205).

    {!Masc_tui_owed_read} does not fit: a change announced while it waits is
    read at once, since that failure may belong to another part of the
    reading. A failing probe is the whole server's failure, and the
    announcements that would cut the wait are the ring itself. It also
    settles only the read that began last, while a full pass and a screen's
    reads overlap and either probe's answer is the fact.

    Nothing here performs I/O or reads a clock. The caller passes [now]. *)

type t = private
  | Answering
      (** The last probe answered, or none has failed. Nothing is owed. *)
  | Failing of { failures : int; retry_at : float }
      (** The last [failures] probes failed in a row. One pass is owed at
          [retry_at]. *)
  | Recovered of { failures : int }
      (** The wait ended early while a pass was owed, and that pass starts
          now. [failures] is the run a failure after it continues: zero when
          [/health] answered, the run so far when only the stream reopened. *)

type ask =
  | Revalidate
      (** Something the TUI observed asks for a pass: a server push, a
          reopened stream, the answer to a request it sent. Waits while the
          probe is failing; the owed pass covers it. *)
  | Operator_key
      (** An operator's key: the refresh key, or a key that changes what a
          screen shows and reads it again. Starts at once and keeps the
          failures in a row, so a failure after it waits longer. *)
  | Owed_pass  (** The pass a failing probe owes, once its wait is over. *)

(** How the stream that restores the workspace confirmation opened. *)
type stream_open =
  | Opened_each_time
      (** Every attempt opened it. A server whose [/health] alone fails
          still opens it, so this says nothing new. *)
  | Opened_after_failure
      (** An earlier attempt did not open it. The server answers again, but
          this is not a [/health] answer. *)

val answering : t

val probe_failed : retry_s:float -> max_retry_s:float -> now:float -> t -> t
(** A probe failed, or a pass raised before it settled. The wait is
    [retry_s] after the first failure and doubles with each failure in a
    row, up to [max_retry_s]. *)

val pass_answered : t -> t
(** A full pass's probe answered. A pass is a whole revalidation, so nothing
    stays owed. *)

val answered_again : t -> t
(** [/health] answered again: a screen's probe answered, or a server the TUI
    started answered its liveness probe. The wait and the run of failures are
    over; a pass the failure owed is still owed and starts now. *)

val stream_opened : stream_open -> t -> t
(** The stream that restores the workspace confirmation opened. Only
    {!Opened_after_failure} ends the wait, and the owed pass starts now. The
    run of failures goes on, since an open stream is not a [/health] answer:
    a failure after it waits longer than the last wait. *)

val due : now:float -> t -> bool
(** Whether the owed pass should start now. *)

val starts : now:float -> ask -> t -> bool
(** Whether a pass, or a screen read that probes first, asked for by [ask]
    starts now when nothing else holds it. *)
