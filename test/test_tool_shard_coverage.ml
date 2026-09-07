(** Coverage for the immutable Keeper handler schema catalog. *)

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

let get_json_assoc key = function
  | `Assoc fields ->
    (match List.assoc_opt key fields with
     | Some (`Assoc assoc) -> Some assoc
     | Some _ | None -> None)
  | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null | `String _ -> None
;;

let family_catalog =
  [ Tool_shard_types.base_tools
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

let test_complete_flat_schema_catalog () =
  let expected_names = family_catalog |> schema_names in
  let catalog_names = schema_names Tool_shard.all_keeper_tool_schemas in
  Alcotest.(check (list string))
    "catalog contains every schema family exactly once"
    expected_names
    catalog_names
;;

let test_catalog_names_are_unique () =
  let names = schema_names Tool_shard.all_keeper_tool_schemas in
  Alcotest.(check int)
    "schema names are unique"
    (List.length (List.sort_uniq String.compare names))
    (List.length names)
;;

let test_voice_schemas_are_registered () =
  let catalog_names = schema_names Tool_shard.all_keeper_tool_schemas in
  let voice_names = schema_names Tool_shard_types.voice_tools in
  Alcotest.(check bool) "voice catalog is non-empty" true (voice_names <> []);
  List.iter
    (fun name ->
       Alcotest.(check bool)
         (name ^ " has a handler schema")
         true
         (List.mem name catalog_names))
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

let test_context_status_description_matches_current_output () =
  let schema =
    schema_by_name "keeper_context_status" Tool_shard_types.base_tools
  in
  List.iter
    (fun current_field ->
       Alcotest.(check bool)
         ("current field documented: " ^ current_field)
         true
         (contains schema.description current_field))
    [ "checkpoint_bytes"; "message_count"; "generation" ];
  List.iter
    (fun unobserved_field ->
       Alcotest.(check bool)
         ("unobserved field not promised: " ^ unobserved_field)
         false
         (contains schema.description unobserved_field))
    [ "context_ratio"; "context_tokens"; "context_max"; "last_model_used" ]
;;

let required_keeper_board_schema board_name =
  match Tool_shard_types.keeper_board_schema board_name with
  | Some schema -> schema
  | None ->
    Alcotest.failf
      "missing Keeper Board projection: %s"
      (Tool_name.Board_name.to_string board_name)
;;

let test_board_projections_are_not_in_flat_keeper_catalog () =
  let flat_names = schema_names Tool_shard.all_keeper_tool_schemas in
  Tool_name.Board_name.all
  |> List.filter_map Tool_shard_types.keeper_board_schema
  |> List.iter (fun (schema : Types.tool_schema) ->
    Alcotest.(check bool)
      (schema.name ^ " is not in the flat handler catalog")
      false
      (List.mem schema.name flat_names))
;;

let test_taskboard_verification_claim_contract () =
  let list_schema =
    schema_by_name "keeper_tasks_list" Tool_shard_types.taskboard_tools
  in
  let claim_schema =
    schema_by_name "keeper_task_claim" Tool_shard_types.taskboard_tools
  in
  let descriptions = list_schema.description ^ "\n" ^ claim_schema.description in
  Alcotest.(check bool)
    "awaiting verification is described as pending"
    true
    (contains descriptions "pending a verdict from the system LLM agent");
  Alcotest.(check bool)
    "awaiting verification is described as not claimable"
    true
    (contains descriptions "not claimable");
  Alcotest.(check bool)
    "obsolete verifier-by-claiming affordance absent"
    false
    (contains descriptions "may issue the verdict");
  Alcotest.(check bool)
    "obsolete awaiting claim-pool affordance absent"
    false
    (contains descriptions "unclaimed todo or awaiting_verification task")
;;

let test_masc_board_post_schema_supports_judgment () =
  let schema =
    required_keeper_board_schema Tool_name.Board_name.Board_post
  in
  match get_json_assoc "properties" schema.input_schema with
  | None -> Alcotest.fail "masc_board_post missing properties"
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

(* The Board is majority machine-authored (task verdict receipts, heartbeats).
   The handler reads exclude_system / exclude_automation straight from args and
   Board_dispatch.list_posts implements both, but the Keeper projection is a
   closed schema: a knob it omits is not merely unadvertised, it is rejected. *)
let test_keeper_board_list_can_exclude_machine_posts () =
  let schema = required_keeper_board_schema Tool_name.Board_name.Board_list in
  match get_json_assoc "properties" schema.input_schema with
  | None -> Alcotest.fail "masc_board_list missing properties"
  | Some properties ->
    List.iter
      (fun field ->
         Alcotest.(check bool)
           (field ^ " reaches the Keeper model")
           true
           (List.mem_assoc field properties))
      [ "exclude_system"; "exclude_automation" ]
;;

(* Same class: the handler reads parent_id (board_tool_post.ml:404) and the
   renderer already builds the reply tree from it (board_tool_format.ml:183),
   but the projection dropped it -- so a Keeper could reply to a post and never
   to another Keeper's comment. *)
let test_keeper_board_comment_can_reply_to_a_comment () =
  let schema = required_keeper_board_schema Tool_name.Board_name.Board_comment in
  match get_json_assoc "properties" schema.input_schema with
  | None -> Alcotest.fail "masc_board_comment missing properties"
  | Some properties ->
    Alcotest.(check bool)
      "parent_id reaches the Keeper model"
      true
      (List.mem_assoc "parent_id" properties)
;;

let test_ide_annotate_schema_is_the_memo_contract () =
  let schema =
    schema_by_name "keeper_ide_annotate" Tool_shard_types.filesystem_tools
  in
  Alcotest.(check bool)
    "unknown fields rejected"
    true
    (match schema.input_schema with
     | `Assoc fields ->
       List.assoc_opt "additionalProperties" fields = Some (`Bool false)
     | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null | `String _ ->
       false);
  match get_json_assoc "properties" schema.input_schema with
  | None -> Alcotest.fail "keeper_ide_annotate missing properties"
  | Some properties ->
    Alcotest.(check (list string))
      "the memo's four inputs and nothing else"
      [ "file_path"; "kind"; "line"; "text" ]
      (List.sort compare (List.map fst properties))
;;

let () =
  Alcotest.run
    "Keeper tool catalog"
    [ ( "flat_catalog"
      , [ Alcotest.test_case
            "complete schema catalog"
            `Quick
            test_complete_flat_schema_catalog
        ; Alcotest.test_case "unique exact names" `Quick test_catalog_names_are_unique
        ; Alcotest.test_case
            "voice schemas are registered"
            `Quick
            test_voice_schemas_are_registered
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
        ; Alcotest.test_case
            "context status current output"
            `Quick
            test_context_status_description_matches_current_output
        ; Alcotest.test_case
            "Board projections stay surface-local"
            `Quick
            test_board_projections_are_not_in_flat_keeper_catalog
        ; Alcotest.test_case
            "taskboard verification claim contract"
            `Quick
            test_taskboard_verification_claim_contract
        ; Alcotest.test_case
            "board post judgment"
            `Quick
            test_masc_board_post_schema_supports_judgment
        ; Alcotest.test_case
            "board list can exclude machine posts"
            `Quick
            test_keeper_board_list_can_exclude_machine_posts
        ; Alcotest.test_case
            "board comment can reply to a comment"
            `Quick
            test_keeper_board_comment_can_reply_to_a_comment
        ; Alcotest.test_case
            "IDE opaque references"
            `Quick
            test_ide_annotate_schema_is_the_memo_contract
        ] )
    ]
