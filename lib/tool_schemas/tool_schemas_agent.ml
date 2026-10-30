(** The three agent tools, read from [config/tools/*.toml] (RFC
    prompts-and-tool-definitions-outside-ocaml §2.2).

    Decoded once at module initialization. A missing file or a declaration that
    does not decode refuses the boot rather than advertising a partial agent
    surface, so a reader never has to ask whether the schema loaded.

    The [masc_agent_card] action enum used to be hand-mirrored here from
    [Tool_agent.valid_agent_card_action_strings] (#8501), because
    masc_tool_schemas only depends on masc_types and cannot reach the owner.
    The mirror still exists -- it is now the enum line in
    [config/tools/masc_agent_card.toml] -- and
    [test_agent_card_action_mirror] still compares the published values
    against the owner's list, so drift fails there as before. *)

let schema_of_name name : Masc_domain.tool_schema =
  let rel = "tools/" ^ name ^ ".toml" in
  match Embedded_config.read rel with
  | None -> failwith (Printf.sprintf "embedded tool definition missing: %s" rel)
  | Some contents ->
    (match Tool_definition_toml.load ~name ~contents with
     | Ok { Tool_definition_toml.schema; _ } -> schema
     | Error message -> failwith message)
;;

type operation =
  | Agent_card
  | Agent_fitness
  | Get_metrics
[@@deriving enumerate]

let operations = all_of_operation

let tool_name = function
  | Agent_card -> "masc_agent_card"
  | Agent_fitness -> "masc_agent_fitness"
  | Get_metrics -> "masc_get_metrics"
;;

let operation_of_tool_name value =
  List.find_opt (fun operation -> String.equal value (tool_name operation)) operations
;;

let schema operation = schema_of_name (tool_name operation)
let schemas : Masc_domain.tool_schema list = List.map schema operations
