open Masc

(** P0-2: Registry consistency tests for the Tool_dispatch registries.

    Asserts that:
    1. The runtime schema-registry key set equals the tag-registry key set.
    2. Mandatory (core-always) tools are present in the tag/schema registries.

    These invariants are foundational for the MASC/Keeper/AGENT_CORE overhaul:
    every tool that can be dispatched must have both a tag (for token
    validation) and a schema (for input validation). *)

let init () = Masc_test_deps.init_unified_tool_registry ()

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

let rec canonical_json = function
  | `Assoc fields ->
    `Assoc
      (fields
       |> List.map (fun (name, value) -> name, canonical_json value)
       |> List.sort (fun (left, _) (right, _) -> String.compare left right))
  | `List values -> `List (List.map canonical_json values)
  | (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _) as value ->
    value
;;

let canonical_json_string value =
  value |> canonical_json |> Yojson.Safe.to_string
;;

let test_schema_inventory_matches_dispatch_validation_registry () =
  init ();
  List.iter
    (fun (schema : Masc_domain.tool_schema) ->
      match Tool_dispatch.lookup_schema schema.name with
      | None -> Alcotest.failf "%s missing from dispatch schema registry" schema.name
      | Some registered_schema ->
        Alcotest.(check string)
          (schema.name ^ " advertised and validation schemas match")
          (canonical_json_string schema.input_schema)
          (canonical_json_string registered_schema))
    Config.raw_all_tool_schemas
;;

let test_every_descriptor_has_exact_runtime_schema () =
  let missing =
    Keeper_tool_descriptor.all_descriptors ()
    |> List.filter_map (fun (descriptor : Keeper_tool_descriptor.t) ->
      match Unified_tool_registry.runtime_schema_for_descriptor descriptor with
      | Some _ -> None
      | None -> Some descriptor.internal_name)
    |> sorted_set
  in
  Alcotest.(check (list string))
    "every descriptor internal handler has an exact runtime schema"
    []
    missing
;;

let schema_property_names schema =
  match Json_util.assoc_member_opt "properties" schema with
  | Some (`Assoc properties) -> List.map fst properties
  | _ -> []
;;

let test_translated_descriptor_keeps_distinct_runtime_schema () =
  init ();
  let edit_descriptor =
    match Keeper_tool_descriptor.find_public "Edit" with
    | Some descriptor -> descriptor
    | None -> Alcotest.fail "Edit descriptor missing"
  in
  let runtime_schema =
    match Tool_dispatch.lookup_schema "tool_edit_file" with
    | Some schema -> schema
    | None -> Alcotest.fail "tool_edit_file runtime schema missing"
  in
  let public_properties = schema_property_names edit_descriptor.input_schema in
  let runtime_properties = schema_property_names runtime_schema in
  Alcotest.(check bool)
    "Edit public schema owns file_path"
    true
    (List.mem "file_path" public_properties);
  Alcotest.(check bool)
    "Edit public schema does not expose runtime path"
    false
    (List.mem "path" public_properties);
  Alcotest.(check bool)
    "tool_edit_file runtime schema owns translated path"
    true
    (List.mem "path" runtime_properties);
  Alcotest.(check bool)
    "tool_edit_file runtime schema does not reuse public file_path"
    false
    (List.mem "file_path" runtime_properties)
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

let test_tag_resolution_requires_exact_ownership () =
  Alcotest.(check (option bool))
    "known Keeper tool resolves from its descriptor"
    (Some true)
    (Option.map
       (fun tag -> tag = Tool_dispatch.Mod_external)
       (Unified_tool_registry.tag_of_name "masc_keeper_status"));
  Alcotest.(check (option bool))
    "public tool resolves from its descriptor"
    (Some true)
    (Option.map
       (fun tag -> tag = Tool_dispatch.Mod_external)
       (Unified_tool_registry.tag_of_name "Write"));
  Alcotest.(check (option bool))
    "inline runtime tool resolves from its schema owner"
    (Some true)
    (Option.map
       (fun tag -> tag = Tool_dispatch.Mod_inline)
       (Unified_tool_registry.tag_of_name "masc_start"));
  Alcotest.(check (option bool))
    "Keeper-like prefix has no owner"
    None
    (Option.map
       (fun tag -> tag = Tool_dispatch.Mod_external)
       (Unified_tool_registry.tag_of_name "masc_keeper_unknown"))
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
      (fun name -> not (List.mem name (Tool_dispatch.all_registered_names ())))
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
      (Tool_catalog.default_metadata ~required_permission:Masc_domain.CanAdmin)
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

let test_every_registered_schema_has_catalog_permission () =
  init ();
  let missing =
    Tool_dispatch.all_schema_names ()
    |> List.filter (fun name ->
      Option.is_none (Tool_catalog.registered_metadata name))
  in
  Alcotest.(check (list string))
    "every registered schema has catalog-owned permission metadata"
    []
    missing
;;

(* HTTP routes that authorize through [with_tool_auth] need a catalog entry
   under the name they pass as ~tool_name. The approval routes used to borrow
   "masc_keeper_delegate_cancel", which made the permission a dispatchable
   tool's business and left the route invisible in the catalog; the entries
   below pin the dedicated keys so neither regression can return silently. *)
let test_approval_route_auth_keys_are_dedicated_hidden_entries () =
  let route_keys =
    [ "keeper_tool_approval_route"; "keeper_tool_approval_mode_route" ]
  in
  List.iter
    (fun name ->
      match Tool_catalog.registered_metadata name with
      | None ->
        Alcotest.failf "%s is missing from the catalog: with_tool_auth would \
                        reject every caller with 'use unregistered tool'"
          name
      | Some meta ->
        Alcotest.(check bool)
          (name ^ " is hidden from the public surface")
          true
          (meta.visibility = Tool_catalog.Hidden);
        Alcotest.(check bool)
          (name ^ " allows the direct call the HTTP route makes")
          true
          meta.allow_direct_call_when_hidden;
        Alcotest.(check bool)
          (name ^ " keeps route authority at admin tier")
          true
          (meta.required_permission = Masc_domain.CanAdmin);
        (* Route keys must stay route-only: no schema, no dispatch path. A
           schema here would put an uncallable name on the tool surface. *)
        Alcotest.(check bool)
          (name ^ " has no dispatchable schema")
          false
          (List.mem name (Tool_dispatch.all_schema_names ())))
    route_keys
;;

let () =
  let open Alcotest in
  run
    "Tool_registry_consistency"
    [ ( "registry_sets"
      , [ test_case "schema set equals tag_registry set" `Quick
            test_schema_set_equals_tag_registry_set
        ; test_case
            "schema inventory matches dispatch validation registry"
            `Quick
            test_schema_inventory_matches_dispatch_validation_registry
        ; test_case
            "every descriptor has an exact runtime schema"
            `Quick
            test_every_descriptor_has_exact_runtime_schema
        ; test_case
            "translated descriptors keep distinct runtime schemas"
            `Quick
            test_translated_descriptor_keeps_distinct_runtime_schema
        ] )
    ; ( "workspace_tools"
      , [ test_case "workspace schemas route to Mod_state" `Quick
            test_workspace_schemas_route_to_state
        ; test_case "workspace schemas match dispatch bindings" `Quick
            test_workspace_schemas_match_dispatch_bindings
        ; test_case "workspace schemas have ToolSpec metadata" `Quick
            test_workspace_schemas_have_tool_spec_metadata
        ; test_case "tag resolution requires exact ownership" `Quick
            test_tag_resolution_requires_exact_ownership
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
        ; test_case
            "every registered schema has catalog permission"
            `Quick
            test_every_registered_schema_has_catalog_permission
        ; test_case
            "approval routes own dedicated hidden auth keys"
            `Quick
            test_approval_route_auth_keys_are_dedicated_hidden_entries
        ] )
    ]
;;
