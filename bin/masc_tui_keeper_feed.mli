(** The past of one Keeper told in time order (RFC-0515 section 2.5): its
    newest turns, its newest wakes and its last digest, oldest first, so that
    the newest event sits next to the story page's "now" group.

    The feed holds what the three reads gave and says nothing about the time
    between two of its events: a turn older than the oldest one listed, or a
    wake the schedule that recorded it has since overwritten, is not in it. *)

type item =
  | Wake of Masc_tui_keeper_wakes.t
  | Turn of Masc_tui_keeper_turns.turn
  | Digest of float  (** When the librarian last digested, in Unix seconds. *)

val at : item -> float
(** When the event happened, in Unix seconds. A wake's time is when it started.
    A turn's is when its record was written, which is when the turn ended. *)

val of_sources :
  turns:Masc_tui_keeper_turns.turn list ->
  wakes:Masc_tui_keeper_wakes.t list ->
  digest_at:float option ->
  item list
(** The events, oldest first. [wakes] is newest first, as
    {!Masc_tui_keeper_wakes.of_page} gives them, and only the newest two
    enter. On equal times a wake comes before a turn and a turn before a
    digest: a wake starts a turn and a digest follows the turns it digested.
    Events of one kind keep the order they came in. *)
