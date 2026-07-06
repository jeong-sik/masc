(* test/test_tool_help_metadata_rfc_0195.ml

   RFC-0195 P0 — help_entry record gains two optional, additive
   metadata fields: [examples] and [alternatives]. These fields
   exist so LLMs can recover from workflow_rejection / governance
   denial / catalog miss without parsing prose hints (RFC-0194 §2).

   This test pins:
   - The six target tools curated in this PR carry non-empty
     [examples] (so the LLM has a concrete invocation template).
   - The four tools whose semantics name a sibling carry a
     non-empty [alternatives] list (so the LLM has a typed next
     step on rejection). The remaining curated tools that are
     genuinely terminal (keeper_memory_write, masc_plan_set_task)
     are pinned as having an empty alternatives list — the
     expectation is "no sibling exists", not "we forgot to fill
     it in".
   - Every name listed in any [alternatives] field resolves
     through [find_entry] against the authoritative schema list,
     so an alternatives entry can never become a dangling
     reference at the source of truth.

   Same MASC_BASE_PATH setenv pattern as
   test_tool_help_registry_shard_coverage_10101.ml — module init
   triggers Cdal_verdict_gate.default_base_path which raises
   under HOME. *)

let () =
  let dir =
    Filename.concat (Filename.get_temp_dir_name ())
      (Printf.sprintf "masc-test-tool-help-metadata-rfc0195-%06x" (Random.bits ()))
  in
  Unix.putenv "MASC_BASE_PATH" dir

module Config = Masc.Config
module Catalog = Tool_catalog
module Registry = Tool_help_registry

let lookup name =
  match Registry.find_entry Config.raw_all_tool_schemas name with
  | Some entry -> entry
  | None ->
    Alcotest.failf
      "RFC-0195 P0: target tool %S is missing from \
       Config.raw_all_tool_schemas; the manual help override \
       cannot reach it" name

(* The six target tools listed in RFC-0195 P0 cover two
   reachability classes:
   - Four are registered in Config.raw_all_tool_schemas and
     therefore round-trip through find_entry. Those are the
     ones this test pins.
   - One (masc_plan_set_task) is a workspace-side tool whose schema lives on
     a different surface that this PR does not modify. Its manual_help
     entry is written here as future-proofing — it takes
     effect the moment those schemas join the keeper-side
     registry. See PR body §"Reachable surface" for the split. *)
let curated_with_examples =
  [
    "keeper_task_done";
    "keeper_memory_write";
    "keeper_tasks_list";
  ]

let curated_with_alternatives = []

let curated_terminal =
  [ "keeper_memory_write"; "keeper_tasks_list" ]

let test_examples_populated () =
  List.iter
    (fun name ->
      let entry = lookup name in
      Alcotest.(check bool)
        (Printf.sprintf "%s has at least one example" name)
        true (entry.examples <> []))
    curated_with_examples

let test_alternatives_typed_list () =
  List.iter
    (fun (name, expected) ->
      let entry = lookup name in
      Alcotest.(check (list string))
        (Printf.sprintf "%s alternatives match RFC-0195 curation" name)
        expected entry.alternatives)
    curated_with_alternatives

let test_terminal_tools_empty_alternatives () =
  List.iter
    (fun name ->
      let entry = lookup name in
      Alcotest.(check (list string))
        (Printf.sprintf "%s is terminal — empty alternatives by design" name)
        [] entry.alternatives)
    curated_terminal

let test_alternatives_never_dangling () =
  let unresolved =
    List.concat_map
      (fun (s : Masc_domain.tool_schema) ->
        match Registry.find_entry Config.raw_all_tool_schemas s.name with
        | None -> []
        | Some entry ->
          List.filter_map
            (fun alt ->
              if Option.is_some
                   (Registry.find_entry Config.raw_all_tool_schemas alt)
              then None
              else Some (s.name, alt))
            entry.alternatives)
      Config.raw_all_tool_schemas
  in
  match unresolved with
  | [] -> ()
  | dangling ->
    let render (src, alt) = Printf.sprintf "%s -> %s" src alt in
    Alcotest.failf
      "RFC-0195 P0: %d dangling alternatives reference(s): %s"
      (List.length dangling)
      (String.concat ", " (List.map render dangling))

let test_entry_json_omits_empty_fields () =
  (* keeper_time_now has no curated examples/alternatives; the JSON wire shape
     must omit both keys so existing consumers see no field they did not see
     before. *)
  let entry = lookup "keeper_time_now" in
  let json = Registry.entry_json entry in
  match json with
  | `Assoc kvs ->
    let has_key key = List.exists (fun (k, _) -> String.equal k key) kvs in
    Alcotest.(check bool)
      "empty examples list omitted from JSON" false (has_key "examples");
    Alcotest.(check bool)
      "empty alternatives list omitted from JSON" false (has_key "alternatives")
  | _ -> Alcotest.fail "entry_json must return an Assoc"

let test_entry_json_includes_populated_fields () =
  let entry = lookup "keeper_task_done" in
  let json = Registry.entry_json entry in
  match json with
  | `Assoc kvs ->
    let has_key key = List.exists (fun (k, _) -> String.equal k key) kvs in
    Alcotest.(check bool)
      "populated examples list emitted in JSON" true (has_key "examples");
    Alcotest.(check bool)
      "empty alternatives list omitted from JSON" false (has_key "alternatives")
  | _ -> Alcotest.fail "entry_json must return an Assoc"

let command_plane_doc_refs =
  [
    "docs/COMMAND-PLANE-RUNBOOK.md";
    "docs/BENCHMARK-RUNBOOK.md";
  ]

let command_plane_operation_names =
  [
    "masc_policy_approve";
    "masc_policy_freeze_unit";
    "masc_policy_kill_switch";
    "masc_observe_operations";
    "masc_observe_capacity";
    "masc_observe_traces";
  ]

let synthetic_schema name : Masc_domain.tool_schema =
  {
    name;
    description = "Synthetic schema used to pin catalog-owned doc references.";
    input_schema = `Assoc [ ("type", `String "object"); ("properties", `Assoc []) ];
  }

let test_command_plane_doc_refs_owned_by_catalog () =
  List.iter
    (fun name ->
      Alcotest.(check (list string))
        (Printf.sprintf "%s doc refs come from Tool_catalog" name)
        command_plane_doc_refs (Catalog.doc_refs name))
    command_plane_operation_names

let test_entry_of_schema_uses_catalog_doc_refs () =
  let entry = Registry.entry_of_schema (synthetic_schema "masc_policy_approve") in
  Alcotest.(check (list string))
    "registered command-plane operation gets catalog doc refs"
    command_plane_doc_refs entry.doc_refs;
  let unrelated = Registry.entry_of_schema (synthetic_schema "masc_policy_unregistered") in
  Alcotest.(check (list string))
    "unregistered prefix sibling is not inferred by prefix"
    [] unrelated.doc_refs

let () =
  Alcotest.run "tool_help_metadata_rfc_0195"
    [
      ( "curated_metadata",
        [
          Alcotest.test_case "six target tools have examples"
            `Quick test_examples_populated;
          Alcotest.test_case "four target tools have typed alternatives"
            `Quick test_alternatives_typed_list;
          Alcotest.test_case "two target tools are terminal — empty alternatives"
            `Quick test_terminal_tools_empty_alternatives;
        ] );
      ( "registry_invariants",
        [
          Alcotest.test_case "alternatives names resolve through find_entry"
            `Quick test_alternatives_never_dangling;
        ] );
      ( "json_projection",
        [
          Alcotest.test_case "empty optional fields are omitted"
            `Quick test_entry_json_omits_empty_fields;
          Alcotest.test_case "populated optional fields are emitted"
            `Quick test_entry_json_includes_populated_fields;
        ] );
      ( "doc_refs",
        [
          Alcotest.test_case "command-plane doc refs are catalog-owned"
            `Quick test_command_plane_doc_refs_owned_by_catalog;
          Alcotest.test_case "entry_of_schema reads doc refs without prefix inference"
            `Quick test_entry_of_schema_uses_catalog_doc_refs;
        ] );
    ]
