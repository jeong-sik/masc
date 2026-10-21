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
   Worker-level Keeper away from an operator tool. Every descriptor the model
   can see, under any name, is judged by the catalog's effective metadata, so a
   tool the catalog has no entry for reads as operator-only and is reported
   here until the catalog classifies it. [masc_board_delete] is the one
   exception: its handler refuses anyone but the post's author. *)
let handler_checks_the_author = [ "masc_board_delete" ]

let model_tools_beyond_worker descriptors =
  let module Descriptor = Masc.Keeper_tool_descriptor in
  descriptors
  |> List.filter_map (fun (descriptor : Descriptor.t) ->
    let internal = descriptor.internal_name in
    match Descriptor.keeper_model_names descriptor with
    | [] -> None
    | _ :: _ ->
      let meta = Tool_catalog.metadata internal in
      if
        List.mem internal handler_checks_the_author
        || Masc_domain.has_permission Masc_domain.Worker meta.required_permission
      then None
      else Some internal)
  |> List.sort_uniq String.compare

let test_model_surface_stays_within_worker_permissions () =
  let module Descriptor = Masc.Keeper_tool_descriptor in
  check (list string) "model-visible tools a Worker token may not call" []
    (model_tools_beyond_worker (Descriptor.all_descriptors ()))

let test_model_tool_without_catalog_entry_is_beyond_worker () =
  let module Descriptor = Masc.Keeper_tool_descriptor in
  let uncatalogued = "keeper_tool_without_catalog_entry" in
  check bool "the control name has no catalog entry" true
    (Option.is_none (Tool_catalog.registered_metadata uncatalogued));
  match
    List.find_opt
      (fun (descriptor : Descriptor.t) ->
         Descriptor.keeper_model_names descriptor <> []
         && not (List.mem descriptor.internal_name handler_checks_the_author))
      (Descriptor.all_descriptors ())
  with
  | None -> fail "no model-visible descriptor to rename"
  | Some model_visible ->
    check (list string) "a model-visible tool the catalog does not classify"
      [ uncatalogued ]
      (model_tools_beyond_worker [ { model_visible with internal_name = uncatalogued } ])

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
            "reports a model-visible tool the catalog does not classify"
            `Quick
            test_model_tool_without_catalog_entry_is_beyond_worker;
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
