(** The keeper runtime tools whose declarations moved to
    [config/tools/*.toml] (RFC prompts-and-tool-definitions-outside-ocaml
    §2.2), read from the binary-embedded config tree.

    Each value is decoded once at module initialization. A missing file or a
    declaration that does not decode refuses the boot rather than advertising a
    partial runtime surface, so a reader of these values never has to ask
    whether a schema loaded.

    All four now load from TOML, including the two whose numbers an OCaml
    module owns: keeper_artifact_read's max_bytes bounds belong to
    [Keeper_artifact_read] and keeper_analyze_image's media-type enum to
    [Keeper_vision_tool]. Moving them cut those derivations, and the pin that
    was supposed to arrive with the move did not. keeper_artifact_read then
    drifted: #32748 lowered the bound in OCaml and the file kept advertising
    65536, so a model reading the schema could ask for four times what the
    handler accepts. [test_keeper_runtime_schemas_toml_parity] now pins both
    files against their owner modules, which is what makes the literals safe.
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
(* RFC-0430 Phase 3 — provider Files tools. *)
let file_upload = schema_of_name "masc_file_upload"
let file_delete = schema_of_name "masc_file_delete"
let file_list = schema_of_name "masc_file_list"

(* The order a model reads these in; [Config.raw_all_tool_schemas] splices
   this list into the catalog. *)
let schemas =
  [ artifact_read
  ; fusion
  ; fusion_status
  ; file_upload
  ; file_delete
  ; file_list
  ; keeper_analyze_image
  ]

