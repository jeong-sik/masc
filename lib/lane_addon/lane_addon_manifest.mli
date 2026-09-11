val load : path:string -> (Lane_addon_types.package, string) result
(** A package is runtime data. Its canonical manifest directory owns relative
    package files; no embedded configuration or domain dispatch is required. *)
