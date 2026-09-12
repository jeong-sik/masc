(** Article ledger for one world (RFC-0442).

    The ledger is an append-only JSONL file under
    [<base_path>/.masc/constitution/]. Each line is the complete article as it
    stood after one move, so the last line carrying an id is that article's
    current state and the lines before it are how it got there. Article counts
    are bounded by the byte ceiling RFC-0442 puts on the prompt slot, so
    reading the whole file is the read path; there is no derived snapshot to
    keep in step.

    A world with no ledger has no articles. That is the fresh-state contract,
    not an error: nothing here reads a legacy layout or converts one. *)

val ledger_path : base_path:string -> string
(** [<base_path>/.masc/constitution/articles.jsonl]. The file need not
    exist. *)

(** {1 Appending} *)

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
  base_path:string -> World_constitution_types.t -> (unit, append_error) result
(** Record the article as it now stands. The caller decided the move was legal
    through {!World_constitution_types.transition}; this writes what that
    produced and judges nothing. *)

(** {1 Reading} *)

type rejected_line = {
  line_number : int;  (** 1-based, counting every line including blanks. *)
  detail : string;
}

type ledger = {
  articles : World_constitution_types.t list;
      (** One entry per article id, in order of first appearance, each at its
          latest recorded state. *)
  rejected : rejected_line list;
      (** Lines that did not decode, in file order. They stay in the file: a
          reader reports them rather than dropping them silently, because a
          line nobody can read is a norm nobody can see. *)
}

type read_error =
  | Unreadable of {
      path : string;
      detail : string;
    }

val read_error_to_string : read_error -> string

val load : base_path:string -> (ledger, read_error) result
(** Read the whole ledger. A missing file is an empty ledger. *)

val in_force : ledger -> World_constitution_types.t list
(** The articles a world ratified and has neither superseded nor repealed —
    the only ones RFC-0442 renders into the system prompt. *)
