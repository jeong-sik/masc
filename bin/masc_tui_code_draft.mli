(** Immutable Code drafts. Paths in an address are the caller's confirmed,
    canonical server workspace pair; no filesystem access happens here. *)
type scope = Code_scope_project | Code_scope_keeper of string | Code_scope_repo of string

type address = { base_path : string; masc_root : string; scope : scope; path : string }
type source = { text : string; revision : string }
type ticket
type review_reason = Conflict of string | Uncertain of string

type phase =
  | Editable
  | Saving of ticket
  | Rejected of string
  | Needs_review of review_reason * source option

type t
val address : t -> address
val base : t -> source
val text : t -> string
val phase : t -> phase
val same_draft : t -> t -> bool
(** Immutable updates retain one draft identity; a recreated draft is distinct. *)
type ending = Empty_source | Final_lf | Final_crlf | No_final_newline
val ending : string -> ending
val equal_address : address -> address -> bool
val create : address:address -> source:source -> t
val edit : string -> t -> (t, string) result
(** A submitted draft cannot be changed or discarded until its own reply. *)
val can_discard : t -> bool
val begin_save : t -> (t * ticket, string) result
(** A conflict/uncertain draft requires a fresh observation and explicit
    {!adopt_current}; observation alone never grants another write. *)
val observe : source -> t -> t
val adopt_current : t -> (t, string) result

type outcome =
  | Save_succeeded of string
  | Save_refused of string
  | Save_conflict of string
  | Save_uncertain of string

type completion = Ignored | Retained of t | Committed of source
val complete : ticket -> outcome -> t -> completion
(** Only this exact submission can settle a draft. A replaced draft or duplicate
    reply cannot clear newer edits. [Committed] carries the submitted bytes. *)
