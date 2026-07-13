(** RFC-0057 Phase 2 regression test.

    Guards [bin/gen_tool_descriptors.ml] output against the
    effective schema exposed by [Tool_schemas_misc] for generated
    misc/infra tools such as [masc_config] and [masc_tool_help].

    Phase 2 lifted spec types into [lib/tool_schemas_specs/] and added
    additional generated tools. Hand-written entries for these tools
    were removed from [Tool_schemas_misc]; generated schemas are the
    SSOT. The test pins generated vs effective field-for-field. *)

open Masc_domain

module Descriptor = Masc.Keeper_tool_descriptor

let yojson_testable : Yojson.Safe.t Alcotest.testable =
  Alcotest.testable
    (fun fmt v -> Format.fprintf fmt "%s" (Yojson.Safe.pretty_to_string v))
    Yojson.Safe.equal
;;

let find_by_name name (schemas : tool_schema list) : tool_schema =
  match List.find_opt (fun s -> String.equal s.name name) schemas with
  | Some s -> s
  | None ->
    Alcotest.failf
      "tool %S not in schemas (have: %s)"
      name
      (String.concat ", " (List.map (fun s -> s.name) schemas))
;;

let has_schema name schemas =
  List.exists (fun (s : tool_schema) -> String.equal s.name name) schemas
;;

let descriptor_internal_schema name : tool_schema =
  match
    List.find_opt
      (fun (descriptor : Descriptor.t) -> String.equal descriptor.internal_name name)
      Descriptor.public_descriptors
  with
  | Some descriptor ->
    { name = descriptor.internal_name
    ; description = descriptor.description
    ; input_schema = descriptor.input_schema
    }
  | None -> Alcotest.failf "descriptor %S not in Keeper_tool_descriptor.public_descriptors" name
;;

let test_masc_config_name_matches () =
  let gen = find_by_name "masc_config" Tool_descriptors_gen.schemas in
  let hand = find_by_name "masc_config" Tool_schemas_misc.schemas in
  Alcotest.(check string) "masc_config name" hand.name gen.name
;;

let test_masc_config_description_matches () =
  let gen = find_by_name "masc_config" Tool_descriptors_gen.schemas in
  let hand = find_by_name "masc_config" Tool_schemas_misc.schemas in
  Alcotest.(check string) "masc_config description" hand.description gen.description
;;

let test_masc_config_input_schema_matches () =
  let gen = find_by_name "masc_config" Tool_descriptors_gen.schemas in
  let hand = find_by_name "masc_config" Tool_schemas_misc.schemas in
  Alcotest.check
    yojson_testable
    "masc_config input_schema (Yojson.Safe.equal)"
    hand.input_schema
    gen.input_schema
;;

let test_masc_spawn_is_not_generated () =
  Alcotest.(check bool)
    "masc_spawn absent from generated schemas"
    false
    (has_schema "masc_spawn" Tool_descriptors_gen.schemas);
  Alcotest.(check bool)
    "masc_spawn absent from effective misc schemas"
    false
    (has_schema "masc_spawn" Tool_schemas_misc.schemas)
;;

let test_control_schemas_use_dedicated_typed_projection () =
  let properties schema =
    match schema.input_schema with
    | `Assoc fields ->
      (match List.assoc_opt "properties" fields with
       | Some (`Assoc properties) -> properties
       | _ -> Alcotest.failf "%s has no object properties" schema.name)
    | _ -> Alcotest.failf "%s has a non-object schema" schema.name
  in
  let pause = Tool_schemas_misc.control_schema Tool_schemas_misc.Pause in
  let resume = Tool_schemas_misc.control_schema Tool_schemas_misc.Resume in
  Alcotest.check
    yojson_testable
    "pause projection keeps generated canonical schema"
    Tool_descriptors_gen.masc_pause_schema.input_schema
    pause.input_schema;
  Alcotest.check
    yojson_testable
    "resume projection keeps generated canonical schema"
    Tool_descriptors_gen.masc_resume_schema.input_schema
    resume.input_schema;
  Alcotest.(check (list string))
    "typed control projection is exhaustive"
    [ "masc_pause"; "masc_resume" ]
    (List.map
       (fun operation ->
          (Tool_schemas_misc.control_schema operation).name)
       Tool_schemas_misc.control_operations);
  List.iter
    (fun name ->
       Alcotest.(check bool)
         (name ^ " absent from generated public misc schemas")
         false
         (has_schema name Tool_descriptors_gen.schemas);
       Alcotest.(check bool)
         (name ^ " absent from effective public misc schemas")
         false
         (has_schema name Tool_schemas_misc.schemas))
    [ "masc_pause"; "masc_resume" ];
  Alcotest.(check bool)
    "masc_pause has reason property"
    true
    (List.mem_assoc "reason" (properties pause));
  Alcotest.(check int)
    "masc_resume has no input properties"
    0
    (List.length (properties resume))
;;

let test_masc_tool_help_name_matches () =
  let gen = find_by_name "masc_tool_help" Tool_descriptors_gen.schemas in
  let hand = find_by_name "masc_tool_help" Tool_schemas_misc.schemas in
  Alcotest.(check string) "masc_tool_help name" hand.name gen.name
;;

let test_masc_tool_help_description_matches () =
  let gen = find_by_name "masc_tool_help" Tool_descriptors_gen.schemas in
  let hand = find_by_name "masc_tool_help" Tool_schemas_misc.schemas in
  Alcotest.(check string) "masc_tool_help description" hand.description gen.description
;;

let test_masc_tool_help_input_schema_matches () =
  let gen = find_by_name "masc_tool_help" Tool_descriptors_gen.schemas in
  let hand = find_by_name "masc_tool_help" Tool_schemas_misc.schemas in
  Alcotest.check
    yojson_testable
    "masc_tool_help input_schema (Yojson.Safe.equal)"
    hand.input_schema
    gen.input_schema
;;

let test_masc_dashboard_name_matches () =
  let gen = find_by_name "masc_dashboard" Tool_descriptors_gen.schemas in
  let hand = find_by_name "masc_dashboard" Tool_schemas_misc.schemas in
  Alcotest.(check string) "masc_dashboard name" hand.name gen.name
;;

let test_masc_dashboard_description_matches () =
  let gen = find_by_name "masc_dashboard" Tool_descriptors_gen.schemas in
  let hand = find_by_name "masc_dashboard" Tool_schemas_misc.schemas in
  Alcotest.(check string) "masc_dashboard description" hand.description gen.description
;;

let test_masc_dashboard_input_schema_matches () =
  let gen = find_by_name "masc_dashboard" Tool_descriptors_gen.schemas in
  let hand = find_by_name "masc_dashboard" Tool_schemas_misc.schemas in
  Alcotest.check
    yojson_testable
    "masc_dashboard input_schema (Yojson.Safe.equal)"
    hand.input_schema
    gen.input_schema
;;

let test_masc_keeper_waiting_inventory_name_matches () =
  let gen =
    find_by_name "masc_keeper_waiting_inventory" Tool_descriptors_gen.schemas
  in
  let hand =
    find_by_name "masc_keeper_waiting_inventory" Tool_schemas_misc.schemas
  in
  Alcotest.(check string) "masc_keeper_waiting_inventory name" hand.name gen.name
;;

let test_masc_keeper_waiting_inventory_description_matches () =
  let gen =
    find_by_name "masc_keeper_waiting_inventory" Tool_descriptors_gen.schemas
  in
  let hand =
    find_by_name "masc_keeper_waiting_inventory" Tool_schemas_misc.schemas
  in
  Alcotest.(check string)
    "masc_keeper_waiting_inventory description"
    hand.description
    gen.description
;;

let test_masc_keeper_waiting_inventory_input_schema_matches () =
  let gen =
    find_by_name "masc_keeper_waiting_inventory" Tool_descriptors_gen.schemas
  in
  let hand =
    find_by_name "masc_keeper_waiting_inventory" Tool_schemas_misc.schemas
  in
  Alcotest.check
    yojson_testable
    "masc_keeper_waiting_inventory input_schema (Yojson.Safe.equal)"
    hand.input_schema
    gen.input_schema
;;

let test_masc_gc_name_matches () =
  let gen = find_by_name "masc_gc" Tool_descriptors_gen.schemas in
  let hand = find_by_name "masc_gc" Tool_schemas_misc.schemas in
  Alcotest.(check string) "masc_gc name" hand.name gen.name
;;

let test_masc_gc_description_matches () =
  let gen = find_by_name "masc_gc" Tool_descriptors_gen.schemas in
  let hand = find_by_name "masc_gc" Tool_schemas_misc.schemas in
  Alcotest.(check string) "masc_gc description" hand.description gen.description
;;

let test_masc_gc_input_schema_matches () =
  let gen = find_by_name "masc_gc" Tool_descriptors_gen.schemas in
  let hand = find_by_name "masc_gc" Tool_schemas_misc.schemas in
  Alcotest.check
    yojson_testable
    "masc_gc input_schema (Yojson.Safe.equal)"
    hand.input_schema
    gen.input_schema
;;

let descriptor_internal_schema name : tool_schema =
  match
    Masc.Keeper_tool_descriptor.public_descriptors
    |> List.find_opt (fun (descriptor : Masc.Keeper_tool_descriptor.t) ->
           String.equal descriptor.internal_name name)
  with
  | Some descriptor ->
      { name = descriptor.internal_name
      ; description = descriptor.description
      ; input_schema = descriptor.input_schema
      }
  | None -> Alcotest.failf "descriptor for internal tool %S not found" name
;;

(* Regression guard for PR #19864 -> keeper web alias pruning spam.
   Web tools are descriptor-backed keeper tools: they MUST be
   present in the raw substrate inventory, but their schema owner is
   [Keeper_tool_descriptor.public_descriptors], not [Tool_descriptors_gen]. *)
let test_web_tools_owned_by_keeper_descriptors () =
  List.iter
    (fun name ->
      let descriptor = descriptor_internal_schema name in
      Alcotest.(check bool)
        (name ^ " absent from Tool_descriptors_gen.schemas")
        false
        (has_schema name Tool_descriptors_gen.schemas);
      Alcotest.(check bool)
        (name ^ " absent from Tool_schemas_misc.schemas")
        false
        (has_schema name Tool_schemas_misc.schemas);
      let raw = find_by_name name Masc.Config.raw_all_tool_schemas in
      Alcotest.(check string)
        (name ^ " raw description matches descriptor")
        descriptor.description
        raw.description;
      Alcotest.check
        yojson_testable
        (name ^ " raw input_schema matches descriptor")
        descriptor.input_schema
        raw.input_schema;
      Alcotest.(check bool)
        (name ^ " present in Config.raw_all_tool_schemas")
        true
        (has_schema name Masc.Config.raw_all_tool_schemas);
      Alcotest.(check bool)
        (name ^ " present in Config.raw_tool_name_set")
        true
        (Masc.Config.is_raw_tool_name name);
      Alcotest.(check bool)
        (name ^ " absent from public_mcp_surface_tools")
        false
        (List.mem name Tool_catalog_surfaces.public_mcp_surface_tools))
    [ "masc_web_search"; "masc_web_fetch" ]
;;

let test_web_backends_are_in_complete_model_surface () =
  let prior = Masc.Keeper_tool_dispatch_runtime.masc_schemas_snapshot () in
  Fun.protect
    ~finally:(fun () -> Masc.Keeper_tool_dispatch_runtime.set_masc_schemas prior)
    (fun () ->
      (* Simulate startup: lib/mcp_server_eio.ml feeds exactly this substrate. *)
      Masc.Keeper_tool_dispatch_runtime.inject_masc_schemas
        Masc.Config.raw_all_tool_schemas;
      let injected =
        Masc.Keeper_tool_dispatch_runtime.injected_masc_tool_names ()
      in
      List.iter
        (fun name ->
          Alcotest.(check bool)
            (name ^ " injected from raw_all_tool_schemas substrate")
            true
            (List.mem name injected))
        [ "masc_web_search"; "masc_web_fetch" ];
      let model_names = Masc.Keeper_tool_dispatch_runtime.keeper_model_tool_names () in
      List.iter
        (fun public_name ->
          Alcotest.(check bool)
            (public_name ^ " present in complete model surface")
            true
            (List.mem public_name model_names))
        [ "WebSearch"; "WebFetch" ])
;;

let test_masc_tool_stats_name_matches () =
  let gen = find_by_name "masc_tool_stats" Tool_descriptors_gen.schemas in
  let hand = find_by_name "masc_tool_stats" Tool_schemas_misc.schemas in
  Alcotest.(check string) "masc_tool_stats name" hand.name gen.name
;;

let test_masc_tool_stats_description_matches () =
  let gen = find_by_name "masc_tool_stats" Tool_descriptors_gen.schemas in
  let hand = find_by_name "masc_tool_stats" Tool_schemas_misc.schemas in
  Alcotest.(check string) "masc_tool_stats description" hand.description gen.description
;;

let test_masc_tool_stats_input_schema_matches () =
  let gen = find_by_name "masc_tool_stats" Tool_descriptors_gen.schemas in
  let hand = find_by_name "masc_tool_stats" Tool_schemas_misc.schemas in
  Alcotest.check
    yojson_testable
    "masc_tool_stats input_schema (Yojson.Safe.equal)"
    hand.input_schema
    gen.input_schema
;;

let test_masc_cleanup_zombies_name_matches () =
  let gen = find_by_name "masc_cleanup_zombies" Tool_descriptors_gen.schemas in
  let hand = find_by_name "masc_cleanup_zombies" Tool_schemas_misc.schemas in
  Alcotest.(check string) "masc_cleanup_zombies name" hand.name gen.name
;;

let test_masc_cleanup_zombies_description_matches () =
  let gen = find_by_name "masc_cleanup_zombies" Tool_descriptors_gen.schemas in
  let hand = find_by_name "masc_cleanup_zombies" Tool_schemas_misc.schemas in
  Alcotest.(check string)
    "masc_cleanup_zombies description"
    hand.description
    gen.description
;;

let test_masc_cleanup_zombies_input_schema_matches () =
  let gen = find_by_name "masc_cleanup_zombies" Tool_descriptors_gen.schemas in
  let hand = find_by_name "masc_cleanup_zombies" Tool_schemas_misc.schemas in
  Alcotest.check
    yojson_testable
    "masc_cleanup_zombies input_schema (Yojson.Safe.equal)"
    hand.input_schema
    gen.input_schema
;;

let () =
  Alcotest.run
    "tool_descriptors_gen"
    [ ( "masc_config field-by-field"
      , [ Alcotest.test_case "name" `Quick test_masc_config_name_matches
        ; Alcotest.test_case "description" `Quick test_masc_config_description_matches
        ; Alcotest.test_case "input_schema" `Quick test_masc_config_input_schema_matches
        ] )
    ; ( "retired tool exclusion"
      , [ Alcotest.test_case "masc_spawn removed" `Quick test_masc_spawn_is_not_generated
        ] )
    ; ( "control schema SSOT"
      , [ Alcotest.test_case
            "pause and resume use a dedicated typed projection"
            `Quick
            test_control_schemas_use_dedicated_typed_projection
        ] )
    ; ( "masc_tool_help field-by-field"
      , [ Alcotest.test_case "name" `Quick test_masc_tool_help_name_matches
        ; Alcotest.test_case "description" `Quick test_masc_tool_help_description_matches
        ; Alcotest.test_case
            "input_schema"
            `Quick
            test_masc_tool_help_input_schema_matches
        ] )
    ; ( "masc_dashboard field-by-field"
      , [ Alcotest.test_case "name" `Quick test_masc_dashboard_name_matches
        ; Alcotest.test_case "description" `Quick test_masc_dashboard_description_matches
        ; Alcotest.test_case
            "input_schema"
            `Quick
            test_masc_dashboard_input_schema_matches
        ] )
    ; ( "masc_keeper_waiting_inventory field-by-field"
      , [ Alcotest.test_case
            "name"
            `Quick
            test_masc_keeper_waiting_inventory_name_matches
        ; Alcotest.test_case
            "description"
            `Quick
            test_masc_keeper_waiting_inventory_description_matches
        ; Alcotest.test_case
            "input_schema"
            `Quick
            test_masc_keeper_waiting_inventory_input_schema_matches
        ] )
    ; ( "masc_gc field-by-field"
      , [ Alcotest.test_case "name" `Quick test_masc_gc_name_matches
        ; Alcotest.test_case "description" `Quick test_masc_gc_description_matches
        ; Alcotest.test_case "input_schema" `Quick test_masc_gc_input_schema_matches
        ] )
    ; ( "descriptor-backed web tools"
      , [ Alcotest.test_case
            "owned by keeper descriptors"
            `Quick
            test_web_tools_owned_by_keeper_descriptors
        ; Alcotest.test_case
            "remain in complete model surface after substrate injection"
            `Quick
            test_web_backends_are_in_complete_model_surface
        ] )
    ; ( "masc_tool_stats field-by-field"
      , [ Alcotest.test_case "name" `Quick test_masc_tool_stats_name_matches
        ; Alcotest.test_case "description" `Quick test_masc_tool_stats_description_matches
        ; Alcotest.test_case
            "input_schema"
            `Quick
            test_masc_tool_stats_input_schema_matches
        ] )
    ; ( "masc_cleanup_zombies field-by-field"
      , [ Alcotest.test_case "name" `Quick test_masc_cleanup_zombies_name_matches
        ; Alcotest.test_case
            "description"
            `Quick
            test_masc_cleanup_zombies_description_matches
        ; Alcotest.test_case
            "input_schema"
            `Quick
            test_masc_cleanup_zombies_input_schema_matches
        ] )
    ]
;;
