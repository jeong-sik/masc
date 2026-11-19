(** Which notice zone 4 draws when more than one is waiting
    (RFC tui-one-screen-grammar §2).

    The order is the RFC's: a pending confirmation, the result of the action
    just done, a read failure, a stale observation, the next schedule. The
    notice that leads is drawn, and the rest are counted as [외 N]. *)

type rank =
  | Pending_confirmation  (** An action waiting for its confirming key (§3.3). *)
  | Action_result  (** What the last key or command did. *)
  | Read_failure  (** A background read that keeps failing. *)
  | Stale_observation  (** A value read long enough ago to doubt. *)
  | Next_schedule  (** The next scheduled wake. *)

val compare_rank : rank -> rank -> int
(** Negative when the first rank leads. *)

type 'a shown = { lead : 'a; more : int }
(** The notice drawn and how many others wait behind it. *)

val choose : rank:('a -> rank) -> 'a list -> 'a shown option
(** The first notice of the leading rank. Within one rank the caller's order
    decides, so a caller that keeps its order fixed keeps the drawn notice
    fixed. [None] when nothing waits. *)
