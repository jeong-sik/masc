(** Tool_catalog_inference — compatibility shim for effect-domain inference.

    Product tool-name ownership lives in schema/descriptor modules, not in
    [Tool_name]. Keep this module only to preserve
    [Tool_catalog.inferred_effect_domain] while callers migrate to explicit
    metadata. *)

(* [effect_domain] is defined in the zero-dep leaf [Tool_tag_types] and
   re-exported here by type-equality so the facade [Tool_catalog] and the public
   [tool_catalog.mli] / this module's [.mli] are unchanged. *)
type effect_domain = Tool_tag_types.effect_domain =
  | Read_only
  | Masc_workspace
  | Playground_write
  | Host_repo_write

let effect_domain_to_string = function
  | Read_only -> "read_only"
  | Masc_workspace -> "masc_workspace"
  | Playground_write -> "playground_write"
  | Host_repo_write -> "host_repo_write"

let inferred_effect_domain name =
  match name with
  | "tool_read_file" -> Some Read_only
  | _ -> None
;;
