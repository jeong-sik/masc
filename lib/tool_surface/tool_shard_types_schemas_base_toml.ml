(** The base keeper tools, read from [config/tools/keeper_*.toml] (RFC
    prompts-and-tool-definitions-outside-ocaml §2.2).

    Each value is decoded once at module initialization. A missing file or a
    declaration that does not decode refuses the boot rather than advertising a
    partial base surface, so a reader of these values never has to ask whether
    a schema loaded.

    keeper_memory_search advertises the source vocabulary [Keeper_tool_memory_runtime]
    owns; in TOML that is a literal, because nothing there reads an OCaml
    value. The owner stays the owner and [test_enum_mirror_sync] compares the
    advertised array against it, which is what RFC §2.2 asks for.
    [test_base_tool_toml_parity] pins the published base surface. *)

let schema_of_name name : Masc_domain.tool_schema =
  let rel = "tools/" ^ name ^ ".toml" in
  match Embedded_config.read rel with
  | None -> failwith (Printf.sprintf "embedded tool definition missing: %s" rel)
  | Some contents ->
    (match Tool_definition_toml.load ~name ~contents with
     | Ok { Tool_definition_toml.schema; _ } -> schema
     | Error message -> failwith message)
;;

let time_now = schema_of_name "keeper_time_now"
let lane_status = schema_of_name "keeper_lane_status"
let context_status = schema_of_name "keeper_context_status"
let memory_search = schema_of_name "keeper_memory_search"
let memory_retract = schema_of_name "keeper_memory_retract"
let memory_write = schema_of_name "keeper_memory_write"
let capability_search = schema_of_name "keeper_capability_search"
let tools_list = schema_of_name "keeper_tools_list"
