(** Article ledger for one world (RFC-0442).

    The ledger is an append-only JSONL file under
    [<base_path>/.masc/constitution/]. Each line is one move — a norm written
    down, or one taken back — and the norms a world currently holds are those
    lines folded in order. Article counts are bounded by the byte ceiling the
    prompt slot puts on them, so reading the whole file is the read path; there
    is no derived snapshot to keep in step.

    A world with no ledger has no articles. That is the fresh-state contract,
    not an error: nothing here reads a legacy layout or converts one. *)

val ledger_path : base_path:string -> string
(** [<base_path>/.masc/constitution/articles.jsonl]. The file need not
    exist. *)

type append_error =
  | Directory_unavailable of {
      path : string;
      detail : string;
    }
  | Ledger_moved of {
      expected : int;
      actual : int;
    }
      (** Someone appended between the caller's read and its write. The caller
          decided something from what it read — the byte ceiling is decided
          exactly this way — so the write is refused rather than applied to a
          ledger the caller never saw. *)
  | Write_failed of {
      path : string;
      detail : string;
    }

val append_error_to_string : append_error -> string

val append_at :
  base_path:string ->
  expected_end_offset:int ->
  World_constitution_types.entry ->
  (unit, append_error) result
(** Record one move, provided the ledger still ends where the caller's
    {!load} left it. Whether the world agreed is settled on the board before
    anyone calls this; the ledger writes what it is told and judges nothing.

    The offset is what makes a read-then-decide safe. Two keepers that both
    read a world one article below the ceiling would both pass their own check
    and both append, leaving the rendered articles over a ceiling nothing
    re-checks on the way out. Here the second one is told its read is
    stale. *)

type rejected_line = {
  line_number : int;  (** 1-based, counting every line including blanks. *)
  detail : string;
}

type ledger = {
  end_offset : int;
      (** Bytes the ledger held when this was read. Pass it to {!append_at} so
          a write built on this read cannot land on a different ledger. *)
  articles : World_constitution_types.t list;
      (** The norms the world currently holds, in the order they were first
          written. An article written, removed and written again returns at the
          end, because that is when the world decided to keep it. *)
  rejected : rejected_line list;
      (** Lines that did not decode, in file order. They stay in the file: a
          reader reports them rather than dropping them silently, because a
          line nobody can read is a norm somebody wrote. *)
}

type read_error =
  | Unreadable of {
      path : string;
      detail : string;
    }

val read_error_to_string : read_error -> string

val load : base_path:string -> (ledger, read_error) result
(** Read the whole ledger and fold it. A missing file is an empty ledger. *)
