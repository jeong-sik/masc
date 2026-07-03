(** test_persona_tool_reachability — descriptor/shard-backed tool access.

    The retired [config/tool_policy.toml] group file must not be the source of
    persona tool reachability. Persona shard names resolve through Tool_shard
    and the keeper policy layer then filters descriptor/registry tools. *)

module Tool_shard = Masc.Tool_shard

let schema_names schemas =
  schemas
  |> List.map (fun (schema : Masc_domain.tool_schema) -> schema.name)
  |> List.sort_uniq String.compare
;;

let assert_contains name names =
  Alcotest.(check bool) name true (List.mem name names)
;;

let assert_not_contains name names =
  Alcotest.(check bool) name false (List.mem name names)
;;

let test_repo_no_longer_seeds_tool_policy_toml () =
  Alcotest.(check bool)
    "repo seed removed"
    false
    (Sys.file_exists (Masc_test_deps.source_path "config/tool_policy.toml"))
;;

let test_persona_shards_resolve_expected_tool_families () =
  let names =
    Tool_shard.tools_of_shards
      [ "filesystem"; "search_files"; "surface"; "taskboard" ]
    |> schema_names
  in
  List.iter
    (fun name -> assert_contains name names)
    [ "tool_read_file"
    ; "tool_edit_file"
    ; "tool_write_file"
    ; "keeper_ide_annotate"
    ; "tool_search_files"
    ; "keeper_surface_read"
    ; "keeper_surface_post"
    ; "keeper_person_note_set"
    ; "keeper_tasks_list"
    ; "keeper_tasks_audit"
    ; "keeper_broadcast"
    ; "keeper_task_claim"
    ; "keeper_task_done"
    ; "keeper_task_create"
    ]
;;

let test_unknown_policy_group_names_are_not_shards () =
  List.iter
    (fun name ->
       Alcotest.(check bool)
         ("unknown shard: " ^ name)
         true
         (Option.is_none (Tool_shard.get_shard name)))
    [ "workspace_write"; "execute"; "masc.goal" ]
;;

let test_unsharded_execute_is_not_a_toml_group () =
  let names = schema_names Tool_shard.keeper_model_tools in
  assert_contains "tool_execute" names;
  assert_not_contains "keeper_tool_search" names
;;

let () =
  Alcotest.run
    "persona_tool_reachability"
    [ ( "descriptor_shards"
      , [ Alcotest.test_case
            "repo no longer seeds tool_policy.toml"
            `Quick
            test_repo_no_longer_seeds_tool_policy_toml
        ; Alcotest.test_case
            "persona shard names resolve tool families"
            `Quick
            test_persona_shards_resolve_expected_tool_families
        ; Alcotest.test_case
            "legacy policy group names are not shards"
            `Quick
            test_unknown_policy_group_names_are_not_shards
        ; Alcotest.test_case
            "execute is unsharded default"
            `Quick
            test_unsharded_execute_is_not_a_toml_group
        ] )
    ]
;;
