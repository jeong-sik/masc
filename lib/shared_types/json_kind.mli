(** Total mapping from [Yojson.Safe.t] to its kind name string.

    Used in [of_json] error messages so operators see which JSON
    kind arrived rather than a bare "expected X" label.  Returns
    one of {{!{["null"; "bool"; "int"; "float"; "string";
    "object"; "array"]}}}. *)
val name : Yojson.Safe.t -> string
