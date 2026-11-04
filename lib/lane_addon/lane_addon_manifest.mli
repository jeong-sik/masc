type error = Invalid_manifest of string | Io_failure of string
val error_to_string : error -> string
val load : path:string -> (Lane_addon_types.package, error) result
(** A package is runtime data. Its canonical manifest directory owns relative
    package files; no embedded configuration or domain dispatch is required. *)

val resolve_in_workspace : workspace:string -> string -> string option
(** [Some resolved] when [path] names an existing entry inside [workspace]. A
    relative name is read against [workspace]. The whole path resolves the way
    the kernel opens it, a link before the [..] that follows it, so a link
    inside the workspace cannot point out of it and [resolved] is the file the
    path opens. A path that does not exist is [None]. Callers check a manifest
    path a request named with this before [load] opens it, so a refusal never
    depends on what sits at a path outside the workspace. *)

val outside_workspace : string
(** The refusal text for a path [resolve_in_workspace] rejects. It names no
    path and does not say whether one exists. *)
