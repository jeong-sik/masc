(** The keeper runtime tools whose declarations moved to
    [config/tools/*.toml] (RFC prompts-and-tool-definitions-outside-ocaml
    §2.2), read from the binary-embedded config tree.

    Each value is decoded once at module initialization. A missing file or a
    declaration that does not decode refuses the boot rather than advertising a
    partial runtime surface, so a reader of these values never has to ask
    whether a schema loaded.

    Three of the four tools published here stay in OCaml for now. keeper_artifact_read takes its max_bytes bounds and default
    from [Keeper_artifact_read] and keeper_analyze_image takes its media-type enum from
    [Keeper_vision_tool]; a TOML literal would cut that derivation, so each
    moves once it has a test pinning the file against its owner.
    masc_fusion_status emits an empty ["required"] list, which the loader omits
    because nothing declares itself required -- moving it would change the
    bytes, and the empty list is a no-op that five tools carry and twenty-six
    already omit. That inconsistency is its own change.

    [test_keeper_runtime_schemas_toml_parity] pins all four against what the
    list published before any of this moved. *)

let schema_of_name name : Masc_domain.tool_schema =
  let rel = "tools/" ^ name ^ ".toml" in
  match Embedded_config.read rel with
  | None -> failwith (Printf.sprintf "embedded tool definition missing: %s" rel)
  | Some contents ->
    (match Tool_definition_toml.load ~name ~contents with
     | Ok { Tool_definition_toml.schema; _ } -> schema
     | Error message -> failwith message)
;;

let fusion = schema_of_name "masc_fusion"
let fusion_status = schema_of_name "masc_fusion_status"
let artifact_read = schema_of_name "keeper_artifact_read"
let keeper_analyze_image = schema_of_name "keeper_analyze_image"

(* The order a model reads these in; [Config.raw_all_tool_schemas] splices
   this list into the catalog. *)
let schemas = [ artifact_read; fusion; fusion_status; keeper_analyze_image ]
