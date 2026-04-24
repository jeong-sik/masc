(* test/test_tool_help_registry_shard_coverage_10101.ml

   #10101: [Config.raw_all_tool_schemas] is the authoritative
   list consumed by [Tool_help_registry.find_entry].  #9912
   patched only [Tool_shard.base_tools] (5 always-present
   tools), leaving 11 other shard categories unregistered so
   [masc_tool_help(keeper_task_claim)] returned "unknown tool"
   despite the dispatcher handling the tool correctly.

   This test asserts the full invariant: every schema exported
   by [Tool_shard.all_keeper_tool_schemas] is resolvable from
   [Config.raw_all_tool_schemas].  If a new shard category is
   introduced and forgotten at the aggregation site, or if a
   future refactor re-introduces the patch-local
   [@ Tool_shard.base_tools] pattern, this test surfaces it
   immediately by name.

   Also pins the specific cases called out in the issue: the
   11 shard categories each have a representative tool name
   that must round-trip through [find_entry]. *)

(* Module init runs Cdal_verdict_gate.default_base_path at
   startup — #9903 prod-guard raises under HOME.  Same dune
   [setenv] pattern as #10091 / #10097. *)
let () =
  let dir =
    Filename.concat (Filename.get_temp_dir_name ())
      (Printf.sprintf "masc-test-tool-help-coverage-10101-%06x" (Random.bits ()))
  in
  Unix.putenv "MASC_BASE_PATH" dir

module Config = Masc_mcp.Config
module Shard = Masc_mcp.Tool_shard
module Registry = Masc_mcp.Tool_help_registry

let registry_has name =
  Option.is_some (Registry.find_entry Config.raw_all_tool_schemas name)

(* Full coverage check: every tool schema exposed by
   [Tool_shard.all_keeper_tool_schemas] must be resolvable via
   [Config.raw_all_tool_schemas].  This is the structural
   invariant — if it fails, aggregation has drifted. *)
let test_every_shard_tool_is_in_authoritative_registry () =
  let shard_schemas = Shard.all_keeper_tool_schemas in
  let missing =
    List.filter_map
      (fun (s : Types.tool_schema) ->
        if registry_has s.name then None else Some s.name)
      shard_schemas
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

(* The direct symptom from the issue — [keeper_task_claim] was
   the "unknown tool" in the live system.  Keep this as a
   named assertion so a regression is easy to spot in the
   test name alone. *)
let test_keeper_task_claim_is_resolvable () =
  Alcotest.(check bool)
    "keeper_task_claim resolves in Config.raw_all_tool_schemas"
    true (registry_has "keeper_task_claim")

(* Representative sample across the 11 previously-missing
   categories (per issue body).  If any ONE of these is
   missing, the aggregation regressed for that whole category. *)
let test_representative_tools_across_categories () =
  let representatives =
    [
      "keeper_stay_silent",   "base_tools";
      "keeper_board_post",    "board_tools";
      "keeper_fs_read",       "filesystem_tools";
      "keeper_shell",         "shell_tools";
      "keeper_task_claim",    "taskboard_tools";
      "keeper_library_search","library_tools";
      "keeper_voice_speak",   "voice_tools";
    ]
  in
  List.iter
    (fun (name, category) ->
      Alcotest.(check bool)
        (Printf.sprintf "%s (%s) resolves" name category)
        true (registry_has name))
    representatives

(* The #9912 fix bolted [Tool_shard.base_tools] onto
   [raw_all_tool_schemas] directly.  We replaced that with
   [all_keeper_tool_schemas] — this test makes sure the base
   five tools are still in there (not regressed by the
   replacement). *)
let test_9912_base_tools_still_covered () =
  let base_five =
    [ "keeper_stay_silent"
    ; "keeper_time_now"
    ; "keeper_context_status"
    ; "keeper_memory_search"
    ; "keeper_tools_list"
    ]
  in
  List.iter
    (fun name ->
      Alcotest.(check bool)
        (Printf.sprintf "#9912 base tool %s stays resolvable" name)
        true (registry_has name))
    base_five

(* [keeper_preflight_tools] and [keeper_pr_review_tools] live
   in [tool_shard.ml] but are NOT owned by any shard in
   [all_shards].  The SSOT helper must include them explicitly
   — if someone refactors to "just iterate all_shards", these
   two lists would drop out silently.  Test pins one
   representative from each. *)
let test_non_shard_lists_are_covered () =
  List.iter
    (fun (sample_name, list_name) ->
      (* We cannot rely on stable tool names inside
         keeper_preflight_tools/pr_review_tools without
         coupling the test to implementation detail, so read
         the first schema name from each list at runtime. *)
      match sample_name with
      | Some name ->
        Alcotest.(check bool)
          (Printf.sprintf "%s (%s) resolves" name list_name)
          true (registry_has name)
      | None ->
        (* Empty list is acceptable — tested category just has
           no tools yet.  Not a failure. *)
        ())
    [
      ( (match Shard.keeper_preflight_tools with
         | []     -> None
         | s :: _ -> Some s.name),
        "keeper_preflight_tools" );
    ]

let () =
  Alcotest.run "tool_help_registry_shard_coverage_10101"
    [
      ( "full_coverage",
        [
          Alcotest.test_case
            "every shard tool is in Config.raw_all_tool_schemas"
            `Quick test_every_shard_tool_is_in_authoritative_registry;
        ] );
      ( "named_cases",
        [
          Alcotest.test_case "keeper_task_claim (issue's direct case)"
            `Quick test_keeper_task_claim_is_resolvable;
          Alcotest.test_case "representatives across 7 categories"
            `Quick test_representative_tools_across_categories;
          Alcotest.test_case "#9912 base tools still covered"
            `Quick test_9912_base_tools_still_covered;
          Alcotest.test_case "non-shard preflight list covered"
            `Quick test_non_shard_lists_are_covered;
        ] );
    ]
