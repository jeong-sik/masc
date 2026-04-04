(** Tests for Tool_catalog tier system — 2-tier tool filtering (Core / Extended) *)

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
      ( "core_tools",
        [
          test_case "contains expected core tools" `Quick (fun () ->
              let core =
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
                  check bool (name ^ " is core") true
                    (Tool_catalog.tool_tier name = Tool_catalog.Core))
                core);
          test_case "count is 25" `Quick (fun () ->
              check int "core count" 25
                (Tool_catalog.tier_tool_count Tool_catalog.Core));
        ] );
      ( "extended_tier",
        [
          test_case "is_in_tier Extended always returns true" `Quick (fun () ->
              check bool "arbitrary tool" true
                (Tool_catalog.is_in_tier Tool_catalog.Extended
                   "masc_some_unknown_tool_xyz");
              check bool "core tool" true
                (Tool_catalog.is_in_tier Tool_catalog.Extended "masc_join"));
          test_case "tier_tool_count returns -1 for Extended" `Quick (fun () ->
              check int "unknown count" (-1)
                (Tool_catalog.tier_tool_count Tool_catalog.Extended));
          test_case "includes board tools" `Quick (fun () ->
              check bool "masc_board_post" true
                (Tool_catalog.is_in_tier Tool_catalog.Extended "masc_board_post");
              check bool "masc_board_search" true
                (Tool_catalog.is_in_tier Tool_catalog.Extended
                   "masc_board_search"));
        ] );
      ( "tool_tier",
        [
          test_case "core tool returns Core" `Quick (fun () ->
              check string "tier" "core"
                (Tool_catalog.tier_to_string
                   (Tool_catalog.tool_tier "masc_join")));
          test_case "non-core tool returns Extended" `Quick (fun () ->
              check string "tier" "extended"
                (Tool_catalog.tier_to_string
                   (Tool_catalog.tool_tier "masc_board_post")));
        ] );
      ( "tier_of_string",
        [
          test_case "parses valid tier names" `Quick (fun () ->
              check bool "core" true
                (Tool_catalog.tier_of_string "core"
                = Some Tool_catalog.Core);
              check bool "extended" true
                (Tool_catalog.tier_of_string "extended"
                = Some Tool_catalog.Extended));
          test_case "backward compat aliases" `Quick (fun () ->
              check bool "essential -> Core" true
                (Tool_catalog.tier_of_string "essential"
                = Some Tool_catalog.Core);
              check bool "standard -> Extended" true
                (Tool_catalog.tier_of_string "standard"
                = Some Tool_catalog.Extended);
              check bool "full -> Extended" true
                (Tool_catalog.tier_of_string "full"
                = Some Tool_catalog.Extended));
          test_case "rejects invalid names" `Quick (fun () ->
              check bool "bogus" true
                (Tool_catalog.tier_of_string "bogus" = None);
              check bool "empty" true
                (Tool_catalog.tier_of_string "" = None));
        ] );
      ( "is_in_tier_filtering",
        [
          test_case "Core excludes non-core tools" `Quick (fun () ->
              check bool "board_post not core" false
                (Tool_catalog.is_in_tier Tool_catalog.Core
                   "masc_board_post"));
          test_case "Core subset property" `Quick (fun () ->
              let core_tools =
                [
                  "masc_join"; "masc_leave"; "masc_status"; "masc_add_task";
                  "masc_transition"; "masc_broadcast"; "masc_heartbeat";
                ]
              in
              List.iter
                (fun name ->
                  check bool (name ^ " also in extended") true
                    (Tool_catalog.is_in_tier Tool_catalog.Extended name))
                core_tools);
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
              check string "tier field" "core" tier_val);
          test_case "extended-tier tool has tier=extended" `Quick (fun () ->
              let fields =
                Tool_catalog.metadata_to_fields "masc_risc_pipeline_status"
              in
              let tier_val =
                List.assoc_opt "tier" fields
                |> Option.map (function `String s -> s | _ -> "")
                |> Option.value ~default:""
              in
              check string "tier field" "extended" tier_val);
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
