(** Config Module Coverage Tests

    Tests for the schema registry helpers that remain after mode removal.
*)

open Alcotest

module Config = Masc_mcp.Config
module Auth = Masc_mcp.Auth
module Tool_catalog = Masc_mcp.Tool_catalog
module Tool_help_registry = Masc_mcp.Tool_help_registry
module Tool_shard = Masc_mcp.Tool_shard
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

let test_all_tool_names_contains_pause () =
  check bool "masc_pause registered" true
    (List.mem "masc_pause" (Config.all_tool_names ()))

let test_all_tool_names_contains_approval_get () =
  check bool "masc_approval_get registered" true
    (List.mem "masc_approval_get" (Config.all_tool_names ()))

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

let test_approval_get_requires_admin_permission () =
  check bool "approval_get admin-only" true
    (Auth.permission_for_tool "masc_approval_get" = Some Masc_domain.CanAdmin);
  check bool "approval_resolve admin-only" true
    (Auth.permission_for_tool "masc_approval_resolve" = Some Masc_domain.CanAdmin)

let test_all_tool_names_omit_removed_mode_tools () =
  let names = Config.all_tool_names () in
  List.iter
    (fun name -> check bool (name ^ " removed") false (List.mem name names))
    [ "masc_switch_mode"; "masc_get_config"; "masc_tool_enable";
      "masc_tool_disable" ]

let test_visible_tool_schemas_subset_of_all () =
  let visible = Config.visible_tool_schemas () in
  check bool "visible <= all" true
    (List.length visible <= List.length Config.all_tool_schemas)

let test_is_tool_visible_pause () =
  (* masc_pause is an internal tool, auto-classified as Hidden *)
  check bool "pause hidden (not on public surface)" false
    (Config.is_tool_visible "masc_pause");
  check bool "pause visible with include_hidden" true
    (Tool_catalog.is_visible ~include_hidden:true "masc_pause")

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
          test_case "all_tool_names contains pause" `Quick
            test_all_tool_names_contains_pause;
          test_case "all_tool_names contains approval_get" `Quick
            test_all_tool_names_contains_approval_get;
          test_case "shard base tools registered for help" `Quick
            test_shard_base_tools_registered_for_help;
          test_case "approval get requires admin permission" `Quick
            test_approval_get_requires_admin_permission;
          test_case "removed mode tools omitted" `Quick
            test_all_tool_names_omit_removed_mode_tools;
          test_case "visible is subset of all" `Quick
            test_visible_tool_schemas_subset_of_all;
          test_case "pause visible" `Quick test_is_tool_visible_pause;
        ] );
    ]
