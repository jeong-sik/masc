(** Coverage for the immutable Keeper tool catalog facade.

    Schema families are organizational only: the model projection is the
    complete de-duplicated catalog and contains no runtime membership state. *)

module Tool_shard = Masc.Tool_shard
module Tool_shard_types = Tool_shard_types
module Types = Masc_domain

let contains text needle = Astring.String.is_infix ~affix:needle text

let schema_by_name name schemas =
  match
    List.find_opt
      (fun (schema : Types.tool_schema) -> String.equal schema.name name)
      schemas
  with
  | Some schema -> schema
  | None -> Alcotest.failf "missing schema: %s" name
;;

let schema_names schemas =
  List.map (fun (schema : Types.tool_schema) -> schema.name) schemas
;;

let dedupe_names names =
  let _, names_rev =
    List.fold_left
      (fun (seen, names_rev) name ->
         if Set_util.StringSet.mem name seen
         then seen, names_rev
         else Set_util.StringSet.add name seen, name :: names_rev)
      (Set_util.StringSet.empty, [])
      names
  in
  List.rev names_rev
;;

let get_json_assoc key = function
  | `Assoc fields ->
    (match List.assoc_opt key fields with
     | Some (`Assoc assoc) -> Some assoc
     | Some _ | None -> None)
  | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null | `String _ -> None
;;

let family_catalog =
  [ Tool_shard_types.base_tools
  ; Tool_shard_types.board_tools
  ; Tool_shard_types.filesystem_tools
  ; Tool_shard_types.search_files_tools
  ; Tool_shard_types.typed_execute_tools
  ; Tool_shard_types.voice_tools
  ; Tool_shard_types.library_tools
  ; Tool_shard_types.surface_tools
  ; Tool_shard_types.taskboard_tools
  ]
  |> List.concat
;;

let test_complete_flat_model_catalog () =
  let expected_names = family_catalog |> schema_names |> dedupe_names in
  let catalog_names = schema_names Tool_shard.all_keeper_tool_schemas in
  let model_names = schema_names Tool_shard.keeper_model_tools in
  Alcotest.(check (list string))
    "catalog contains every schema family exactly once"
    expected_names
    catalog_names;
  Alcotest.(check (list string))
    "model projection is the complete flat catalog"
    catalog_names
    model_names
;;

let test_catalog_names_are_unique () =
  let names = schema_names Tool_shard.all_keeper_tool_schemas in
  Alcotest.(check int)
    "exact-name de-duplication"
    (List.length (List.sort_uniq String.compare names))
    (List.length names)
;;

let test_voice_tools_are_model_visible () =
  let model_names = schema_names Tool_shard.keeper_model_tools in
  let voice_names = schema_names Tool_shard_types.voice_tools in
  Alcotest.(check bool) "voice catalog is non-empty" true (voice_names <> []);
  List.iter
    (fun name ->
       Alcotest.(check bool)
         (name ^ " is model-visible")
         true
         (List.mem name model_names))
    voice_names
;;

let test_runtime_admin_tools_absent () =
  let names = schema_names Tool_shard.all_keeper_tool_schemas in
  List.iter
    (fun name ->
       Alcotest.(check bool) (name ^ " absent") false (List.mem name names))
    [ "masc_tool_" ^ "list"
    ; "masc_tool_" ^ "grant"
    ; "masc_tool_" ^ "revoke"
    ]
;;

let test_user_facing_alias_copy_is_canonical () =
  let execute =
    schema_by_name "tool_execute" Tool_shard_types.typed_execute_tools
  in
  let search =
    schema_by_name "tool_search_files" Tool_shard_types.search_files_tools
  in
  let surface_text = execute.description ^ "\n" ^ search.description in
  List.iter
    (fun retired ->
       Alcotest.(check bool)
         ("retired alias absent: " ^ retired)
         false
         (contains surface_text retired))
    [ "Search" ^ "Files"; "Edit" ^ "File"; "Read" ^ "File"; "Write" ^ "File" ];
  Alcotest.(check bool)
    "canonical Execute alias present"
    true
    (contains surface_text "Execute")
;;

let test_base_tools () =
  let names = schema_names Tool_shard.base_tools in
  List.iter
    (fun name ->
       Alcotest.(check bool) (name ^ " present") true (List.mem name names))
    [ "keeper_time_now"; "keeper_context_status"; "keeper_memory_search" ]
;;

let test_board_tools () =
  let names = schema_names Tool_shard.board_tools in
  List.iter
    (fun name ->
       Alcotest.(check bool) (name ^ " present") true (List.mem name names))
    [ "keeper_board_post"
    ; "keeper_board_list"
    ; "keeper_board_comment"
    ; "keeper_board_vote"
    ]
;;

let test_keeper_board_post_schema_supports_judgment () =
  let schema = schema_by_name "keeper_board_post" Tool_shard.board_tools in
  match get_json_assoc "properties" schema.input_schema with
  | None -> Alcotest.fail "keeper_board_post missing properties"
  | Some properties ->
    List.iter
      (fun field ->
         Alcotest.(check bool)
           (field ^ " present")
           true
           (List.mem_assoc field properties))
      [ "classification_reason"; "judgment"; "sources" ];
    Alcotest.(check bool)
      "claim-specific evidence gate absent"
      false
      (List.mem_assoc "quantitative_evidence" properties)
;;

let test_ide_annotation_schema_uses_opaque_references () =
  let schema =
    schema_by_name "keeper_ide_annotate" Tool_shard_types.filesystem_tools
  in
  Alcotest.(check bool)
    "unknown annotation fields rejected"
    true
    (match schema.input_schema with
     | `Assoc fields ->
       List.assoc_opt "additionalProperties" fields = Some (`Bool false)
     | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null | `String _ ->
       false);
  match get_json_assoc "properties" schema.input_schema with
  | None -> Alcotest.fail "keeper_ide_annotate missing properties"
  | Some properties ->
    Alcotest.(check bool)
      "opaque references exposed"
      true
      (List.mem_assoc "references" properties);
    List.iter
      (fun retired_field ->
         Alcotest.(check bool)
           ("product-specific field absent: " ^ retired_field)
           false
           (List.mem_assoc retired_field properties))
      [ "board_" ^ "post_id"
      ; "comment_" ^ "id"
      ; "pr_" ^ "id"
      ; "git_" ^ "ref"
      ; "log_" ^ "id"
      ; "session_" ^ "id"
      ; "operation_" ^ "id"
      ; "worker_run_" ^ "id"
      ]
;;

let () =
  Alcotest.run
    "Keeper tool catalog"
    [ ( "flat_catalog"
      , [ Alcotest.test_case
            "complete model projection"
            `Quick
            test_complete_flat_model_catalog
        ; Alcotest.test_case "unique exact names" `Quick test_catalog_names_are_unique
        ; Alcotest.test_case
            "voice is model-visible"
            `Quick
            test_voice_tools_are_model_visible
        ; Alcotest.test_case
            "runtime admin tools absent"
            `Quick
            test_runtime_admin_tools_absent
        ] )
    ; ( "schema_contracts"
      , [ Alcotest.test_case
            "canonical alias copy"
            `Quick
            test_user_facing_alias_copy_is_canonical
        ; Alcotest.test_case "base tools" `Quick test_base_tools
        ; Alcotest.test_case "board tools" `Quick test_board_tools
        ; Alcotest.test_case
            "board post judgment"
            `Quick
            test_keeper_board_post_schema_supports_judgment
        ; Alcotest.test_case
            "IDE opaque references"
            `Quick
            test_ide_annotation_schema_uses_opaque_references
        ] )
    ]
