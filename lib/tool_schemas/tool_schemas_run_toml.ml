(** The four run tools, read from [config/tools/masc_run_*.toml] (RFC
    prompts-and-tool-definitions-outside-ocaml §2.2).

    Each value is decoded once at module initialization. A missing file or a
    declaration that does not decode refuses the boot rather than advertising a
    partial run surface, so a reader of these values never has to ask whether a
    schema loaded.

    [test_run_tool_toml_parity] keeps the publication order; the descriptions
    and schemas it also pinned were copies of these values. *)

let schema_of_name = Tool_definition_embedded.schema

let init = schema_of_name "masc_run_init"
let plan = schema_of_name "masc_run_plan"
let get = schema_of_name "masc_run_get"
let list = schema_of_name "masc_run_list"
