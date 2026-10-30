(* The masc_ask tool is declared in config/tools/masc_ask.toml and read at
   module-init time; a declaration that does not decode refuses the boot
   rather than advertising a partial surface. These tests name that
   declaration so a typo fails CI instead of a running binary, and pin the
   two places where the schema and the code have to agree. *)

let the_ask_schema_loads () =
  let schema = Tool_schemas_operator_surface.ask in
  Alcotest.(check string) "tool name" "masc_ask" schema.Masc_domain.name;
  Alcotest.(check bool) "description is not empty" true
    (String.trim schema.Masc_domain.description <> "")

let rec find_enum json =
  match json with
  | `Assoc fields -> (
      match List.assoc_opt "enum" fields with
      | Some (`List items) -> Some items
      | Some _ | None -> List.find_map (fun (_, value) -> find_enum value) fields)
  | `List items -> List.find_map find_enum items
  | _ -> None

(* The wire boundary parses "single" and "multi" and rejects anything else. A
   schema that advertised a third mode would reach the operator as a choice
   that always fails, which is worse than not offering it. *)
let the_schema_offers_only_modes_the_boundary_parses () =
  match find_enum Tool_schemas_operator_surface.ask.Masc_domain.input_schema with
  | None -> Alcotest.fail "the ask schema declares no mode enum"
  | Some items ->
      let labels =
        List.sort compare
          (List.filter_map (function `String s -> Some s | _ -> None) items)
      in
      Alcotest.(check (list string)) "modes the schema offers" [ "multi"; "single" ] labels

(* Registering a tool means the dispatch vocabulary and the wire name agree in
   both directions. A name that parses to an operation whose canonical name is
   something else would route one tool's arguments into another's handler. *)
let the_tool_name_round_trips_through_the_dispatch_vocabulary () =
  match Tool_schemas_misc.mcp_runtime_operation_of_tool_name "masc_ask" with
  | None -> Alcotest.fail "masc_ask is not in the MCP runtime dispatch vocabulary"
  | Some operation ->
      Alcotest.(check string) "canonical name" "masc_ask"
        (Tool_schemas_misc.mcp_runtime_tool_name operation)

let every_dispatched_operation_has_a_schema () =
  List.iter
    (fun operation ->
      let name = Tool_schemas_misc.mcp_runtime_tool_name operation in
      let schema = Tool_schemas_misc.mcp_runtime_schema operation in
      Alcotest.(check string) ("schema for " ^ name) name schema.Masc_domain.name)
    Tool_schemas_misc.mcp_runtime_operations

(* Asking and reading back are two tools because they are two acts: one writes
   a question, the other only looks. Both have to be reachable, and the read
   one must not claim it writes. *)
let the_ask_status_schema_loads () =
  let schema = Tool_schemas_operator_surface.ask_status in
  Alcotest.(check string) "tool name" "masc_ask_status" schema.Masc_domain.name;
  Alcotest.(check bool) "description is not empty" true
    (String.trim schema.Masc_domain.description <> "")

(* A question stays open "until a human answers it or the asking Keeper
   withdraws it". The store has had [withdraw] since it was written and nothing
   outside its own tests ever called it, so the second half of that sentence
   was not true. *)
let the_withdraw_schema_loads () =
  let schema = Tool_schemas_operator_surface.ask_withdraw in
  Alcotest.(check string) "tool name" "masc_ask_withdraw" schema.Masc_domain.name;
  Alcotest.(check bool) "description is not empty" true
    (String.trim schema.Masc_domain.description <> "")

let both_ask_tools_are_dispatched () =
  List.iter
    (fun name ->
      match Tool_schemas_misc.mcp_runtime_operation_of_tool_name name with
      | None -> Alcotest.failf "%s is not in the MCP runtime dispatch vocabulary" name
      | Some operation ->
          Alcotest.(check string) ("canonical name for " ^ name) name
            (Tool_schemas_misc.mcp_runtime_tool_name operation))
    [ "masc_ask"; "masc_ask_status"; "masc_ask_withdraw" ]

let () =
  Alcotest.run "masc_ask tool surface"
    [
      ( "the declaration",
        [
          Alcotest.test_case "the ask schema loads" `Quick the_ask_schema_loads;
          Alcotest.test_case "the withdraw schema loads" `Quick
            the_withdraw_schema_loads;
          Alcotest.test_case "modes match the boundary" `Quick
            the_schema_offers_only_modes_the_boundary_parses;
          Alcotest.test_case "the ask_status schema loads" `Quick
            the_ask_status_schema_loads;
        ] );
      ( "dispatch",
        [
          Alcotest.test_case "the tool name round trips" `Quick
            the_tool_name_round_trips_through_the_dispatch_vocabulary;
          Alcotest.test_case "both ask tools are dispatched" `Quick
            both_ask_tools_are_dispatched;
          Alcotest.test_case "every dispatched operation has a schema" `Quick
            every_dispatched_operation_has_a_schema;
        ] );
    ]
