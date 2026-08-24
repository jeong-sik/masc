open Alcotest

module Catalog = Masc.Keeper_tool_composition_catalog
module Plan = Masc.Keeper_tool_plan

let valid_catalog =
  {|[[compositions]]
name = "time-memory-query"
description = "Feed the exact clock result into memory search."
execution = "inline"

[[compositions.nodes]]
id = "time"
tool = "keeper_time_now"
[compositions.nodes.input]
kind = "literal"
value = {}

[[compositions.nodes]]
id = "search"
tool = "keeper_memory_search"
after = ["time"]
[compositions.nodes.input]
kind = "object"
[[compositions.nodes.input.fields]]
name = "query"
[compositions.nodes.input.fields.value]
kind = "output"
node = "time"
pointer = "/now_iso"
|}
;;

let node_id value =
  match Plan.Node_id.make value with
  | Ok id -> id
  | Error Plan.Node_id.Empty -> fail "unexpected empty node id"
;;

let test_catalog_builds_executable_typed_plan () =
  let catalog =
    match Catalog.parse valid_catalog with
    | Ok catalog -> catalog
    | Error _ -> fail "valid composition catalog was rejected"
  in
  check int "one catalog entry" 1 (List.length (Catalog.entries catalog));
  let entry =
    match Catalog.find catalog "time-memory-query" with
    | Some entry -> entry
    | None -> fail "composition lookup missed exact name"
  in
  check
    (option string)
    "description"
    (Some "Feed the exact clock result into memory search.")
    entry.description;
  let layers = Plan.dependency_layers entry.plan in
  check
    (list (list string))
    "typed dependency layers"
    [ [ "time" ]; [ "search" ] ]
    (List.map
       (List.map (fun node -> Plan.Node_id.to_string node.Plan.id))
       layers);
  let run_id = Plan.Run_id.fresh () in
  let time_output =
    match
      Plan.validate_output
        entry.plan
        ~run_id
        ~node_id:(node_id "time")
        (`Assoc
            [ "now_iso", `String "2026-08-14T00:00:00Z"
            ; "now_unix", `Float 0.0
            ])
    with
    | Ok output -> output
    | Error _ -> fail "valid clock output was rejected"
  in
  match
    Plan.resolve_input
      entry.plan
      ~run_id
      ~node_id:(node_id "search")
      ~lookup:(fun id ->
        if Plan.Node_id.equal id (node_id "time") then Some time_output else None)
  with
  | Ok (`Assoc [ ("query", `String "2026-08-14T00:00:00Z") ]) -> ()
  | Ok value ->
    failf "resolved catalog input changed shape: %s" (Yojson.Safe.to_string value)
  | Error _ -> fail "catalog output reference did not resolve"
;;

let test_catalog_rejects_unknown_fields () =
  let document =
    {|[[compositions]]
name = "bad"
execution = "inline"
guess = true
[[compositions.nodes]]
id = "time"
tool = "keeper_time_now"
input = { kind = "literal", value = {} }
|}
  in
  match Catalog.parse document with
  | Error
      (Catalog.Unknown_field
        { path = [ "compositions"; "0" ]; field = "guess" }) -> ()
  | Error _ | Ok _ -> fail "unknown composition field was not rejected"
;;

let test_catalog_rejects_malformed_output_pointer () =
  let document =
    {|[[compositions]]
name = "bad-pointer"
execution = "inline"
[[compositions.nodes]]
id = "time"
tool = "keeper_time_now"
[compositions.nodes.input]
kind = "literal"
value = {}
[[compositions.nodes]]
id = "search"
tool = "keeper_memory_search"
[compositions.nodes.input]
kind = "object"
[[compositions.nodes.input.fields]]
name = "query"
[compositions.nodes.input.fields.value]
kind = "output"
node = "time"
pointer = "now_iso"
|}
  in
  match Catalog.parse document with
  | Error
      (Catalog.Invalid_json_pointer
        { error = Plan.Json_pointer.Missing_initial_slash; _ }) -> ()
  | Error _ | Ok _ -> fail "non-RFC6901 output pointer was accepted"
;;

let one_node_composition name =
  Printf.sprintf
    {|[[compositions]]
name = %S
execution = "inline"
[[compositions.nodes]]
id = "time"
tool = "keeper_time_now"
[compositions.nodes.input]
kind = "literal"
value = {}
|}
    name
;;

let one_node_async_composition name =
  Printf.sprintf
    {|[[compositions]]
name = %S
execution = "async"
[[compositions.nodes]]
id = "time"
tool = "keeper_time_now"
[compositions.nodes.input]
kind = "literal"
value = {}
|}
    name
;;

let test_catalog_requires_explicit_execution_mode () =
  let document =
    {|[[compositions]]
name = "missing-execution"
[[compositions.nodes]]
id = "time"
tool = "keeper_time_now"
[compositions.nodes.input]
kind = "literal"
value = {}
|}
  in
  match Catalog.parse document with
  | Error
      (Catalog.Missing_field
        { path = [ "compositions"; "0" ]; field = "execution" }) ->
    ()
  | Error _ | Ok _ -> fail "composition execution mode was inferred"
;;

let test_catalog_accepts_async_only_for_statically_read_only_tools () =
  let catalog =
    match Catalog.parse (one_node_async_composition "clock-background") with
    | Ok catalog -> catalog
    | Error error -> fail (Catalog.error_to_string error)
  in
  let entry =
    match Catalog.find catalog "clock-background" with
    | Some entry -> entry
    | None -> fail "async composition lookup failed"
  in
  (match entry.execution with
   | Catalog.Async -> ()
   | Catalog.Inline -> fail "async execution mode was rewritten");
  check
    (list string)
    "async model surface includes exact controls"
    [ "keeper_compose_clock-background"
    ; "keeper_composition_status"
    ; "keeper_composition_cancel"
    ]
    (Catalog.model_tool_names catalog)
;;

let test_catalog_rejects_async_effectful_tool () =
  let document =
    {|[[compositions]]
name = "write-background"
execution = "async"
[[compositions.nodes]]
id = "write"
tool = "keeper_memory_write"
[compositions.nodes.input]
kind = "literal"
value = { title = "not admitted", content = "effectful async" }
|}
  in
  match Catalog.parse document with
  | Error
      (Catalog.Async_tool_not_statically_read_only
        { name = "write-background"; node_id; tool_name = "keeper_memory_write" }) ->
    check string "rejected node" "write" (Plan.Node_id.to_string node_id)
  | Error _ | Ok _ -> fail "effectful async composition was admitted"
;;

let test_catalog_projects_stable_tool_name_and_path () =
  let catalog =
    match Catalog.parse (one_node_composition "clock-check") with
    | Ok catalog -> catalog
    | Error _ -> fail "valid named composition was rejected"
  in
  let entry =
    match Catalog.find catalog "clock-check" with
    | Some entry -> entry
    | None -> fail "named composition lookup failed"
  in
  check string "model-visible tool name" "keeper_compose_clock-check"
    (Catalog.tool_name entry);
  check string "resolved catalog path" "config/tool-compositions.toml"
    (Catalog.path ~config_root:"config")
;;

let test_catalog_rejects_name_outside_tool_alphabet () =
  match Catalog.parse (one_node_composition "clock check") with
  | Error
      (Catalog.Invalid_composition_name_character
        { name = "clock check"; character = ' ' }) -> ()
  | Error _ | Ok _ -> fail "composition name outside the tool alphabet was accepted"
;;

let test_catalog_rejects_name_beyond_provider_limit () =
  let name = String.make 50 'a' in
  match Catalog.parse (one_node_composition name) with
  | Error
      (Catalog.Composition_name_too_long
        { name = actual; maximum_bytes = 49 }) ->
    check string "rejected exact name" name actual
  | Error _ | Ok _ -> fail "composition name beyond provider limit was accepted"
;;

let test_catalog_rejects_duplicate_composition_names () =
  let document = one_node_composition "same" ^ one_node_composition "same" in
  match Catalog.parse document with
  | Error (Catalog.Duplicate_composition_name "same") -> ()
  | Error _ | Ok _ -> fail "duplicate composition name was accepted"
;;

let test_catalog_rejects_unknown_tool_through_plan_authority () =
  let document =
    {|[[compositions]]
name = "unknown-tool"
execution = "inline"
[[compositions.nodes]]
id = "unknown"
tool = "invented_tool"
[compositions.nodes.input]
kind = "literal"
value = {}
|}
  in
  match Catalog.parse document with
  | Error
      (Catalog.Plan_rejected
        { error = Plan.Unknown_tool { tool_name = "invented_tool"; _ }; _ }) -> ()
  | Error _ | Ok _ -> fail "catalog bypassed canonical plan tool authority"
;;

let test_catalog_loader_distinguishes_missing_valid_and_invalid () =
  let config_root = Filename.temp_file "keeper-composition-loader" "" in
  Unix.unlink config_root;
  Unix.mkdir config_root 0o755;
  let catalog_path = Catalog.path ~config_root in
  Fun.protect
    ~finally:(fun () ->
      if Sys.file_exists catalog_path then Unix.unlink catalog_path;
      Unix.rmdir config_root)
    (fun () ->
       (match Masc.Keeper_run_tools_setup.load_composition_catalog ~config_root with
        | Ok None -> ()
        | Ok (Some _) | Error _ -> fail "missing catalog did not remain optional");
       let write content =
         let channel = open_out_bin catalog_path in
         Fun.protect
           ~finally:(fun () -> close_out channel)
           (fun () -> output_string channel content)
       in
       write (one_node_composition "loaded");
       (match Masc.Keeper_run_tools_setup.load_composition_catalog ~config_root with
        | Ok (Some catalog) ->
          check bool "valid catalog loaded" true (Option.is_some (Catalog.find catalog "loaded"))
        | Ok None | Error _ -> fail "existing valid catalog was not loaded");
       write "[[compositions]]\nname = \"broken\"\n";
       match Masc.Keeper_run_tools_setup.load_composition_catalog ~config_root with
       | Error
           (Agent_core.Error.Config
             (Agent_core.Error.InvalidConfig
               { field = "tool-compositions.toml"; detail })) ->
         check bool
           "parse detail remains visible"
           true
           (String.length detail > 0)
       | Ok _ | Error _ -> fail "invalid catalog did not return typed config error")
;;

let test_catalog_tools_join_runtime_projection_authority () =
  let catalog =
    match Catalog.parse (one_node_composition "projected") with
    | Ok catalog -> catalog
    | Error _ -> fail "valid projection catalog was rejected"
  in
  let descriptors = Masc.Keeper_tool_descriptor.model_visible_descriptors () in
  let descriptor_names =
    descriptors
    |> List.concat_map Masc.Keeper_tool_descriptor.keeper_model_names
    |> List.sort_uniq String.compare
  in
  let expected =
    Masc.Keeper_run_tools_setup.expected_model_tool_names
      ~skill_catalog:Masc.Keeper_skill_catalog.empty
      ~model_visible_descriptors:descriptors
      ~composition_catalog:(Some catalog)
  in
  check bool
    "dynamic composition joins descriptor projection"
    true
    (List.mem "keeper_compose_projected" expected);
  check bool
    "model-defined plan tool always joins the projection"
    true
    (List.mem
       Masc.Keeper_tool_composition_surface.plan_execute_tool_name
       expected);
  (* One catalog tool plus the always-present keeper_plan_execute. *)
  check int
    "projection adds the catalog tool and the plan tool"
    (List.length descriptor_names + 2)
    (List.length expected)
;;

let () =
  run
    "keeper_tool_composition_catalog"
    [ ( "catalog"
      , [ test_case
            "builds executable typed plan"
            `Quick
            test_catalog_builds_executable_typed_plan
        ; test_case "rejects unknown fields" `Quick test_catalog_rejects_unknown_fields
        ; test_case
            "rejects malformed pointer"
            `Quick
            test_catalog_rejects_malformed_output_pointer
        ; test_case
            "rejects duplicate names"
            `Quick
            test_catalog_rejects_duplicate_composition_names
        ; test_case
            "requires explicit execution mode"
            `Quick
            test_catalog_requires_explicit_execution_mode
        ; test_case
            "accepts async statically read-only plan"
            `Quick
            test_catalog_accepts_async_only_for_statically_read_only_tools
        ; test_case
            "rejects async effectful tool"
            `Quick
            test_catalog_rejects_async_effectful_tool
        ; test_case
            "projects stable tool name and path"
            `Quick
            test_catalog_projects_stable_tool_name_and_path
        ; test_case
            "rejects unsupported name characters"
            `Quick
            test_catalog_rejects_name_outside_tool_alphabet
        ; test_case
            "rejects name beyond provider limit"
            `Quick
            test_catalog_rejects_name_beyond_provider_limit
        ; test_case
            "rejects unknown tools"
            `Quick
            test_catalog_rejects_unknown_tool_through_plan_authority
        ; test_case
            "loader distinguishes missing valid and invalid"
            `Quick
            test_catalog_loader_distinguishes_missing_valid_and_invalid
        ; test_case
            "catalog tools join runtime projection authority"
            `Quick
            test_catalog_tools_join_runtime_projection_authority
        ] )
    ]
;;
