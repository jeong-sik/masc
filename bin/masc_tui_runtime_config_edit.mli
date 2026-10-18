(** A full runtime.toml edit keeps the source revision on which it was based.
    Reading a newer file never silently rebases or discards the draft. *)
type document = { path : string; source_text : string; source_revision : string }
type t = private {
  draft_owner : unit ref;
  basis_owner : unit ref;
  current_read_floor : int option;
    (** [None]: no uncertain-save barrier. Otherwise only a read started after
        this generation may become the current comparison. *)
  basis_read_generation : int option;
    (** [None]: the chosen base has no stamped TUI read provenance. *)
  current_read_generation : int option;
    (** [None]: no stamped current comparison is held. *)
  base : document;
  text : string;
  current : document option;
  error : string option;
}

val open_document : ?read_generation:int -> document -> t
val edit : string -> t -> t
val same_draft : t -> t -> bool
(** Same editing intent; observations and failures preserve it. Editing or
    explicitly choosing a new base starts another intent, even for equal text. *)
val same_basis : t -> t -> bool
(** Same chosen revision basis. Editing preserves it; explicit adoption,
    replacement and a freshly opened document choose a new basis. *)
val failed : string -> t -> t
val unconfirmed : after_read:int -> string -> t -> t
(** Preserve both input owners and text, but retire any current-file comparison
    that predates an uncertain save. Adoption must wait for a new observation. *)
val observe : ?read_generation:int -> document -> t -> (t, string) result
(** Refuses another config path or a read predating an uncertain-save barrier.
    An omitted generation cannot clear such a barrier. *)
val adopt_current : t -> (t, string) result
(** Keep the draft but explicitly adopt the displayed file's revision. *)
val replace_with_current : t -> (t, string) result
(** Explicitly discard the draft and use the displayed file instead. *)
