(** A full runtime.toml edit keeps the source revision on which it was based.
    Reading a newer file never silently rebases or discards the draft. *)
type document = { path : string; source_text : string; source_revision : string }
type t = private {
  base : document;
  text : string;
  current : document option;
  error : string option;
}

val open_document : document -> t
val edit : string -> t -> t
val failed : string -> t -> t
val observe : document -> t -> (t, string) result
(** Refuses a document from another config path. *)
val adopt_current : t -> (t, string) result
(** Keep the draft but explicitly adopt the displayed file's revision. *)
val replace_with_current : t -> (t, string) result
(** Explicitly discard the draft and use the displayed file instead. *)
