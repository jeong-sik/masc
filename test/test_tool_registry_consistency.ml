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

let test_mandatory_tools_are_registered () =
  init ();
  let mandatory = Keeper_tool_registry.core_always_tools in
  List.iter
    (fun name ->
      Alcotest.(check bool)
        (Printf.sprintf "mandatory tool %s has tag" name)
        true
        (Option.is_some (Tool_dispatch.lookup_tag name));
      Alcotest.(check bool)
        (Printf.sprintf "mandatory tool %s has schema" name)
        true
        (Option.is_some (Tool_dispatch.lookup_schema name)))
    mandatory
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

let test_retired_tools_are_absent () =
  init ();
  let retired_front_door_tools =
    [ "masc_operator_snapshot"
    ; "masc_operator_digest"
    ; "masc_operator_action"
    ; "masc_operator_confirm"
    ; "masc_operator_judgment_write"
    ; "masc_surface_audit"
    ; "masc_operation_start"
    ; "masc_dispatch_tick"
    ; "masc_goal_review"
    ]
  in
  let retired_tool_admin_surface =
    [ "masc_tool_admin_snapshot"
    ; "masc_tool_admin_update"
    ; "tool_admin_snapshot"
    ; "tool_admin_update"
    ]
  in
  let retired_masc_tool_shard =
    [ "masc_tool_list"
    ; "masc_tool_grant"
    ; "masc_tool_revoke"
    ]
  in
  let retired_tools =
    retired_front_door_tools @ retired_tool_admin_surface @ retired_masc_tool_shard
    |> sorted_set
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
    ; ( "mandatory_tools"
      , [ test_case "mandatory tools are registered" `Quick
            test_mandatory_tools_are_registered
        ] )
    ; ( "workspace_tools"
      , [ test_case "workspace schemas route to Mod_state" `Quick
            test_workspace_schemas_route_to_state
        ] )
    ; ( "retired_tools"
      , [ test_case "retired tools are absent" `Quick test_retired_tools_are_absent
        ] )
    ]
;;
