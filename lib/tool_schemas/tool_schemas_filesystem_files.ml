(** Name, description and parameters for the four filesystem tools, read from
    the binary-embedded [config/tools/tool_{read,edit,write,search}_file*.toml]
    declarations (RFC prompts-and-tool-definitions-outside-ocaml §2.2).

    One file declares one tool; [schema_of_name] decodes it through
    [Tool_definition_toml] once at module initialization. A missing file or a
    declaration that does not decode refuses the boot instead of advertising a
    partial filesystem surface.

    Read and Edit are the closed objects of the four. Read's runtime handler
    reads exactly the four declared keys, so a fifth would be a silent no-op.
    Edit is patch-only and its translator used to infer overwrite from an
    undeclared 'content' key — closing the schema rejects that key instead of
    silently escalating to a whole-file overwrite (masc#31573). Write and Grep
    were open before this move and stay open. *)

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

let read_file = schema_of_name "Read"
let edit_file = schema_of_name "Edit"
let write_file = schema_of_name "Write"
let search_files = schema_of_name "Grep"
