(** Tests for Tool_catalog tier system — 3-tier tool filtering *)

module Tool_catalog = Masc_mcp.Tool_catalog

let with_env key value f =
  let old = Sys.getenv_opt key in
  Unix.putenv key value;
  Fun.protect
    ~finally:(fun () ->
      match old with
      | Some prev -> Unix.putenv key prev
      | None ->
          (* OCaml stdlib has no unsetenv; blank matches the enabled default
             path we are asserting for placeholder_tools_enabled. *)
          Unix.putenv key "")
    f

let () =
  let open Alcotest in
  run "Tool_tier"
    [
      ( "essential_tools",
        [
          test_case "contains expected core tools" `Quick (fun () ->
              let essential =
                [
                  "masc_join"; "masc_leave"; "masc_status"; "masc_start";
                  "masc_add_task"; "masc_claim_next"; "masc_transition";
                  "masc_tasks"; "masc_broadcast"; "masc_heartbeat";
                  "masc_messages"; "masc_worktree_create";
                  "masc_worktree_list"; "masc_worktree_remove";
                  "masc_plan_init"; "masc_plan_get"; "masc_plan_set_task";
                  "masc_plan_update"; "masc_who"; "masc_dashboard";
                  "masc_agent_timeline";
                ]
              in
              List.iter
                (fun name ->
                  check bool (name ^ " is essential") true
                    (Tool_catalog.tool_tier name = Tool_catalog.Essential))
                essential);
          test_case "count is 21" `Quick (fun () ->
              check int "essential count" 21
                (Tool_catalog.tier_tool_count Tool_catalog.Essential));
        ] );
      ( "standard_tools",
        [
          test_case "includes all essential tools" `Quick (fun () ->
              check bool "masc_join in standard" true
                (Tool_catalog.is_in_tier Tool_catalog.Standard "masc_join");
              check bool "masc_dashboard in standard" true
                (Tool_catalog.is_in_tier Tool_catalog.Standard "masc_dashboard"));
          test_case "includes board tools" `Quick (fun () ->
              check bool "masc_board_post" true
                (Tool_catalog.is_in_tier Tool_catalog.Standard "masc_board_post");
              check bool "masc_board_search" true
                (Tool_catalog.is_in_tier Tool_catalog.Standard
                   "masc_board_search"));
          test_case "includes team session tools" `Quick (fun () ->
              check bool "masc_team_session_start" true
                (Tool_catalog.is_in_tier Tool_catalog.Standard
                   "masc_team_session_start");
              check bool "masc_team_session_step" true
                (Tool_catalog.is_in_tier Tool_catalog.Standard
                   "masc_team_session_step"));
          test_case "includes governance v2 tools" `Quick (fun () ->
              check bool "masc_cases" true
                (Tool_catalog.is_in_tier Tool_catalog.Standard
                   "masc_cases");
              check bool "masc_case_status" true
                (Tool_catalog.is_in_tier Tool_catalog.Standard
                   "masc_case_status"));
          test_case "includes decision tools" `Quick (fun () ->
              check bool "decision_create" true
                (Tool_catalog.is_in_tier Tool_catalog.Standard "decision_create");
              check bool "decision_status" true
                (Tool_catalog.is_in_tier Tool_catalog.Standard "decision_status"));
          test_case "count is reasonable (40-60)" `Quick (fun () ->
              let n = Tool_catalog.tier_tool_count Tool_catalog.Standard in
              check bool "between 40 and 60" true (n >= 40 && n <= 60));
        ] );
      ( "full_tier",
        [
          test_case "is_in_tier Full always returns true" `Quick (fun () ->
              check bool "arbitrary tool" true
                (Tool_catalog.is_in_tier Tool_catalog.Full
                   "masc_some_unknown_tool_xyz");
              check bool "essential tool" true
                (Tool_catalog.is_in_tier Tool_catalog.Full "masc_join"));
          test_case "tier_tool_count returns -1 for Full" `Quick (fun () ->
              check int "unknown count" (-1)
                (Tool_catalog.tier_tool_count Tool_catalog.Full));
        ] );
      ( "tool_tier",
        [
          test_case "essential tool returns Essential" `Quick (fun () ->
              check string "tier" "essential"
                (Tool_catalog.tier_to_string
                   (Tool_catalog.tool_tier "masc_join")));
          test_case "standard-only tool returns Standard" `Quick (fun () ->
              check string "tier" "standard"
                (Tool_catalog.tier_to_string
                   (Tool_catalog.tool_tier "masc_board_post")));
          test_case "unknown tool returns Full" `Quick (fun () ->
              check string "tier" "full"
                (Tool_catalog.tier_to_string
                   (Tool_catalog.tool_tier "masc_risc_pipeline_status")));
        ] );
      ( "tier_of_string",
        [
          test_case "parses valid tier names" `Quick (fun () ->
              check bool "essential" true
                (Tool_catalog.tier_of_string "essential"
                = Some Tool_catalog.Essential);
              check bool "standard" true
                (Tool_catalog.tier_of_string "standard"
                = Some Tool_catalog.Standard);
              check bool "full" true
                (Tool_catalog.tier_of_string "full" = Some Tool_catalog.Full));
          test_case "rejects invalid names" `Quick (fun () ->
              check bool "bogus" true
                (Tool_catalog.tier_of_string "bogus" = None);
              check bool "empty" true
                (Tool_catalog.tier_of_string "" = None));
        ] );
      ( "is_in_tier_filtering",
        [
          test_case "Essential excludes standard-only tools" `Quick (fun () ->
              check bool "board_post not essential" false
                (Tool_catalog.is_in_tier Tool_catalog.Essential
                   "masc_board_post"));
          test_case "Standard excludes full-only tools" `Quick (fun () ->
              check bool "risc tool not standard" false
                (Tool_catalog.is_in_tier Tool_catalog.Standard
                   "masc_risc_pipeline_status"));
          test_case "Essential subset property" `Quick (fun () ->
              let essentials =
                [
                  "masc_join"; "masc_leave"; "masc_status"; "masc_add_task";
                  "masc_transition"; "masc_broadcast"; "masc_heartbeat";
                ]
              in
              List.iter
                (fun name ->
                  check bool (name ^ " also in standard") true
                    (Tool_catalog.is_in_tier Tool_catalog.Standard name))
                essentials);
        ] );
      ( "metadata_to_fields",
        [
          test_case "includes tier in output" `Quick (fun () ->
              let fields = Tool_catalog.metadata_to_fields "masc_join" in
              let tier_val =
                List.assoc_opt "tier" fields
                |> Option.map (function `String s -> s | _ -> "")
                |> Option.value ~default:""
              in
              check string "tier field" "essential" tier_val);
          test_case "full-tier tool has tier=full" `Quick (fun () ->
              let fields =
                Tool_catalog.metadata_to_fields "masc_risc_pipeline_status"
              in
              let tier_val =
                List.assoc_opt "tier" fields
                |> Option.map (function `String s -> s | _ -> "")
                |> Option.value ~default:""
              in
              check string "tier field" "full" tier_val);
          test_case "public contract keeps implementation status only" `Quick
            (fun () ->
              let fields = Tool_catalog.public_contract_fields "masc_join" in
              let status_val =
                List.assoc_opt "implementationStatus" fields
                |> Option.map (function `String s -> s | _ -> "")
                |> Option.value ~default:""
              in
              check string "status field" "real" status_val;
              check bool "visibility omitted" true
                (List.assoc_opt "visibility" fields = None);
              check bool "lifecycle omitted" true
                (List.assoc_opt "lifecycle" fields = None));
        ] );
      ( "placeholder_tools_enabled",
        [
          test_case "unset and blank values keep enabled default" `Quick
            (fun () ->
              check bool "unset defaults to enabled" true
                (Tool_catalog.placeholder_tools_enabled ());
              with_env "MASC_PLACEHOLDER_TOOLS_ENABLED" "" (fun () ->
                  check bool "blank defaults to enabled" true
                    (Tool_catalog.placeholder_tools_enabled ())));
          test_case "only exact false and 0 disable placeholder tools" `Quick
            (fun () ->
              List.iter
                (fun raw ->
                  with_env "MASC_PLACEHOLDER_TOOLS_ENABLED" raw (fun () ->
                      check bool raw false
                        (Tool_catalog.placeholder_tools_enabled ())))
                [ "false"; "0" ]);
          test_case "other spellings stay enabled for backward compatibility"
            `Quick (fun () ->
              List.iter
                (fun raw ->
                  with_env "MASC_PLACEHOLDER_TOOLS_ENABLED" raw (fun () ->
                      check bool raw true
                        (Tool_catalog.placeholder_tools_enabled ())))
                [ "FALSE"; " false "; "no"; "NO"; "true"; "1"; "bogus" ]);
        ] );
    ]
