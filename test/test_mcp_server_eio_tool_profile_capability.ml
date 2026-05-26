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

let test_annotations_ignore_dispatch_only_read_only () =
  let name = "__profile_dispatch_only_ro" in
  Masc_mcp.Tool_dispatch.init_read_only_set [ name ];
  check bool "dispatch-only readOnlyHint ignored" false (bool_annotation "readOnlyHint" name);
  check
    (option string)
    "dispatch-only openWorldHint absent"
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

let () =
  run
    "mcp-server-eio-tool-profile-capability"
    [ ( "annotations"
      , [ test_case
            "ignore-dispatch-only-read-only"
            `Quick
            test_annotations_ignore_dispatch_only_read_only
        ; test_case
            "use-catalog-capabilities"
            `Quick
            test_annotations_use_catalog_capabilities
        ] )
    ]
;;
