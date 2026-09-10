(** Read-only declaration rows. No metadata, runtime, authentication or sandbox
    is created or probed while listing Keepers. *)
type requirement = Runtime_check_required | Sandbox_check_required | Declaration_invalid

type t = { name : string; requirements : requirement list }

val missing : base_path:string -> persisted_names:string list -> t list
val requirement_label : requirement -> string
val to_json : t -> Yojson.Safe.t
