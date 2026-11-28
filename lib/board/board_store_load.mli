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
(** Re-read the posts file when it is due, by the rule of {!reobserve}.
    Persistence is taken only for that read: a store with nothing due answers
    [Ok ()], and an unknown earlier write answers [Error] from the store's
    fields, not read clear. A complete read replaces the posts model,
    re-derives reply and vote counts and becomes the new write observation.
    [Ok ()] when no reobservation was due or the source is readable again;
    [Error] names the cause and the needed action. The caller must not hold
    persistence. *)

val reobserve :
  Board_types.store -> (Board_paths.persisted_file * Board_types.board_error) list
(** One fresh read for each source that is due, in the order startup loads
    them: posts, comments, votes, reactions, sub-board policy.

    A refused source is due in one of three cases ({!Board_source_file}):
    - its cause is one {!Board_posts_source.fresh_read_can_clear} accepts
      (#55449): at every call;
    - no read made the refusal (a write, a guard or a check did): at the next
      call;
    - a read made it, and the directory no longer says of the source's file
      or of its lock file what it said when that read began (#55465).

    The third case costs one [lstat] of each of the two files, without a lock;
    the others and a store with no refused source cost a look at the store's
    fields. A read takes the two entries before anything else and its refusal
    carries them whatever the read then met, so a cause that lasts — a torn
    last line, a lock file with the wrong mode, a changed workspace directory
    — is met by one read and not by every call. The first read of a file
    creates its lock file, so a source that read refused is read once more. A
    cause that passes without changing either entry, and that is not of the
    first case, leaves the source refused until one of the two files changes
    or the server restarts.

    A complete read replaces that source's model as at startup and becomes its
    new write observation; a comments read that is not complete merges its
    rows and re-derives no counts. Persistence is taken only for a read, and
    once it is held the source is asked again from its fields, so a call that
    waited behind another call's read does not read a second time.

    Returns the sources that were read and are still not readable, each with
    its cause. Posts are also returned while a write of unknown outcome needs
    a restart. While a Board deletion is pending no source is read again: a
    source of the first case is returned with that cause, as before #55465,
    and a source of the other two is left as it is, without an [lstat] and
    without an entry in the list, and asked again once the deletion is over.
    A refused source that is not due is not in the list. The caller must hold
    neither persistence nor the state lock. *)
