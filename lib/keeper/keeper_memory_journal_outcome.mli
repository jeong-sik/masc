(** The newest Librarian commit in a Keeper's memory journal and the newest
    Librarian failure after it, kept across reads.

    Every [keeper_memory_write] and retraction journals a committed line of
    its own, so the last line says nothing about the Librarian: the answer is
    the newest Librarian commit and whatever Librarian failure came after it,
    wherever in the journal that commit sits. With no Librarian commit it is
    the newest failure.

    The answer is folded oldest first, so a read takes only the lines appended
    since the last read of the same file. A journal that was replaced or shrank
    is folded again from its start. *)

type t =
  { last_success_at : float option
  ; last_failure : Keeper_memory_os_current.librarian_failure_kind option
  }

val read : keepers_dir:string -> keeper_id:string -> t
(** A missing journal is no commit and no failure. A read that fails keeps the
    answer of the last read that succeeded, since the journal only grows, and
    is retried on the next read; with none, it is no commit and no failure. *)
