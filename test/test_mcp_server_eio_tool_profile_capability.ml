open Alcotest

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

(* Descriptor facts are this server's own, so they sit under its [_meta] key
   rather than beside the fields [Tool] defines. *)
let json_string_field key json =
  let catalog =
    json
    |> Yojson.Safe.Util.member "_meta"
    |> Yojson.Safe.Util.member Masc.Mcp_server.tool_catalog_meta_key
  in
  match Yojson.Safe.Util.member key catalog with
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
    (option string)
    "tool_read_file does not infer idempotentHint from read-only"
    None
    (Option.map
       Yojson.Safe.to_string
       (annotation_field "idempotentHint" "tool_read_file"))
;;

let test_annotations_use_descriptor_public_capabilities () =
  check
    bool
    "ReadFile readOnlyHint from descriptor"
    true
    (bool_annotation "readOnlyHint" "Read");
  check
    bool
    "SearchFiles readOnlyHint from descriptor"
    true
    (bool_annotation "readOnlyHint" "Grep");
  check
    bool
    "WriteFile readOnlyHint false from descriptor"
    false
    (bool_annotation "readOnlyHint" "Write")
;;

let test_tool_json_projects_descriptor_metadata_for_public_names () =
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
  let write_file = tool_json "Write" in
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
    (json_string_field "descriptorCanonicalName" search_files)
;;

let test_descriptor_resolution_capabilities_for_public_names () =
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
    "mcp-prefixed SearchFiles read-only via descriptor resolution"
    true
    (capability_has Tool_capability.Read_only "mcp__masc__Grep");
  check bool "WriteFile is not read-only" false
    (capability_has Tool_capability.Read_only "Write");
  check bool "Execute is not read-only" false
    (capability_has Tool_capability.Read_only "Execute")
;;

let test_full_profile_admission_uses_catalog_direct_call_policy () =
  let state =
    Masc.Mcp_server.For_testing.create_state
      ~base_path:(Filename.get_temp_dir_name ())
  in
  let advertised_names =
    Masc.Mcp_server_eio_tool_profile.tool_schemas_for_profile
      ~include_hidden:true
      state
      Masc.Mcp_server_eio_tool_profile.Full
    |> List.map (fun (schema : Masc_domain.tool_schema) -> schema.name)
  in
  (* The corpus is every tool name this binary knows, from both places that
     know one. [Config.raw_all_tool_schemas] is nine static lists concatenated
     by hand and the operator family is not among them, because those tools
     reach the surface through [Tool_spec.register] at load time instead. A
     corpus that reads only the static side never visits a Hidden tool with
     direct calls denied, which is the branch the control assertion at the
     bottom of this test is here to prove was visited. *)
  let corpus_names =
    List.map
      (fun (schema : Masc_domain.tool_schema) -> schema.name)
      Masc.Config.raw_all_tool_schemas
    @ Tool_dispatch.all_schema_names ()
    @ Tool_catalog.known_names ()
    |> List.sort_uniq String.compare
  in
  let hidden_disallowed = ref 0 in
  List.iter
    (fun name ->
      let schema : Masc_domain.tool_schema =
        { name; description = ""; input_schema = `Assoc [] }
      in
      let metadata = Tool_catalog.metadata schema.name in
      if
        metadata.visibility = Tool_catalog.Hidden
        && not metadata.allow_direct_call_when_hidden
      then incr hidden_disallowed;
      (* Three conditions, not two. The front-door corpus is one of them, and
         it was invisible while this loop only walked names that were in it by
         construction: masc_pause carries a broadcast policy and is dispatched
         in process, but tool_control keeps its schema out of Config on
         purpose, so the Full profile does not admit it and should not. *)
      let expected =
        Masc.Config.is_raw_tool_name schema.name
        && Tool_catalog.is_visible ~include_hidden:true schema.name
        && Tool_catalog.allow_direct_call schema.name
      in
      check
        bool
        (schema.name ^ " Full-profile admission follows catalog policy")
        expected
        (Masc.Mcp_server_eio_tool_profile.tool_allowed_in_profile
           state
           Masc.Mcp_server_eio_tool_profile.Full
           schema.name);
      check
        bool
        (schema.name ^ " Full-profile advertisement matches admission")
        expected
        (List.mem schema.name advertised_names))
    corpus_names;
  check
    bool
    "contract corpus includes a hidden direct-call denial"
    true
    (!hidden_disallowed > 0)
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
            "use-descriptor-public-capabilities"
            `Quick
            test_annotations_use_descriptor_public_capabilities
        ; test_case
            "tool-json-projects-descriptor-metadata-for-public-names"
            `Quick
            test_tool_json_projects_descriptor_metadata_for_public_names
        ; test_case
            "descriptor-resolution-capabilities-for-public-names"
            `Quick
            test_descriptor_resolution_capabilities_for_public_names
        ; test_case
            "full-profile-admission-uses-catalog-direct-call-policy"
            `Quick
            test_full_profile_admission_uses_catalog_direct_call_policy
        ] )
    ]
;;
