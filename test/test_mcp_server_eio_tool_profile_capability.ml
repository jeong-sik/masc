open Alcotest

let annotation_fields tool_name =
  match
    Masc_mcp.Mcp_server_eio_tool_profile.tool_annotations_for_profile
      Masc_mcp.Mcp_server_eio_tool_profile.Full
      tool_name
  with
  | Some (`Assoc fields) -> fields
  | Some _ -> failf "annotations for %s was not an object" tool_name
  | None -> failf "annotations missing for %s" tool_name
;;

let annotation_field name tool_name =
  List.assoc_opt name (annotation_fields tool_name)
;;

let bool_annotation name tool_name =
  match annotation_field name tool_name with
  | Some (`Bool value) -> value
  | Some other ->
    failf "annotation %s for %s was %s" name tool_name (Yojson.Safe.to_string other)
  | None -> failf "annotation %s missing for %s" name tool_name
;;

let tool_json name =
  Masc_mcp.Mcp_server_eio_tool_profile.tool_json_for_profile
    Masc_mcp.Mcp_server_eio_tool_profile.Full
    { Masc_domain.name
    ; description = "test schema"
    ; input_schema = `Assoc [ "type", `String "object" ]
    }
;;

let json_string_field key json =
  match Yojson.Safe.Util.member key json with
  | `String value -> value
  | other -> failf "field %s was %s" key (Yojson.Safe.to_string other)
;;

let test_annotations_do_not_invent_read_only () =
  let name = "__profile_unknown_tool" in
  check bool "unknown readOnlyHint false" false (bool_annotation "readOnlyHint" name);
  check
    (option string)
    "unknown openWorldHint absent"
    None
    (Option.map Yojson.Safe.to_string (annotation_field "openWorldHint" name))
;;

let test_annotations_use_catalog_capabilities () =
  check
    bool
    "tool_read_file readOnlyHint from catalog capability"
    true
    (bool_annotation "readOnlyHint" "tool_read_file");
  check
    bool
    "tool_read_file openWorldHint closed"
    false
    (bool_annotation "openWorldHint" "tool_read_file");
  check
    bool
    "shell_exec destructiveHint from catalog capability"
    true
    (bool_annotation "destructiveHint" "shell_exec");
  check
    bool
    "shell_exec openWorldHint open"
    true
    (bool_annotation "openWorldHint" "shell_exec")
;;

let test_annotations_use_descriptor_public_alias_capabilities () =
  check
    bool
    "ReadFile readOnlyHint from descriptor"
    true
    (bool_annotation "readOnlyHint" "ReadFile");
  check
    bool
    "ReadFile openWorldHint closed"
    false
    (bool_annotation "openWorldHint" "ReadFile");
  check
    bool
    "SearchFiles readOnlyHint from descriptor"
    true
    (bool_annotation "readOnlyHint" "SearchFiles");
  check
    bool
    "WriteFile readOnlyHint false from descriptor"
    false
    (bool_annotation "readOnlyHint" "WriteFile");
  check
    bool
    "WriteFile destructiveHint from canonical internal capability"
    true
    (bool_annotation "destructiveHint" "WriteFile");
  check
    bool
    "Execute destructiveHint from canonical internal capability"
    true
    (bool_annotation "destructiveHint" "Execute")
;;

let test_tool_json_projects_descriptor_metadata_for_public_aliases () =
  let read_file = tool_json "ReadFile" in
  check
    string
    "ReadFile descriptor id"
    "agent.read_file"
    (json_string_field "descriptorId" read_file);
  check
    string
    "ReadFile canonical descriptor name"
    "tool_read_file"
    (json_string_field "descriptorCanonicalName" read_file);
  check
    string
    "ReadFile effect domain"
    "read_only"
    (json_string_field "effectDomain" read_file);
  let write_file = tool_json "WriteFile" in
  check
    string
    "WriteFile effect domain"
    "playground_write"
    (json_string_field "effectDomain" write_file);
  check
    string
    "WriteFile descriptor executor"
    "filesystem"
    (json_string_field "descriptorExecutor" write_file)
  ;
  let search_files = tool_json "SearchFiles" in
  check
    string
    "SearchFiles canonical descriptor name"
    "tool_search_files"
    (json_string_field "descriptorCanonicalName" search_files)
;;

let test_descriptor_resolution_capabilities_for_public_aliases () =
  let capability_has =
    Masc_mcp.Agent_tool_descriptor_resolution.capability_has
  in
  check
    bool
    "ReadFile read-only via descriptor resolution"
    true
    (capability_has Masc_mcp.Tool_capability.Read_only "ReadFile");
  check
    bool
    "SearchFiles read-only via descriptor resolution"
    true
    (capability_has Masc_mcp.Tool_capability.Read_only "SearchFiles");
  check
    bool
    "mcp-prefixed SearchFiles read-only via descriptor resolution"
    true
    (capability_has Masc_mcp.Tool_capability.Read_only "mcp__masc__SearchFiles");
  check
    bool
    "WriteFile destructive via descriptor resolution"
    true
    (capability_has Masc_mcp.Tool_capability.Destructive "WriteFile");
  check
    bool
    "Execute destructive via descriptor resolution"
    true
    (capability_has Masc_mcp.Tool_capability.Destructive "Execute");
  check
    bool
    "ReadFile not destructive via descriptor resolution"
    false
    (capability_has Masc_mcp.Tool_capability.Destructive "ReadFile")
;;

let () =
  run
    "mcp-server-eio-tool-profile-capability"
    [ ( "annotations"
      , [ test_case
            "do-not-invent-read-only"
            `Quick
            test_annotations_do_not_invent_read_only
        ; test_case
            "use-catalog-capabilities"
            `Quick
            test_annotations_use_catalog_capabilities
        ; test_case
            "use-descriptor-public-alias-capabilities"
            `Quick
            test_annotations_use_descriptor_public_alias_capabilities
        ; test_case
            "tool-json-projects-descriptor-metadata-for-public-aliases"
            `Quick
            test_tool_json_projects_descriptor_metadata_for_public_aliases
        ; test_case
            "descriptor-resolution-capabilities-for-public-aliases"
            `Quick
            test_descriptor_resolution_capabilities_for_public_aliases
        ] )
    ]
;;
