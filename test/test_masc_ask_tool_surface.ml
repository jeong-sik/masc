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

(* A live Keeper reaches its own tools under the agent alias its runtime was
   spawned with, not under the bare name the registry holds. Measured against
   a running server on 2026-08-26: every unit test passed while a real keeper
   was refused as an unregistered keeper -- the message named its alias, not
   its registry name -- because the tool read the alias straight through. The
   guard is right; the name it was handed was not.

   The keeper this happened to is not named here. The rule does not depend on
   which name it was, and the identity guard forbids a live one in tracked
   source: an ordinary word eventually picks somebody's. *)
let resolves = Masc.Mcp_tool_runtime_ask.asking_keeper_name

let the_spellings_a_keeper_runtime_spawns_under () =
  (* Four spellings reach the same registry row. The first fix here matched
     only the first two by hand, so the other two stayed broken in exactly the
     way the measurement had just found. *)
  Alcotest.(check string) "the canonical agent alias" "orrery"
    (resolves "keeper-orrery-agent");
  Alcotest.(check string) "underscore spelling" "orrery"
    (resolves "keeper_orrery_agent");
  Alcotest.(check string) "the bare prefix form" "orrery" (resolves "keeper-orrery")

let the_registry_name_passes_through () =
  (* An operator and these tests call under the registry name itself. It has
     to survive unchanged, or answering breaks for everyone who is not a
     Keeper runtime. *)
  Alcotest.(check string) "unchanged" "orrery" (resolves "orrery")

let a_name_no_canonicaliser_knows_is_left_alone () =
  (* Left alone on purpose: the registry check downstream is what refuses a
     caller that is not a Keeper, and it can only name the caller if it is
     handed the name the caller actually used. *)
  Alcotest.(check string) "an ordinary client name" "codex-mcp-client"
    (resolves "codex-mcp-client")

(* Asking and reading back are two tools because they are two acts: one writes
   a question, the other only looks. Both have to be reachable, and the read
   one must not claim it writes. *)
let the_ask_status_schema_loads () =
  let schema = Tool_schemas_operator_surface.ask_status in
  Alcotest.(check string) "tool name" "masc_ask_status" schema.Masc_domain.name;
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
    [ "masc_ask"; "masc_ask_status" ]

let () =
  Alcotest.run "masc_ask tool surface"
    [
      ( "the declaration",
        [
          Alcotest.test_case "the ask schema loads" `Quick the_ask_schema_loads;
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
      ( "who is asking",
        [
          Alcotest.test_case "the spellings a Keeper runtime spawns under" `Quick
            the_spellings_a_keeper_runtime_spawns_under;
          Alcotest.test_case "the registry name passes through" `Quick
            the_registry_name_passes_through;
          Alcotest.test_case "a name no canonicaliser knows is left alone" `Quick
            a_name_no_canonicaliser_knows_is_left_alone;
        ] );
    ]
