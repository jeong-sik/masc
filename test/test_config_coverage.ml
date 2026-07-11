(** Config Module Coverage Tests

    Tests for the schema registry helpers that remain after mode removal.
*)

open Alcotest

module Config = Masc.Config
module Auth = Masc.Auth
module Tool_catalog = Tool_catalog
module Tool_help_registry = Tool_help_registry
module Tool_shard = Masc.Tool_shard
module Types = Masc_domain

let dummy_schema name : Masc_domain.tool_schema =
  {
    name;
    description = "dummy";
    input_schema =
      `Assoc
        [
          ("type", `String "object");
          ("properties", `Assoc []);
        ];
  }

let test_dedupe_schemas () =
  let deduped =
    Config.dedupe_schemas
      [ dummy_schema "alpha"; dummy_schema "alpha"; dummy_schema "beta" ]
  in
  check int "deduped length" 2 (List.length deduped)

let test_raw_all_tool_schemas_non_empty () =
  check bool "raw schemas exist" true (List.length Config.raw_all_tool_schemas > 0)

let test_all_tool_schemas_non_empty () =
  check bool "public schemas exist" true (List.length Config.all_tool_schemas > 0)

let test_control_tools_keep_raw_schema_but_leave_public_projection () =
  let raw_names =
    List.map
      (fun (schema : Masc_domain.tool_schema) -> schema.name)
      Config.raw_all_tool_schemas
  in
  let public_names = Config.all_tool_names () in
  List.iter
    (fun name ->
      check bool (name ^ " retained in raw inventory") true (List.mem name raw_names);
      check bool (name ^ " omitted from public projection") false
        (List.mem name public_names))
    [ "masc_pause"; "masc_resume" ]

let test_shard_base_tools_registered_for_help () =
  List.iter
    (fun (tool : Masc_domain.tool_schema) ->
      let registered =
        Config.raw_all_tool_schemas
        |> List.exists (fun (schema : Masc_domain.tool_schema) ->
               String.equal schema.name tool.name)
      in
      check bool (tool.name ^ " in raw schemas") true registered;
      match Tool_help_registry.find_entry Config.raw_all_tool_schemas tool.name with
      | Some entry ->
          check string (tool.name ^ " help name") tool.name entry.name
      | None -> failf "%s missing from tool help registry" tool.name)
    Tool_shard.base_tools

let test_all_tool_names_omit_removed_mode_tools () =
  let names = Config.all_tool_names () in
  List.iter
    (fun name -> check bool (name ^ " removed") false (List.mem name names))
    [ "masc_switch_mode"; "masc_get_config"; "masc_tool_enable";
      "masc_tool_disable" ]

let test_tool_registry_omits_autoresearch_tools () =
  let has_autoresearch schemas =
    List.exists
      (fun (schema : Masc_domain.tool_schema) ->
         String.starts_with ~prefix:"masc_autoresearch_" schema.name)
      schemas
  in
  check bool "raw registry omits autoresearch" false
    (has_autoresearch Config.raw_all_tool_schemas);
  check bool "public front door hides autoresearch" false
    (has_autoresearch Config.all_tool_schemas);
  check bool "visible discovery hides autoresearch" false
    (has_autoresearch (Config.visible_tool_schemas ~include_hidden:true ()))

let test_visible_tool_schemas_subset_of_all () =
  let visible = Config.visible_tool_schemas () in
  check bool "visible <= all" true
    (List.length visible <= List.length Config.all_tool_schemas)

let test_control_tools_remain_admin_dispatchable () =
  List.iter
    (fun name ->
      check bool (name ^ " allowed on admin/catalog surface") true
        (Config.is_tool_allowed name);
      check bool (name ^ " included with include_hidden") true
        (Tool_catalog.is_visible ~include_hidden:true name))
    [ "masc_pause"; "masc_resume" ]

let () =
  run "Config Coverage"
    [
      ( "schema_registry",
        [
          test_case "dedupe_schemas" `Quick test_dedupe_schemas;
          test_case "raw schemas non-empty" `Quick
            test_raw_all_tool_schemas_non_empty;
          test_case "all schemas non-empty" `Quick
            test_all_tool_schemas_non_empty;
          test_case "control tools are raw-only" `Quick
            test_control_tools_keep_raw_schema_but_leave_public_projection;
          test_case "shard base tools registered for help" `Quick
            test_shard_base_tools_registered_for_help;
          test_case "removed mode tools omitted" `Quick
            test_all_tool_names_omit_removed_mode_tools;
          test_case "autoresearch tools omitted" `Quick
            test_tool_registry_omits_autoresearch_tools;
          test_case "visible is subset of all" `Quick
            test_visible_tool_schemas_subset_of_all;
          test_case "control tools remain admin dispatchable" `Quick
            test_control_tools_remain_admin_dispatchable;
        ] );
    ]
