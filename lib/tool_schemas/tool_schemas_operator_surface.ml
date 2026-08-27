(** The 19 tools RFC-0057's codegen owned, read from the binary-embedded
    [config/tools/masc_*.toml] declarations (RFC
    prompts-and-tool-definitions-outside-ocaml §2.2, migration item 5).

    RFC-0057 solved "one place owns a tool definition" by generating OCaml:
    [bin/gen_tool_descriptors.ml] held the definitions as OCaml values and a
    dune rule captured its stdout into [tool_descriptors_gen.ml]. This RFC
    solves the same problem with data files, which is why its header carries
    [supersedes: ["0057"]]. The definitions live here; the generator, its dune rule
    and its regression suite are gone. The three invariants that suite carried
    which had nothing to do with code generation — the masc_config category
    enum matching its owner, keeper_spawn staying unpublished, and the
    Operator_only control trio staying off the Keeper-visible list — moved to
    [test_operator_surface_toml_parity].

    One file declares one tool; [schema_of_name] decodes it through
    [Tool_definition_toml] once at module initialization. A missing file or a
    declaration that does not decode refuses the boot instead of advertising a
    partial operator surface. *)

let schema_of_name name : Masc_domain.tool_schema =
  let rel = "tools/" ^ name ^ ".toml" in
  match Embedded_config.read rel with
  | None -> failwith (Printf.sprintf "embedded tool definition missing: %s" rel)
  | Some contents ->
    (match Tool_definition_toml.load ~name ~contents with
     | Ok { Tool_definition_toml.schema; _ } -> schema
     | Error message -> failwith message)
;;

let ask = schema_of_name "masc_ask"
let ask_status = schema_of_name "masc_ask_status"
let ask_withdraw = schema_of_name "masc_ask_withdraw"
let broadcast = schema_of_name "masc_broadcast"
let config = schema_of_name "masc_config"
let dashboard = schema_of_name "masc_dashboard"
let deliver = schema_of_name "masc_deliver"
let gc = schema_of_name "masc_gc"
let keeper_waiting_inventory = schema_of_name "masc_keeper_waiting_inventory"
let messages = schema_of_name "masc_messages"
let note_add = schema_of_name "masc_note_add"
let pause = schema_of_name "masc_pause"
let pause_status = schema_of_name "masc_pause_status"
let plan_clear_task = schema_of_name "masc_plan_clear_task"
let plan_get = schema_of_name "masc_plan_get"
let plan_get_task = schema_of_name "masc_plan_get_task"
let plan_init = schema_of_name "masc_plan_init"
let plan_set_task = schema_of_name "masc_plan_set_task"
let plan_update = schema_of_name "masc_plan_update"
let resume = schema_of_name "masc_resume"
let start = schema_of_name "masc_start"
let tool_help = schema_of_name "masc_tool_help"

(* [schemas] is the list Tool_schemas_misc publishes. pause / resume /
   pause_status are absent from it by design — they are Operator_only, reached
   as individual values rather than through the Keeper-visible list. *)
let schemas : Masc_domain.tool_schema list =
  [ ask; ask_status; ask_withdraw; broadcast; config; dashboard; deliver; gc; keeper_waiting_inventory; messages; note_add; plan_clear_task; plan_get; plan_get_task; plan_init; plan_set_task; plan_update; start; tool_help ]
;;
