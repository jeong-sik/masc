(** Persistence loaders. Posts and comments serve quiescent startup; votes
    and reactions also serve explicit reload under their persistence/state
    interval. All four refuse model replacement while deletion work is
    pending. Counts include accepted duplicate physical rows. *)
val load_persisted_posts : Board_types.store -> (int, string * exn) result
val load_persisted_comments : Board_types.store -> (int, string * exn) result
val load_persisted_votes : Board_types.store -> (int, string * exn) result
(** Owns persistence and publishes the vote model under the state lock.
    A complete source replaces the ledger and recalculates counts; valid
    orphan votes remain stored. Partial rows are display-only. Neither load
    nor a normal write settles unknown effects or unfinished publication. *)
val load_persisted_reactions : Board_types.store -> (int, string * exn) result

(** Rebuild current reply counts and timestamp high-water marks after loading
    comments, before votes. Quiescent startup only; emits the existing log. *)
val recalculate_reply_counts : Board_types.store -> unit

val reobserve_posts : Board_types.store -> (unit, Board_types.board_error) result
(** Re-read the posts file when {!Board_posts_source.reobservation_due}.
    Persistence is taken only for that read: a store with nothing due answers
    [Ok ()] after at most one [lstat] of a refused source's file, and an
    unknown earlier write or a pending deletion answers [Error] from the
    store's fields, not read clear. A complete read replaces the posts model,
    re-derives reply and vote counts and becomes the new write observation.
    [Ok ()] when no reobservation was due or the source is readable again;
    [Error] names the cause and the needed action. The caller must not hold
    persistence. *)

val reobserve :
  Board_types.store -> (Board_paths.persisted_file * Board_types.board_error) list
(** One fresh read for each source that is due, in the order startup loads
    them: posts, comments, votes, reactions, sub-board policy. A source is due
    when it is refused and either its cause is one
    {!Board_posts_source.fresh_read_can_clear} accepts or its file has changed
    since this store last read it (#55465). A complete read replaces that
    source's model as at startup and becomes its new write observation; a
    comments read that is not complete merges its rows and re-derives no
    counts. Persistence is taken only for a read. A store with no refused
    source costs a look at its fields; each refused source whose cause is not
    one of those costs one [lstat], which takes no lock. Returns the
    sources that were due and are still not readable, each with its cause: a
    read that failed, or a pending deletion, during which no source is read
    again. Posts are also returned while a write of unknown outcome needs a
    restart. A refused source that is not due is not in the list. The
    caller must hold neither persistence nor the state lock (#55449). *)
