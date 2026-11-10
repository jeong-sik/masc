(** What a Keeper's memory journal says for the memory health row, kept across
    reads: the newest Librarian commit, the newest Librarian failure after it,
    and the facts the Keeper held after each hour's last commit.

    Every [keeper_memory_write] and retraction journals a committed line of
    its own, so the last line says nothing about the Librarian: the answer is
    the newest Librarian commit and whatever Librarian failure came after it,
    wherever in the journal that commit sits. With no Librarian commit it is
    the newest failure.

    The answer is folded oldest first, so a read takes only the lines appended
    since the last read of the same file. A line still being written, or left
    unfinished by a writer that stopped, is read once it is complete or once
    the next append cuts it. A journal that was replaced or shrank is folded
    again from its start. *)

type facts_at_hour =
  { recorded_at : float  (** [recorded_at] of the hour's last committed line *)
  ; facts : int  (** the facts after that commit: its [retained] and its [added] *)
  }

val trend_hours : int
(** 168, a week of clock hours. *)

type t =
  { last_success_at : float option
  ; last_failure : Keeper_memory_os_current_types.librarian_failure_kind option
  ; facts_by_hour : facts_at_hour list
      (** Oldest first, one point per clock hour with a committed line from
          any source, over the {!trend_hours} hours that end with the newest
          such hour. The journal's later line is the later commit, so it
          replaces the point of its hour. A commit that kept the stored
          snapshot journals the facts it kept and adds none, so its point is
          the snapshot's size and counts no new claim. *)
  }

val read : keepers_dir:string -> keeper_id:string -> t
(** A missing journal is no commit and no failure. A read that fails keeps the
    answer of the last read that succeeded, since the journal only grows, and
    is retried on the next read; with none, it is no commit and no failure. *)

val within : now:float -> facts_at_hour list -> facts_at_hour list
(** The points in the {!trend_hours} clock hours that end with [now]'s hour.
    A point after [now]'s hour is left out too. *)

val facts_by_hour_to_json : facts_at_hour list -> Yojson.Safe.t
(** An array of [{"recorded_at", "facts"}] objects in the order given. *)

val facts_by_hour_of_json : Yojson.Safe.t -> (facts_at_hour list, string) result
(** Takes an array of at most {!trend_hours} objects with exactly those two
    members: a finite [recorded_at] and a non-negative int [facts]. Each point
    must be in a later clock hour than the one before it. *)
