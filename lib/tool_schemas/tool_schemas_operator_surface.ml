(** The 19 tools RFC-0057's codegen owned, read from the binary-embedded
    [config/tools/masc_*.toml] declarations (RFC
    prompts-and-tool-definitions-outside-ocaml §2.2, migration item 5).

    RFC-0057 solved "one place owns a tool definition" by generating OCaml:
    [bin/gen_tool_descriptors.ml] held the definitions as OCaml values and a
    dune rule captured its stdout into [tool_descriptors_gen.ml]. This RFC
    solves the same problem with data files, which is why its header carries
    [supersedes: ["0057"]]. The definitions live here; the generator, its dune rule
    and its regression suite are gone. The two invariants that suite carried
    which had nothing to do with code generation — the masc_config category
    enum matching its owner, and the Operator_only [pause_status] staying off
    the Keeper-visible list — moved to [test_operator_surface_toml_parity].

    One file declares one tool; [schema_of_name] decodes it through
    [Tool_definition_toml] once at module initialization. A missing file or a
    declaration that does not decode refuses the boot instead of advertising a
    partial operator surface. *)

let schema_of_name = Tool_definition_embedded.schema

let ask = schema_of_name "masc_ask"
let ask_status = schema_of_name "masc_ask_status"
let ask_withdraw = schema_of_name "masc_ask_withdraw"
let broadcast = schema_of_name "masc_broadcast"
let config = schema_of_name "masc_config"
let dashboard = schema_of_name "masc_dashboard"
let gc = schema_of_name "masc_gc"
let sandbox_volume_gc = schema_of_name "masc_sandbox_volume_gc"
let keeper_waiting_inventory = schema_of_name "masc_keeper_waiting_inventory"
let messages = schema_of_name "masc_messages"
let pause_status = schema_of_name "masc_pause_status"
let plan_clear_task = schema_of_name "masc_plan_clear_task"
let plan_get_task = schema_of_name "masc_plan_get_task"
let plan_set_task = schema_of_name "masc_plan_set_task"
let start = schema_of_name "masc_start"
let tool_help = schema_of_name "masc_tool_help"

(* [schemas] is the list Tool_schemas_misc publishes. pause_status is absent
   from it by design — it is Operator_only, reached as an individual value
   rather than through the Keeper-visible list. *)
let schemas : Masc_domain.tool_schema list =
  [ ask; ask_status; ask_withdraw; broadcast; config; dashboard; gc; sandbox_volume_gc; keeper_waiting_inventory; messages; plan_clear_task; plan_get_task; plan_set_task; start; tool_help ]
;;
