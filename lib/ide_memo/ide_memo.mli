(** A line memo is a comment whose body follows one grammar:

    {v
    masc(AUTHOR): TEXT
    masc(AUTHOR) KIND: TEXT
    v}

    [AUTHOR] is one or more of [A-Za-z0-9_.-]. [KIND] is [decision],
    [question] or [bookmark]; its absence is a plain comment. [TEXT] is the
    rest of the line. The memo is the comment itself: it travels with the
    file into diffs, commits and reviews, and it moves with the line below
    it when the file is edited, which a line number stored elsewhere does
    not. This module is the one place the grammar is spelled, for the
    reader and for a writer composing one. *)

type t =
  { author : string
  ; kind : Agent_observation.annotation_kind
  ; text : string
  }

type parsed =
  | Memo of t
  | Malformed of string
      (** The comment starts with [masc(] and does not finish the grammar:
          the reason names what is missing, so a writer sees the memo it
          meant to leave rather than a comment nobody reads. *)
  | Not_a_memo  (** Any other comment, including one that does not close on its row. *)

val of_comment : string -> parsed
(** [of_comment token] reads a lexer's comment token, markers included:
    [(* … *)], [/* … */], [// …] or [# …]. A block comment must close on
    the same row. *)

val make
  :  author:string
  -> kind:Agent_observation.annotation_kind
  -> text:string
  -> (t, string) result
(** A memo a writer can print. Refused with the reason when the author has
    a character outside [A-Za-z0-9_.-], or the text is empty or spans
    lines. *)

val to_body : t -> string
(** The comment body, without markers: ["masc(alpha) question: why"]. A
    writer puts it inside the file's own comment syntax; [of_comment] reads
    it back. *)

val kind_word : Agent_observation.annotation_kind -> string option
(** The grammar's word for a kind, and [None] for the plain comment, which
    the grammar spells by leaving the word out. *)
