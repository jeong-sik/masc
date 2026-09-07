(** Tool_schemas_agent_timeline — the agent-timeline tool declaration, read
    from [config/tools/masc_agent_timeline.toml] (RFC
    prompts-and-tool-definitions-outside-ocaml §2.2).

    One operation today. The wire name is written once, in [operation_name];
    {!schemas} and {!operation_of_tool_name} both derive from {!definitions},
    so a second tool added to this surface cannot be advertised without a
    route or routed without a declaration.

    Decoded once at module initialization. A missing file or a declaration
    that does not decode refuses the boot rather than advertising a partial
    surface. *)

let schema_of_name name : Masc_domain.tool_schema =
  let rel = "tools/" ^ name ^ ".toml" in
  match Embedded_config.read rel with
  | None -> failwith (Printf.sprintf "embedded tool definition missing: %s" rel)
  | Some contents ->
    (match Tool_definition_toml.load ~name ~contents with
     | Ok { Tool_definition_toml.schema; _ } -> schema
     | Error message -> failwith message)
;;

type operation = Agent_timeline [@@deriving enumerate]

let operations = all_of_operation

let operation_name = function
  | Agent_timeline -> "masc_agent_timeline"
;;

let definitions : (operation * Masc_domain.tool_schema) list =
  List.map
    (fun operation -> operation, schema_of_name (operation_name operation))
    operations
;;

let schemas : Masc_domain.tool_schema list = List.map snd definitions

let operation_of_tool_name value =
  List.find_map
    (fun (operation, (schema : Masc_domain.tool_schema)) ->
       if String.equal value schema.name then Some operation else None)
    definitions
;;
