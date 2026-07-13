(** Pure schema lookup helpers shared by every Keeper tool-schema family. *)

let select_named_schemas (names : string list) (schemas : Masc_domain.tool_schema list)
  : Masc_domain.tool_schema list
  =
  names
  |> List.filter_map (fun name ->
    List.find_opt
      (fun (schema : Masc_domain.tool_schema) -> String.equal schema.name name)
      schemas)
;;
