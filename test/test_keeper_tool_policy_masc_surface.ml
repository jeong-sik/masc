open Alcotest

let check_member label name expected names =
  check bool label expected (List.mem name names)

let test_board_registry_advertises_cleanup_tool () =
  let names = List.map (fun (schema : Masc_domain.tool_schema) -> schema.name) Board_tool_registry.tools in
  check_member "board cleanup advertised" "masc_board_cleanup" true names

let test_model_surface_exposes_direct_board_operations () =
  let names = Masc.Keeper_tool_policy.keeper_model_tool_names () in
  check_member "board cleanup is operator-only" "masc_board_cleanup" false names;
  check_member "board delete is model-visible" "masc_board_delete" true names

(* The keeper lane admits any name on the model surface and never reads
   [required_permission], so the projection is the only thing keeping a
   Worker-level Keeper away from an operator tool. Every model-visible tool
   the catalog classifies must therefore be one a Worker token could call over
   MCP. [masc_board_delete] is the one exception: its handler refuses anyone
   but the post's author. *)
let test_model_surface_stays_within_worker_permissions () =
  let names = Masc.Keeper_tool_policy.keeper_model_tool_names () in
  let handler_checks_the_author = [ "masc_board_delete" ] in
  let beyond_worker =
    Tool_catalog.explicit_metadata
    |> List.filter_map (fun (name, (meta : Tool_catalog.metadata)) ->
      if
        List.mem name names
        && (not (List.mem name handler_checks_the_author))
        && not (Masc_domain.has_permission Masc_domain.Worker meta.required_permission)
      then Some name
      else None)
    |> List.sort_uniq String.compare
  in
  check (list string) "model-visible tools a Worker token may not call" [] beyond_worker

let test_model_surface_exposes_working_capability_families () =
  let names = Masc.Keeper_tool_policy.keeper_model_tool_names () in
  List.iter
    (fun name -> check_member (name ^ " is model-visible") name true names)
    [ "Execute"
    ; "Grep"
    ; "Read"
    ; "Edit"
    ; "Write"
    ; "WebSearch"
    ; "WebFetch"
    ; "keeper_voice_speak"
    ; "keeper_voice_listen"
    ; "keeper_voice_agent"
    ; "keeper_voice_sessions"
    ; "keeper_voice_session_start"
    ; "keeper_voice_session_end"
    ; "masc_fusion"
    ]

let test_model_surface_exposes_delegation_not_keeper_administration () =
  let names = Masc.Keeper_tool_policy.keeper_model_tool_names () in
  List.iter
    (fun name -> check_member (name ^ " is model-visible") name true names)
    [ "masc_keeper_delegate"
    ; "masc_keeper_delegate_status"
    ; "masc_keeper_delegate_cancel"
    ];
  List.iter
    (fun name -> check_member (name ^ " is operator-only") name false names)
    [ "masc_keeper_waiting_inventory"
    ; "masc_keeper_list"
    ; "masc_keeper_delegate_list"
    ; "masc_keeper_clear"
    ; "masc_keeper_sandbox_start"
    ; "masc_keeper_sandbox_stop"
    ; "masc_keeper_reset"
    ; "masc_keeper_audit"
    ; "masc_keeper_status"
    ; "masc_keeper_down"
    ; "masc_keeper_up"
    ]

let () =
  Alcotest.run "keeper_tool_policy_masc_surface"
    [
      ( "model surface",
        [
          test_case "advertises board cleanup tool" `Quick
            test_board_registry_advertises_cleanup_tool;
          test_case
            "exposes direct Board operations"
            `Quick
            test_model_surface_exposes_direct_board_operations;
          test_case
            "stays within Worker permissions"
            `Quick
            test_model_surface_stays_within_worker_permissions;
          test_case
            "exposes code web media voice and Fusion"
            `Quick
            test_model_surface_exposes_working_capability_families;
          test_case
            "exposes delegation without Keeper administration"
            `Quick
            test_model_surface_exposes_delegation_not_keeper_administration;
        ] );
    ]
