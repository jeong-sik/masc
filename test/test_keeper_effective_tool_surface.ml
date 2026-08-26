open Alcotest
open Masc

let composition_skill ~name ~execution =
  Printf.sprintf
    {|---
name: %s
description: Effective surface fixture.
---

```toml composition
[[compositions]]
name = "%s"
description = "Effective surface fixture."
execution = "%s"

[[compositions.nodes]]
id = "clock"
tool = "keeper_time_now"
[compositions.nodes.input]
kind = "literal"
value = {}
```
|}
    name name execution
;;

let instruction_skill name =
  Printf.sprintf
    {|---
name: %s
description: Read these instructions before working.
---

Use the repository's focused validation wrapper.
|}
    name
;;

let skill_catalog () =
  match
    Keeper_skill_catalog.of_documents
      [ "guide", instruction_skill "guide"
      ; "snapshot", composition_skill ~name:"snapshot" ~execution:"async"
      ]
  with
  | Ok catalog -> catalog
  | Error error ->
    failf "fixture catalog rejected: %s"
      (Keeper_skill_catalog.error_to_string error)
;;

let names (surface : Keeper_effective_tool_surface.t) =
  surface.tools
  |> List.map (fun (tool : Keeper_effective_tool_surface.tool) -> tool.name)
  |> List.sort String.compare
;;

let project ~tool_groups ~task_skill_names ~native_posture =
  Keeper_effective_tool_surface.For_testing.project
    ~keeper_name:"fixture"
    ~runtime_id:"fixture.runtime"
    ~official_client_kind:"codex"
    ~native_posture:(Some native_posture)
    ~tool_groups
    ~current_task_id:(Some "task-001")
    ~task_skill_names
    ~skill_catalog:(skill_catalog ())
;;

let test_projection_names_equal_turn_surface_authority () =
  ignore (Masc_test_deps.init_unified_tool_registry ());
  match
    project
      ~tool_groups:None
      ~task_skill_names:[ "guide" ]
      ~native_posture:Runtime_native_tools.Native_read
  with
  | Error (_, detail) -> fail detail
  | Ok surface ->
    let descriptors = Keeper_tool_descriptor.model_visible_descriptors () in
    let expected =
      Keeper_run_tools_setup.expected_model_tool_names
        ~skill_catalog:(skill_catalog ())
        ~model_visible_descriptors:descriptors
    in
    check (list string) "projection and turn setup names are identical"
      expected (names surface);
    check (list string) "instruction skill is explicit" [ "guide" ]
      surface.instruction_skills;
    check bool "instruction reader provenance exists" true
      (List.exists
         (fun (tool : Keeper_effective_tool_surface.tool) ->
            String.equal tool.name "keeper_skill"
            && tool.origin = Keeper_effective_tool_surface.Instruction_skill)
         surface.tools);
    check bool "composition provenance exists" true
      (List.exists
         (fun (tool : Keeper_effective_tool_surface.tool) ->
            match tool.origin with
            | Keeper_effective_tool_surface.Composition_skill
                { source = "skills/snapshot/SKILL.md" } -> true
            | _ -> false)
         surface.tools);
    check bool "official client digest exists" true
      (Option.is_some surface.tool_surface_sha256)
;;

let test_two_surfaces_have_different_names_and_digests () =
  ignore (Masc_test_deps.init_unified_tool_registry ());
  let all =
    project
      ~tool_groups:None
      ~task_skill_names:[]
      ~native_posture:Runtime_native_tools.Native_read
  in
  let narrow =
    project
      ~tool_groups:(Some [ "fs" ])
      ~task_skill_names:[]
      ~native_posture:Runtime_native_tools.Native_full
  in
  match all, narrow with
  | Ok left, Ok right ->
    check bool "effective names differ" true (names left <> names right);
    check bool "session digests differ" true
      (left.tool_surface_sha256 <> right.tool_surface_sha256)
  | Error (_, detail), _ | _, Error (_, detail) -> fail detail
;;

let test_instruction_skill_without_read_fails_closed () =
  ignore (Masc_test_deps.init_unified_tool_registry ());
  match
    project
      ~tool_groups:(Some [ "board" ])
      ~task_skill_names:[ "guide" ]
      ~native_posture:Runtime_native_tools.Native_read
  with
  | Error (reason, _) ->
    check string "typed conflict" "instruction_skill_unreadable" reason
  | Ok _ -> fail "instruction skill was projected without Read"
;;

let rec remove_tree path =
  if Sys.is_directory path
  then (
    Sys.readdir path
    |> Array.iter (fun name -> remove_tree (Filename.concat path name));
    Unix.rmdir path)
  else Sys.remove path
;;

let test_turn_admission_rechecks_instruction_readability () =
  let base = Filename.temp_file "keeper-skill-admission-" "" in
  Sys.remove base;
  Unix.mkdir base 0o755;
  Fun.protect
    ~finally:(fun () -> remove_tree base)
    (fun () ->
       let config = Workspace.default_config base in
       ignore (Workspace.init config ~agent_name:None);
       let created =
         match
           Workspace.add_task_with_result
             ~created_by:"fixture"
             ~skills:[ "guide" ]
             config
             ~title:"skill admission"
             ~priority:3
             ~description:"fixture"
         with
         | Ok created -> created
         | Error error -> fail (Workspace.add_task_error_to_string error)
       in
       let current_task_id =
         match Keeper_id.Task_id.of_string created.task_id with
         | Ok task_id -> Some task_id
         | Error detail -> fail detail
       in
       let meta =
         match
           Masc_test_deps.meta_of_json_fixture
             (`Assoc
                [ "name", `String "skill-admission"
                ; "agent_name", `String "keeper-skill-admission-agent"
                ; "trace_id", `String "skill-admission-trace"
                ])
         with
         | Ok meta ->
           { meta with current_task_id; tool_groups = Some [ "board" ] }
         | Error detail -> fail detail
       in
       match
         Keeper_run_tools_setup.validate_current_task_skill_admission
           ~config
           ~meta
           ~skill_catalog:(skill_catalog ())
       with
       | Error error ->
         check bool "turn admission names Read conflict" true
           (String_util.contains_substring
              (Agent_core.Error.to_string error)
              "model-visible Read tool")
       | Ok () -> fail "turn admission accepted an unreadable instruction skill")
;;

let () =
  Alcotest.run
    "keeper effective tool surface"
    [ ( "projection"
      , [ test_case "names equal turn setup authority" `Quick
            test_projection_names_equal_turn_surface_authority
        ; test_case "different Keeper declarations change names and digest" `Quick
            test_two_surfaces_have_different_names_and_digests
        ; test_case "instruction skill requires Read" `Quick
            test_instruction_skill_without_read_fails_closed
        ; test_case "turn admission rechecks Read" `Quick
            test_turn_admission_rechecks_instruction_readability
        ] )
    ]
;;
