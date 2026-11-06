module Types = Masc_domain

(* test/test_tool_help_registry_shard_coverage_10101.ml

   #10101: [Config.raw_all_tool_schemas] is the authoritative
   list consumed by [Tool_help_registry.find_entry].  #9912
   patched only [Tool_shard.base_tools] (5 always-present
   tools), leaving 11 other shard categories unregistered so
   [masc_tool_help(keeper_task_claim)] returned "unknown tool"
   despite the dispatcher handling the tool correctly.

   This test asserts the registry invariant: every schema exported
   by [Tool_shard.all_keeper_tool_schemas] is resolvable from
   [Config.raw_all_tool_schemas].  If a new shard category is
   introduced and forgotten at the aggregation site, or if a
   future refactor re-introduces the patch-local
   [@ Tool_shard.base_tools] pattern, this test surfaces it
   immediately by name. *)

(* Module init resolves the runtime base path at startup —
   the #9903 prod-guard raises under HOME.  Same dune
   [setenv] pattern as #10091 / #10097. *)
let () =
  let dir =
    Filename.concat (Filename.get_temp_dir_name ())
      (Printf.sprintf "masc-test-tool-help-coverage-10101-%06x" (Random.bits ()))
  in
  Unix.putenv "MASC_BASE_PATH" dir

module Config = Masc.Config
module Shard = Masc.Tool_shard
module Registry = Tool_help_registry

let registry_has name =
  Option.is_some (Registry.find_entry Config.raw_all_tool_schemas name)

(* Registry coverage check: every tool schema exposed by
   [Tool_shard.all_keeper_tool_schemas] must be resolvable via
   [Config.raw_all_tool_schemas].  This is the structural invariant for
   help lookup and dispatch-supporting metadata — if it fails,
   aggregation has drifted. *)
let test_every_shard_tool_is_in_authoritative_registry () =
  let missing =
    List.filter_map
      (fun (s : Masc_domain.tool_schema) ->
        if registry_has s.name then None else Some s.name)
      Shard.all_keeper_tool_schemas
    |> List.sort_uniq String.compare
  in
  match missing with
  | [] -> ()
  | names ->
    Alcotest.failf
      "#10101 regression: %d shard tool(s) missing from \
       Config.raw_all_tool_schemas: %s"
      (List.length names)
      (String.concat ", " names)

let () =
  Alcotest.run "tool_help_registry_shard_coverage_10101"
    [
      ( "full_coverage",
        [
          Alcotest.test_case
            "every shard tool is in Config.raw_all_tool_schemas"
            `Quick test_every_shard_tool_is_in_authoritative_registry;
        ] );
    ]
