(** MCP tool schemas for shared Goal planning and lifecycle operations, read
    from the binary-embedded [config/tools/masc_goal_*.toml] declarations (RFC
    prompts-and-tool-definitions-outside-ocaml §2.2).

    One file declares one tool; [schema_of_name] decodes it through
    [Tool_definition_toml] once at module initialization. A missing file or a
    declaration that does not decode refuses the boot instead of advertising a
    partial Goal surface.

    The [phase] and [action] enums are literals in those files, mirroring
    [Goal_phase.all] and [Goal_phase.Public_action.all]. Nothing in TOML can
    derive them from the variants, so [test_enum_mirror_sync] compares the
    published values against their owners — a constructor added to either
    variant without editing its file fails there rather than shipping a schema
    that never offers the value. *)

open Masc_domain

let schema_of_name name : tool_schema =
  let rel = "tools/" ^ name ^ ".toml" in
  match Embedded_config.read rel with
  | None -> failwith (Printf.sprintf "embedded tool definition missing: %s" rel)
  | Some contents ->
    (match Tool_definition_toml.load ~name ~contents with
     | Ok { Tool_definition_toml.schema; _ } -> schema
     | Error message -> failwith message)
;;

(* B1 — creation requires metric and target_value — is deliberately not a
   schema-level [required] on masc_goal_upsert: the one tool serves both create
   and update, and JSON Schema [required] is unconditional, so declaring it
   would reject every metadata update of an existing goal. The create/update
   split is only decidable against the store, so the handler enforces it on the
   creation branch (Goal_store.upsert_goal, inside the write lock). *)
(* One schema per Tool_name.Goal_name constructor. Spelling the three names
   here again let a constructor be routable (Tool_workspace.goal_handler) and
   never advertised; now a new one either brings its config/tools file or
   refuses the boot, which is what schema_of_name already does for the rest. *)
let schemas : tool_schema list =
  List.map
    (fun name -> schema_of_name (Tool_name.Goal_name.to_string name))
    Tool_name.Goal_name.all
;;
