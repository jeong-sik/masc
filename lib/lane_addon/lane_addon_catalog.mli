(** One level of local workspace packages; discovery never starts a worker.
    Filesystem operations are blocking: call from a system thread in Eio. *)
type metadata = { title : string; revision : string; description : string option }
type entry =
  | Folder of string
  | Package of { manifest_path : string; metadata : metadata }
  | Issue of { path : string; message : string }
type t = { directory : string; parent : string option; entries : entry list }

val discover :
  base_path:string -> directory:string option ->
  load_package:(path:string -> (metadata, string) result) -> (t, string) result
(** [None] starts at the workspace root; relative directories are workspace
    relative. Loads only lane.toml in this directory and its immediate children.
    Paths are canonicalized and checked inside the workspace before calling
    the loader. This is a path check, not an atomic filesystem sandbox: the
    loader opens independently, so a concurrent writer can replace a checked
    manifest or ancestor before that open, as in the existing preview path.
    Unreadable/invalid entries remain issues, not empty-success placeholders.
    A package directory remains navigable by its manifest's parent directory. *)
val to_json : t -> Yojson.Safe.t
val of_json : Yojson.Safe.t -> (t, string) result
