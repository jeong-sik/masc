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

let instruction_skill ?(description = "Read these instructions before working.") name =
  Printf.sprintf
    {|---
name: %s
description: %s
---

Use the repository's focused validation wrapper.
|}
    name description
;;

let skill_catalog_with_description description =
  match
    Keeper_skill_catalog.of_documents
      [ "guide", instruction_skill ~description "guide"
      ; "snapshot", composition_skill ~name:"snapshot" ~execution:"async"
      ]
  with
  | Ok catalog -> catalog
  | Error error ->
    failf "fixture catalog rejected: %s"
      (Keeper_skill_catalog.error_to_string error)
;;

let skill_catalog () =
  skill_catalog_with_description "Read these instructions before working."
;;

let configured_external_skill_catalog () =
  let config_text =
    {|[skills]
activation-lifetime = "session"
precedence = "earlier-source-wins"
[[skills.sources]]
id = "shared-catalog"
anchor = "absolute"
path = "/srv/shared-agent-skills"
access = "read-only"
|}
  in
  let config =
    match Skill_source_config.parse_text config_text with
    | Ok config -> config
    | Error _ -> fail "external Skill source fixture config was rejected"
  in
  let source =
    match config.Skill_source_config.sources with
    | [ source ] -> source
    | _ -> fail "external Skill fixture did not contain exactly one source"
  in
  let resolved =
    Skill_source_config.resolve ~base_path:"/workspace" ~user_home:None source
  in
  let document = composition_skill ~name:"snapshot" ~execution:"async" in
  let scan : Skill_catalog_snapshot.source_scan =
    { source = resolved
    ; observation =
        Skill_catalog_snapshot.Source_ready
          { resolved_path = "/srv/shared-agent-skills"; candidates = 1 }
    ; candidates =
        [ Skill_catalog_snapshot.Candidate_document
            { directory = "snapshot"; source_text = document }
        ]
    }
  in
  let snapshot =
    match Skill_catalog_snapshot.configured ~config [ scan ] with
    | Ok snapshot -> snapshot
    | Error _ -> fail "external Skill snapshot fixture was rejected"
  in
  match Keeper_skill_catalog.of_snapshot snapshot with
  | catalog, [] -> catalog
  | _, diagnostics ->
    failf "external Skill projection returned %d diagnostics" (List.length diagnostics)
;;

let names (surface : Keeper_effective_tool_surface.t) =
  surface.tools
  |> List.map (fun (tool : Keeper_effective_tool_surface.tool) -> tool.name)
  |> List.sort String.compare
;;

(* The trailing unit is what lets [?catalog] be left out. Without it every
   argument is labelled, nothing marks the application as finished, and each
   call reads as a function still waiting for the optional rather than as
   the result it is used as. *)
let project
      ?(catalog = skill_catalog ())
      ~tool_groups
      ~task_skill_names
      ~native_posture
      ()
  =
  Keeper_effective_tool_surface.For_testing.project
    ~keeper_name:"fixture"
    ~runtime_id:"fixture.runtime"
    ~official_client_kind:"codex"
    ~native_posture:(Some native_posture)
    ~tool_groups
    ~current_task_id:(Some "task-001")
    ~task_skill_names
    ~skill_catalog:catalog
;;

let test_projection_names_equal_turn_surface_authority () =
  ignore (Masc_test_deps.init_unified_tool_registry ());
  match
    project
      ~tool_groups:None
      ~task_skill_names:[ "guide" ]
      ~native_posture:Runtime_native_tools.Native_read
      ()
  with
  | Error (_, detail) -> fail detail
  | Ok surface ->
    let descriptors = Keeper_tool_descriptor.model_visible_descriptors () in
    let expected =
      Keeper_run_tools_setup.expected_model_tool_names
        ~identity_tool_names:[]
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
            | Keeper_effective_tool_surface.Composition_skill _ -> true
            | _ -> false)
         surface.tools);
    check bool "official client digest exists" true
      (Option.is_some surface.tool_surface_sha256);
    let instruction_entries =
      Keeper_skill_catalog.instruction_entries (skill_catalog ())
    in
    let schema_tool =
      Keeper_tool_composition_surface.schema_tools
        ~instruction_skills:instruction_entries
        ()
      |> List.find_opt (fun (tool : Agent_core.Tool.t) ->
        String.equal tool.schema.name "keeper_skill")
    in
    (match schema_tool with
     | None -> fail "schema-only surface omitted keeper_skill"
     | Some tool ->
       check string "projection carries the exact Available list"
         (Keeper_tool_composition_surface.For_testing.instruction_skill_description
            instruction_entries)
         tool.schema.description)
;;

let test_external_composition_preserves_snapshot_provenance () =
  ignore (Masc_test_deps.init_unified_tool_registry ());
  match
    Keeper_effective_tool_surface.For_testing.project
      ~keeper_name:"fixture"
      ~runtime_id:"fixture.runtime"
      ~official_client_kind:"codex"
      ~native_posture:None
      ~tool_groups:None
      ~current_task_id:None
      ~task_skill_names:[]
      ~skill_catalog:(configured_external_skill_catalog ())
  with
  | Error (_, detail) -> fail detail
  | Ok surface ->
    let provenance =
      List.find_map
        (fun (tool : Keeper_effective_tool_surface.tool) ->
           match tool.origin with
           | Keeper_effective_tool_surface.Composition_skill
               { provenance = Some provenance } -> Some provenance
           | Composition_skill { provenance = None }
           | Descriptor _
           | Composition_plan
           | Composition_control -> None)
        surface.tools
    in
    (match provenance with
     | None -> fail "external composition lost snapshot provenance"
     | Some provenance ->
       check string "exact configured source id" "shared-catalog"
         (Skill_source_config.source_id_to_string provenance.source.id);
       check string "exact configured source path" "/srv/shared-agent-skills"
         provenance.source.configured_path;
       check string "exact package directory" "snapshot" provenance.directory;
       check string "exact identity source" "shared-catalog"
         (Skill_source_config.source_id_to_string provenance.identity.source_id));
    let open Yojson.Safe.Util in
    let composition_origin =
      Keeper_effective_tool_surface.to_yojson (Available surface)
      |> member "tools"
      |> to_list
      |> List.find_map (fun tool ->
        let origin = member "origin" tool in
        match member "kind" origin with
        | `String "composition_skill" -> Some origin
        | _ -> None)
    in
    (match composition_origin with
     | None -> fail "effective-surface JSON omitted composition provenance"
     | Some origin ->
       check string "wire source path is exact" "/srv/shared-agent-skills"
         (origin |> member "skill_provenance" |> member "source" |> member "path"
          |> to_string);
       check string "wire identity source is exact" "shared-catalog"
         (origin |> member "skill_provenance" |> member "identity"
          |> member "source_id" |> to_string))
;;

let test_two_surfaces_have_different_names_and_digests () =
  ignore (Masc_test_deps.init_unified_tool_registry ());
  let all =
    project
      ~tool_groups:None
      ~task_skill_names:[]
      ~native_posture:Runtime_native_tools.Native_read
      ()
  in
  let narrow =
    project
      ~tool_groups:(Some [ "fs" ])
      ~task_skill_names:[]
      ~native_posture:Runtime_native_tools.Native_full
      ()
  in
  match all, narrow with
  | Ok left, Ok right ->
    check bool "effective names differ" true (names left <> names right);
    check bool "session digests differ" true
      (left.tool_surface_sha256 <> right.tool_surface_sha256)
  | Error (_, detail), _ | _, Error (_, detail) -> fail detail
;;

let test_instruction_skill_without_read_is_admitted () =
  ignore (Masc_test_deps.init_unified_tool_registry ());
  match
    project
      ~tool_groups:(Some [ "board" ])
      ~task_skill_names:[ "guide" ]
      ~native_posture:Runtime_native_tools.Native_read
      ()
  with
  | Error (_, detail) -> fail detail
  | Ok surface ->
    check (list string) "instruction name is admitted" [ "guide" ]
      surface.instruction_skills;
    check bool "dedicated reader is present" true
      (List.exists (String.equal "keeper_skill") (names surface))
;;

let test_instruction_description_changes_digest () =
  ignore (Masc_test_deps.init_unified_tool_registry ());
  let project_description description =
    project
      ~catalog:(skill_catalog_with_description description)
      ~tool_groups:None
      ~task_skill_names:[ "guide" ]
      ~native_posture:Runtime_native_tools.Native_read
      ()
  in
  match project_description "first contract", project_description "second contract" with
  | Ok left, Ok right ->
    check bool "instruction description participates in digest" true
      (left.tool_surface_sha256 <> right.tool_surface_sha256)
  | Error (_, detail), _ | _, Error (_, detail) -> fail detail
;;

let rec remove_tree path =
  if Sys.is_directory path
  then (
    Sys.readdir path
    |> Array.iter (fun name -> remove_tree (Filename.concat path name));
    Unix.rmdir path)
  else Sys.remove path
;;

let test_turn_admission_uses_dedicated_instruction_reader () =
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
         Keeper_run_tools_setup.validate_held_task_skill_admission
           ~config
           ~meta
           ~skill_catalog:(skill_catalog ())
       with
       | Ok () -> ()
       | Error error -> fail (Agent_core.Error.to_string error))
;;

(* task-364: a keeper holding task A (current) that claims task B, which
   names an instruction skill, must have B's skills admitted too — the
   reconciler keeps A current, so B is only reachable as a held task. *)
let test_turn_admission_covers_held_tasks_beyond_current () =
  let base = Filename.temp_file "keeper-skill-held-" "" in
  Sys.remove base;
  Unix.mkdir base 0o755;
  Fun.protect
    ~finally:(fun () -> remove_tree base)
    (fun () ->
       let config = Workspace.default_config base in
       ignore (Workspace.init config ~agent_name:None);
       let agent_name = "keeper-skill-held-agent" in
       let add ~skills ~title =
         match
           Workspace.add_task_with_result
             ~created_by:"fixture" ~skills config ~title ~priority:3 ~description:"fixture"
         with
         | Ok created -> created.task_id
         | Error error -> fail (Workspace.add_task_error_to_string error)
       in
       let task_a = add ~skills:[] ~title:"plain work" in
       let task_b = add ~skills:[ "guide" ] ~title:"skill work" in
       (* Both held by the same keeper. The claim rule admits one live claim
          per agent, so the backlog is written directly: what matters here is
          the projection over two held tasks, not how they came to be held. *)
       let backlog = Workspace_backlog.read_backlog config in
       Workspace_backlog.write_backlog config
         { backlog with
           tasks =
             List.map
               (fun (task : Masc_domain.task) ->
                  if String.equal task.id task_a || String.equal task.id task_b
                  then
                    { task with
                      task_status =
                        Masc_domain.Claimed
                          { assignee = agent_name; claimed_at = "2026-08-26T00:00:00Z" }
                    }
                  else task)
               backlog.tasks
         };
       let current_task_id =
         match Keeper_id.Task_id.of_string task_a with
         | Ok task_id -> Some task_id
         | Error detail -> fail detail
       in
       let meta ~tool_groups =
         match
           Masc_test_deps.meta_of_json_fixture
             (`Assoc
                [ "name", `String "skill-held"
                ; "agent_name", `String agent_name
                ; "trace_id", `String "skill-held-trace"
                ])
         with
         | Ok meta -> { meta with current_task_id; tool_groups }
         | Error detail -> fail detail
       in
       (match
          Keeper_run_tools_setup.validate_held_task_skill_admission
            ~config
            ~meta:(meta ~tool_groups:(Some [ "board" ]))
            ~skill_catalog:Keeper_skill_catalog.empty
        with
        | Ok () -> fail "held task's missing skill was not inspected"
        | Error error ->
          let rendered = Agent_core.Error.to_string error in
          check bool "the held task, not the current one, is named" true
            (String_util.contains_substring rendered task_b);
          check bool "the held skill is named" true
            (String_util.contains_substring rendered "guide"));
       (match
          Keeper_run_tools_setup.validate_held_task_skill_admission
            ~config ~meta:(meta ~tool_groups:(Some [ "board" ])) ~skill_catalog:(skill_catalog ())
        with
        | Ok () -> ()
        | Error error -> fail (Agent_core.Error.to_string error));
       match
         Keeper_run_tools_setup.validate_held_task_skill_admission
           ~config ~meta:(meta ~tool_groups:None) ~skill_catalog:(skill_catalog ())
       with
       | Ok () -> ()
       | Error error -> fail (Agent_core.Error.to_string error))
;;

let () =
  Alcotest.run
    "keeper effective tool surface"
    [ ( "projection"
      , [ test_case "names equal turn setup authority" `Quick
            test_projection_names_equal_turn_surface_authority
        ; test_case "different Keeper declarations change names and digest" `Quick
            test_two_surfaces_have_different_names_and_digests
        ; test_case
            "external composition preserves snapshot provenance"
            `Quick
            test_external_composition_preserves_snapshot_provenance
        ; test_case "instruction skill does not require Read" `Quick
            test_instruction_skill_without_read_is_admitted
        ; test_case "instruction description changes digest" `Quick
            test_instruction_description_changes_digest
        ; test_case "turn admission uses dedicated instruction reader" `Quick
            test_turn_admission_uses_dedicated_instruction_reader
        ; test_case "turn admission covers held tasks beyond the current one" `Quick
            test_turn_admission_covers_held_tasks_beyond_current
        ] )
    ]
;;
