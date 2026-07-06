open Alcotest
module Profile = Masc.Mcp_server_eio_tool_profile

let contains_substring haystack needle =
  let hlen = String.length haystack in
  let nlen = String.length needle in
  let rec loop index =
    if nlen = 0 then true
    else if index + nlen > hlen then false
    else if String.sub haystack index nlen = needle then true
    else loop (index + 1)
  in
  loop 0
;;

let annotation_fields tool_name =
  match
    Masc.Mcp_server_eio_tool_profile.tool_annotations_for_profile
      Masc.Mcp_server_eio_tool_profile.Full
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
  Masc.Mcp_server_eio_tool_profile.tool_json_for_profile
    Masc.Mcp_server_eio_tool_profile.Full
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

let test_decode_cursor_result_reports_base64_error () =
  match
    Profile.decode_cursor_result ~kind:"tools" "not-base64"
  with
  | Ok _ -> fail "expected base64 decode error"
  | Error (Profile.Cursor_base64_decode_error { kind; message }) ->
      check string "kind" "tools" kind;
      check bool "message present" true (String.length message > 0)
  | Error _ -> fail "expected Cursor_base64_decode_error"
;;

let test_decode_cursor_result_reports_kind_mismatch () =
  let cursor = Base64.encode_string "resources:1" in
  match Profile.decode_cursor_result ~kind:"tools" cursor with
  | Ok _ -> fail "expected kind mismatch"
  | Error (Profile.Cursor_kind_mismatch { expected_kind }) ->
      check string "expected kind" "tools" expected_kind
  | Error _ -> fail "expected Cursor_kind_mismatch"
;;

let test_decode_cursor_result_reports_non_integer_offset () =
  let cursor = Base64.encode_string "tools:not-an-int" in
  match Profile.decode_cursor_result ~kind:"tools" cursor with
  | Ok _ -> fail "expected offset parse error"
  | Error (Profile.Cursor_offset_parse_error { kind; raw_offset }) ->
      check string "kind" "tools" kind;
      check string "raw offset" "not-an-int" raw_offset
  | Error _ -> fail "expected Cursor_offset_parse_error"
;;

let test_decode_cursor_result_reports_negative_offset () =
  let cursor = Base64.encode_string "tools:-1" in
  match Profile.decode_cursor_result ~kind:"tools" cursor with
  | Ok _ -> fail "expected negative offset"
  | Error (Profile.Cursor_negative_offset { kind; offset }) ->
      check string "kind" "tools" kind;
      check int "offset" (-1) offset
  | Error _ -> fail "expected Cursor_negative_offset"
;;

let test_page_items_with_cursor_preserves_invalid_cursor_contract () =
  match
    Profile.page_items_with_cursor ~kind:"tools" [ "a"; "b" ] (Some "not-base64")
  with
  | Ok _ -> fail "expected invalid cursor error"
  | Error msg ->
      check bool "contract label" true (contains_substring msg "Invalid params: cursor");
      check bool "received cursor present" true (contains_substring msg "not-base64")
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
    (bool_annotation "readOnlyHint" "Read");
  check
    bool
    "ReadFile openWorldHint closed"
    false
    (bool_annotation "openWorldHint" "Read");
  check
    bool
    "SearchFiles readOnlyHint from descriptor"
    true
    (bool_annotation "readOnlyHint" "Grep");
  check
    bool
    "Search secondary alias readOnlyHint from descriptor"
    true
    (bool_annotation "readOnlyHint" "Search");
  check
    bool
    "WriteFile readOnlyHint false from descriptor"
    false
    (bool_annotation "readOnlyHint" "Write");
  check
    bool
    "WriteFile destructiveHint from canonical internal capability"
    true
    (bool_annotation "destructiveHint" "Write");
  check
    bool
    "Execute destructiveHint from canonical internal capability"
    true
    (bool_annotation "destructiveHint" "Execute")
;;

let test_tool_json_projects_descriptor_metadata_for_public_aliases () =
  let read_file = tool_json "Read" in
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
  let write_file = tool_json "Write" in
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
  let search_files = tool_json "Grep" in
  check
    string
    "SearchFiles canonical descriptor name"
    "tool_search_files"
    (json_string_field "descriptorCanonicalName" search_files);
  let search_alias = tool_json "Search" in
  check
    string
    "Search alias canonical descriptor name"
    "tool_search_files"
    (json_string_field "descriptorCanonicalName" search_alias)
;;

let test_descriptor_resolution_capabilities_for_public_aliases () =
  let capability_has =
    Masc.Keeper_tool_descriptor_resolution.capability_has
  in
  check
    bool
    "ReadFile read-only via descriptor resolution"
    true
    (capability_has Tool_capability.Read_only "Read");
  check
    bool
    "SearchFiles read-only via descriptor resolution"
    true
    (capability_has Tool_capability.Read_only "Grep");
  check
    bool
    "Search secondary alias read-only via descriptor resolution"
    true
    (capability_has Tool_capability.Read_only "Search");
  check
    bool
    "mcp-prefixed SearchFiles read-only via descriptor resolution"
    true
    (capability_has Tool_capability.Read_only "mcp__masc__Grep");
  check
    bool
    "WriteFile destructive via descriptor resolution"
    true
    (capability_has Tool_capability.Destructive "Write");
  check
    bool
    "Execute destructive via descriptor resolution"
    true
    (capability_has Tool_capability.Destructive "Execute");
  check
    bool
    "ReadFile not destructive via descriptor resolution"
    false
    (capability_has Tool_capability.Destructive "Read")
;;

let test_default_instructions_pin_start_transition_workflow () =
  let instructions = Masc.Mcp_server_eio_tool_profile.default_instructions () in
  check
    bool
    "write summary names start"
    true
    (contains_substring instructions "claim/start/done");
  check
    bool
    "workflow includes start transition"
    true
    (contains_substring instructions "masc_transition(start)");
  check
    bool
    "workflow does not skip start"
    false
    (contains_substring
       instructions
       "masc_transition(claim) -> work in a repo-local worktree")
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
        ; test_case
            "default-instructions-pin-start-transition-workflow"
            `Quick
            test_default_instructions_pin_start_transition_workflow
        ] )
    ; ( "pagination-cursor"
      , [ test_case
            "decode-cursor-result-reports-base64-error"
            `Quick
            test_decode_cursor_result_reports_base64_error
        ; test_case
            "decode-cursor-result-reports-kind-mismatch"
            `Quick
            test_decode_cursor_result_reports_kind_mismatch
        ; test_case
            "decode-cursor-result-reports-non-integer-offset"
            `Quick
            test_decode_cursor_result_reports_non_integer_offset
        ; test_case
            "decode-cursor-result-reports-negative-offset"
            `Quick
            test_decode_cursor_result_reports_negative_offset
        ; test_case
            "page-items-preserves-invalid-cursor-contract"
            `Quick
            test_page_items_with_cursor_preserves_invalid_cursor_contract
        ] )
    ]
;;
