(** Read-only declaration rows. No metadata, runtime, authentication or sandbox
    is created or probed while listing Keepers. *)
type requirement = Runtime_check_required | Sandbox_check_required | Declaration_invalid

type t = { name : string; requirements : requirement list }

val missing : base_path:string -> persisted_names:string list -> t list
val requirement_label : requirement -> string
val to_json : t -> Yojson.Safe.t

(** Which of the two row shapes a keeper list entry is. A [Declaration_row] is
    a Keeper declared in config that has never booted: it has no metadata, no
    runtime diagnostic and no trust, so nothing that reads runtime health may
    ask it for one. *)
type row_kind = Declaration_row | Runtime_row

val row_kind_of_json : Yojson.Safe.t -> (row_kind, string) result
(** Reads the [declaration_only] key {!to_json} writes. [Error] when the key
    holds something other than a boolean. *)
