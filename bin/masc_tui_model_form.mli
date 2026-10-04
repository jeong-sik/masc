(** Structured editing and duplication of a selected account/model binding.
    All changes are drafts until the existing config preview/save succeeds. *)
type mode = Edit | Copy
type t
val create : mode -> Masc_tui_model_runtime_table.row -> t
val rows : width:int -> height:int -> t -> string list
val paste : t -> string -> t
type outcome = Editing of t | Cancelled | Submit of t
val key : t -> string -> outcome
val refused : t -> string -> t
val apply : t -> string -> (string, string) result
(** Re-read and transform the current source. Copies model and binding settings,
    keeps the same provider/account and API model, and never changes route order.
    Editing context/output is binding-local; effort/temperature edit the named
    shared model and the form states this explicitly. *)
