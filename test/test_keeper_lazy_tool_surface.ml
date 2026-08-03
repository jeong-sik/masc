open Masc

let surface () =
  match
    Keeper_agent_tool_surface.create_active_tool_surface
      ~registered_names:[ "list"; "search"; "read"; "write" ]
      ~initial_names:[ "list"; "search" ]
  with
  | Ok surface -> surface
  | Error _ -> Alcotest.fail "valid lazy surface was rejected"
;;

let test_initial_surface_is_exact () =
  Alcotest.(check (list string))
    "initial names"
    [ "list"; "search" ]
    (Keeper_agent_tool_surface.active_names (surface ()))
;;

let test_actual_catalog_starts_with_discovery_only () =
  let descriptors = Keeper_tool_descriptor.model_visible_descriptors () in
  let registered_names =
    List.concat_map Keeper_tool_descriptor.keeper_model_names descriptors
  in
  let initial_names = Keeper_run_tools_setup.initial_model_tool_names descriptors in
  Alcotest.(check (list string))
    "initial discovery names"
    [ "keeper_tools_list"; "keeper_tool_search" ]
    initial_names;
  Alcotest.(check bool)
    "registered catalog remains larger than provider surface"
    true
    (List.length registered_names > List.length initial_names)
;;

let test_activation_preserves_registration_order () =
  let surface = surface () in
  (match Keeper_agent_tool_surface.activate_exact surface ~names:[ "write"; "read" ] with
   | Ok () -> ()
   | Error _ -> Alcotest.fail "registered activation was rejected");
  Alcotest.(check (list string))
    "canonical order"
    [ "list"; "search"; "read"; "write" ]
    (Keeper_agent_tool_surface.active_names surface)
;;

let test_unknown_activation_fails_without_mutation () =
  let surface = surface () in
  (match Keeper_agent_tool_surface.activate_exact surface ~names:[ "missing" ] with
   | Error (Keeper_agent_tool_surface.Unknown_activation_name "missing") -> ()
   | Error _ -> Alcotest.fail "wrong typed activation error"
   | Ok () -> Alcotest.fail "unknown activation was accepted");
  Alcotest.(check (list string))
    "unchanged"
    [ "list"; "search" ]
    (Keeper_agent_tool_surface.active_names surface)
;;

let test_invalid_initial_surfaces_fail_closed () =
  (match
     Keeper_agent_tool_surface.create_active_tool_surface
       ~registered_names:[ "search"; "search" ]
       ~initial_names:[ "search" ]
   with
   | Error (Keeper_agent_tool_surface.Duplicate_registered_name "search") -> ()
   | Error _ -> Alcotest.fail "wrong duplicate registration error"
   | Ok _ -> Alcotest.fail "duplicate registration was accepted");
  match
    Keeper_agent_tool_surface.create_active_tool_surface
      ~registered_names:[ "search" ]
      ~initial_names:[ "missing" ]
  with
  | Error (Keeper_agent_tool_surface.Unknown_initial_name "missing") -> ()
  | Error _ -> Alcotest.fail "wrong unknown initial error"
  | Ok _ -> Alcotest.fail "unknown initial name was accepted"
;;

let schema name description : Masc_domain.tool_schema =
  { name; description; input_schema = `Assoc [ "type", `String "object" ] }
;;

let test_only_exact_name_is_activation_capable () =
  let schemas = [ schema "keeper_read_file" "Read a file" ] in
  (match
     Keeper_tool_registry.search_tool_schemas
       ~query:"read file"
       ~max_results:5
       schemas
   with
   | Keeper_tool_registry.Advisory_candidates [ ranked ] ->
     Alcotest.(check string) "candidate" "keeper_read_file" ranked.schema.name
  | Keeper_tool_registry.Advisory_candidates _ ->
    Alcotest.fail "expected one advisory candidate"
  | Keeper_tool_registry.Exact_name _ ->
    Alcotest.fail "free text became activation authority");
  (match
     Keeper_tool_registry.search_tool_schemas
       ~query:" keeper_read_file "
       ~max_results:5
       schemas
   with
   | Keeper_tool_registry.Advisory_candidates _ -> ()
   | Keeper_tool_registry.Exact_name _ ->
     Alcotest.fail "whitespace-normalized name became activation authority");
  match
    Keeper_tool_registry.search_tool_schemas
      ~query:"keeper_read_file"
      ~max_results:5
      schemas
  with
  | Keeper_tool_registry.Exact_name ranked ->
    Alcotest.(check string) "exact" "keeper_read_file" ranked.schema.name
  | Keeper_tool_registry.Advisory_candidates _ ->
    Alcotest.fail "exact name did not produce exact activation"
;;

let () =
  Alcotest.run
    "keeper lazy tool surface"
    [ ( "activation"
      , [ Alcotest.test_case "initial exact" `Quick test_initial_surface_is_exact
        ; Alcotest.test_case
            "actual catalog starts with discovery only"
            `Quick
            test_actual_catalog_starts_with_discovery_only
        ; Alcotest.test_case
            "canonical activation order"
            `Quick
            test_activation_preserves_registration_order
        ; Alcotest.test_case
            "unknown activation is atomic"
            `Quick
            test_unknown_activation_fails_without_mutation
        ; Alcotest.test_case
            "invalid initial surfaces"
            `Quick
            test_invalid_initial_surfaces_fail_closed
        ; Alcotest.test_case
            "only exact names activate"
            `Quick
            test_only_exact_name_is_activation_capable
        ] )
    ]
;;
