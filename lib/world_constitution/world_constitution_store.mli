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
  | Write_failed of {
      path : string;
      detail : string;
    }

val append_error_to_string : append_error -> string

val append :
  base_path:string ->
  World_constitution_types.entry ->
  (unit, append_error) result
(** Record one move. Whether the world agreed is settled on the board before
    anyone calls this; the ledger writes what it is told and judges nothing. *)

type rejected_line = {
  line_number : int;  (** 1-based, counting every line including blanks. *)
  detail : string;
}

type ledger = {
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
