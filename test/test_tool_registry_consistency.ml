open Masc

(** P0-2: Registry consistency tests for the Tool_dispatch registries.

    Asserts that:
    1. The runtime schema-registry key set equals the tag-registry key set.
    2. Mandatory (core-always) tools are present in the tag/schema registries.
    3. Retired tool names are absent from the tag/schema/handler registries.

    These invariants are foundational for the MASC/Keeper/OAS overhaul:
    every tool that can be dispatched must have both a tag (for token
    validation) and a schema (for input validation), and retired surfaces
    must not leak back into the runtime registry. *)

let init () = Masc_test_deps.init_keeper_tool_registry ()

let sorted_set names = List.sort_uniq String.compare names

let assert_same_set ~label ~expected ~actual =
  let expected = sorted_set expected in
  let actual = sorted_set actual in
  if expected <> actual
  then (
    let missing = List.filter (fun n -> not (List.mem n actual)) expected in
    let extra = List.filter (fun n -> not (List.mem n expected)) actual in
    Printf.printf "[%s] missing from actual: [%s]\n" label
      (String.concat "; " missing);
    Printf.printf "[%s] extra in actual: [%s]\n" label
      (String.concat "; " extra);
    Alcotest.fail (Printf.sprintf "%s set mismatch" label))
;;

let tag_registry_names () = Tool_dispatch.all_registered_names ()
let schema_registry_names () = Tool_dispatch.all_schema_names ()

let schema_inventory_names () =
  List.map (fun (s : Masc_domain.tool_schema) -> s.name) Config.raw_all_tool_schemas
;;

let workspace_schema_names () =
  List.map (fun (s : Masc_domain.tool_schema) -> s.name) Tool_schemas_workspace.schemas
;;

let expected_workspace_read_only_names =
  [ "masc_check"; "masc_goal_list"; "masc_status" ]
;;

let expected_workspace_hidden_names = []

let expect_some ~label = function
  | Some value -> value
  | None -> Alcotest.fail (label ^ " missing")
;;

let test_schema_set_equals_tag_registry_set () =
  init ();
  let tags = tag_registry_names () in
  let schemas = schema_registry_names () in
  Printf.printf "TAGS (%d): %s\n" (List.length tags)
    (String.concat "; " (List.sort String.compare tags));
  Printf.printf "INVENTORY (%d): %s\n" (List.length (schema_inventory_names ()))
    (String.concat "; " (List.sort String.compare (schema_inventory_names ())));
  Alcotest.(check int)
    "tag_registry_count equals schema_registry_count"
    (Tool_dispatch.tag_registry_count ())
    (List.length schemas);
  assert_same_set
    ~label:"tag_registry vs schema_registry"
    ~expected:tags
    ~actual:schemas
;;

let test_workspace_schemas_route_to_state () =
  init ();
  Tool_schemas_workspace.schemas
  |> List.iter (fun (schema : Masc_domain.tool_schema) ->
       Alcotest.(check bool)
         (Printf.sprintf "%s routes to Mod_state" schema.name)
       true
       (Unified_tool_registry.tag_of_name schema.name = Some Tool_dispatch.Mod_state))
;;

let test_workspace_schemas_match_dispatch_bindings () =
  init ();
  assert_same_set
    ~label:"workspace schema names vs dispatchable names"
    ~expected:(workspace_schema_names ())
    ~actual:Tool_workspace.dispatchable_names
;;

let test_workspace_schemas_have_tool_spec_metadata () =
  init ();
  let workspace_names = workspace_schema_names () in
  let missing_tool_specs =
    List.filter
      (fun name -> not (List.mem name (Tool_spec.all_registered_names ())))
      workspace_names
  in
  Alcotest.(check (list string))
    "workspace schemas registered via Tool_spec"
    []
    missing_tool_specs;
  let unexpected_read_only_contract =
    List.filter
      (fun name -> not (List.mem name workspace_names))
      expected_workspace_read_only_names
  in
  Alcotest.(check (list string))
    "expected read-only workspace tools exist"
    []
    unexpected_read_only_contract;
  let unexpected_hidden_contract =
    List.filter
      (fun name -> not (List.mem name workspace_names))
      expected_workspace_hidden_names
  in
  Alcotest.(check (list string))
    "expected hidden workspace tools exist"
    []
    unexpected_hidden_contract;
  List.iter
    (fun name ->
       let meta =
         Tool_catalog.registered_metadata name
         |> expect_some ~label:(Printf.sprintf "%s Tool_catalog metadata" name)
       in
       let expected_read_only = List.mem name expected_workspace_read_only_names in
       let expected_idempotent = false in
       let expected_hidden = List.mem name expected_workspace_hidden_names in
       Alcotest.(check (option bool))
         (Printf.sprintf "%s readonly metadata" name)
         (Some expected_read_only)
         meta.Tool_catalog.readonly;
       Alcotest.(check (option bool))
         (Printf.sprintf "%s idempotent metadata" name)
         (Some expected_idempotent)
         meta.Tool_catalog.idempotent;
       Alcotest.(check bool)
         (Printf.sprintf "%s hidden visibility" name)
         expected_hidden
         (meta.Tool_catalog.visibility = Tool_catalog.Hidden);
       Alcotest.(check bool)
         (Printf.sprintf "%s direct hidden call allowance" name)
         expected_hidden
         meta.Tool_catalog.allow_direct_call_when_hidden)
    workspace_names
;;

let test_default_metadata_has_no_implicit_execution_policy () =
  match
    Tool_catalog.execution_policy_of_metadata
      ~tool_name:"__unregistered_tool"
      Tool_catalog.default_metadata
  with
  | Ok _ -> Alcotest.fail "default metadata must not invent an execution policy"
  | Error (Tool_catalog.Missing_execution_policy { tool_name; missing_axes }) ->
    Alcotest.(check string) "diagnostic keeps tool name" "__unregistered_tool" tool_name;
    Alcotest.(check int) "all execution axes are absent" 3 (List.length missing_axes)
;;

let test_keeper_schemas_have_explicit_execution_policy () =
  let errors =
    Keeper_schema.schemas
    |> List.filter_map (fun (schema : Masc_domain.tool_schema) ->
      match List.assoc_opt schema.name Tool_catalog.explicit_metadata with
      | None -> Some (Printf.sprintf "%s: missing explicit metadata" schema.name)
      | Some metadata ->
        (match
           Tool_catalog.execution_policy_of_metadata
             ~tool_name:schema.name
             metadata
         with
         | Ok _ -> None
         | Error error ->
           Some (Tool_catalog.execution_policy_error_to_string error)))
  in
  Alcotest.(check (list string))
    "every Keeper schema has total catalog-owned execution policy"
    []
    errors
;;

let test_retired_tools_are_absent () =
  init ();
  (* Only fully retired tools — no live dispatch handler and no keeper
     descriptor — belong here. masc_operator_* were removed from this list
     because they are live tools: lib/operator/operator_tool.ml carries
     dispatch handlers for them. register_all() therefore legitimately
     registers them; they only appeared absent before when the
     Mcp_server_eio module-load bootstrap did not run in this executable. *)
  let retired_front_door_tools =
    [ "masc_operation_start"; "masc_dispatch_tick"; "masc_goal_review" ]
  in
  let retired_tool_admin_surface =
    [ "masc_tool_admin_snapshot"
    ; "masc_tool_admin_update"
    ; "tool_admin_snapshot"
    ; "tool_admin_update"
    ]
  in
  let retired_tools =
    retired_front_door_tools @ retired_tool_admin_surface |> sorted_set
  in
  let leaked_tag =
    List.filter (fun name -> Option.is_some (Tool_dispatch.lookup_tag name)) retired_tools
  in
  let leaked_schema =
    List.filter (fun name -> Option.is_some (Tool_dispatch.lookup_schema name)) retired_tools
  in
  let leaked_handler =
    List.filter (fun name -> Tool_dispatch.is_registered name) retired_tools
  in
  Alcotest.(check (list string)) "retired tools absent from tag registry" [] leaked_tag;
  Alcotest.(check (list string)) "retired tools absent from schema registry" [] leaked_schema;
  Alcotest.(check (list string)) "retired tools absent from handler registry" [] leaked_handler
;;

let () =
  let open Alcotest in
  run
    "Tool_registry_consistency"
    [ ( "registry_sets"
      , [ test_case "schema set equals tag_registry set" `Quick
            test_schema_set_equals_tag_registry_set
        ] )
    ; ( "workspace_tools"
      , [ test_case "workspace schemas route to Mod_state" `Quick
            test_workspace_schemas_route_to_state
        ; test_case "workspace schemas match dispatch bindings" `Quick
            test_workspace_schemas_match_dispatch_bindings
        ; test_case "workspace schemas have ToolSpec metadata" `Quick
            test_workspace_schemas_have_tool_spec_metadata
        ] )
    ; ( "keeper_tool_policy"
      , [ test_case
            "default metadata does not invent execution policy"
            `Quick
            test_default_metadata_has_no_implicit_execution_policy
        ; test_case
            "Keeper schemas have explicit execution policy"
            `Quick
            test_keeper_schemas_have_explicit_execution_policy
        ] )
    ; ( "retired_tools"
      , [ test_case "retired tools are absent" `Quick test_retired_tools_are_absent
        ] )
    ]
;;
