type error = Invalid_manifest of string | Io_failure of string
val error_to_string : error -> string
val load : path:string -> (Lane_addon_types.package, error) result
(** A package is runtime data. Its canonical manifest directory owns relative
    package files; no embedded configuration or domain dispatch is required. *)
