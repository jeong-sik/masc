(** The facts that left a Keeper's Memory, read from its commit log
    (RFC librarian-call-only-proposes §10, §11.5).

    This is what a search for dropped or absorbed facts reads, and where a
    fact's successor is found: a removal says what the fact was merged into,
    revised into or superseded by. Nothing here writes, and no index is
    kept: every reading scans the log.

    The log starts at the cut. A fact removed before it is not here. *)

open Keeper_memory_os_types

type left =
  { fact : fact (** As Memory held it when it left. *)
  ; removal : Librarian_effects.removal
  ; at : float (** When the line that removed it was committed. *)
  ; line_at : int (** Byte offset of that line in the commit log. *)
  }

type t =
  { left : left list
  (** One entry for every fact whose last line in the log removed it, in the
      order of those lines. A fact that was added again after it left has no
      entry, and neither has a fact [current] holds. *)
  ; unreadable : int
  (** Lines that do not decode. What they removed or added is not known, so
      an absence here is not proof when this is not 0. *)
  }

(** [current] is the Memory the snapshot holds now. A snapshot an operator
    adopted can hold a fact the log last saw leaving. *)
val read : string -> current:fact list -> (t, Librarian_log_store.scan_error) result
