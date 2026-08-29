open Alcotest
open Masc

let resolve_observed_task_skills ~config ~meta ~skill_snapshot =
  Keeper_task_skill_turn.resolve_observations
    ~snapshot:skill_snapshot
    ~current_task:(Keeper_world_observation_inputs.read_current_task ~config ~meta)
    ~held_task_skills:
      (Keeper_world_observation_inputs.read_held_task_skills ~config ~meta)
  |> Result.map_error Keeper_task_skill_turn.core_error
;;

let validate_observed_task_skills ~config ~meta ~skill_snapshot =
  Result.map (fun _ -> ())
    (resolve_observed_task_skills ~config ~meta ~skill_snapshot)
;;

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

[[compositions.nodes]]
id = "board"
tool = "masc_board_stats"
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

let configured_snapshot ~source_id ~anchor ~path documents =
  let config_text =
    Printf.sprintf
      "[skills]\nresource-read-max-bytes = 65536\n[[skills.sources]]\nid = %S\nanchor = %S\npath = %S\naccess = \"read-only\"\n"
      source_id
      anchor
      path
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
  let scan : Skill_catalog_snapshot.source_scan =
    { source = resolved
    ; observation =
        Skill_catalog_snapshot.Source_ready
          { resolved_path = path; candidates = List.length documents }
    ; candidates =
        List.map
          (fun (directory, source_text) ->
             Skill_catalog_snapshot.Candidate_document { directory; source_text })
          documents
    }
  in
  let snapshot =
    match Skill_catalog_snapshot.configured ~config [ scan ] with
    | Ok snapshot -> snapshot
    | Error _ -> fail "external Skill snapshot fixture was rejected"
  in
  snapshot
;;

let skill_snapshot_with_description description =
  configured_snapshot
    ~source_id:"fixture-catalog"
    ~anchor:"base-path"
    ~path:"skills"
    [ "guide", instruction_skill ~description "guide"
    ; "snapshot", composition_skill ~name:"snapshot" ~execution:"async"
    ]
;;

let skill_snapshot () =
  skill_snapshot_with_description "Read these instructions before working."
;;

let skill_catalog_with_description description =
  let catalog, diagnostics =
    Keeper_skill_catalog.of_snapshot (skill_snapshot_with_description description)
  in
  match diagnostics with
  | [] -> catalog
  | diagnostics ->
    failf "fixture catalog projected with %d diagnostics" (List.length diagnostics)
;;

let skill_catalog () =
  skill_catalog_with_description "Read these instructions before working."
;;

let configured_external_skill_snapshot () =
  configured_snapshot
    ~source_id:"shared-catalog"
    ~anchor:"absolute"
    ~path:"/srv/shared-agent-skills"
    [ "snapshot", composition_skill ~name:"snapshot" ~execution:"async" ]
;;

let reference_by_name snapshot name =
  match Skill_catalog_snapshot.find_effective_by_name snapshot name with
  | Some entry -> Skill_catalog_snapshot.entry_reference entry
  | None -> failf "fixture Skill %S is absent" name
;;

let instruction_entries snapshot references =
  match Keeper_task_skill_turn.resolve ~snapshot references with
  | Error error -> fail (Keeper_task_skill_turn.error_to_string error)
  | Ok selection ->
    let partition = Keeper_task_skill_turn.partition selection in
    List.map
      (fun (selected : Keeper_task_skill_turn.selected) ->
         Keeper_tool_composition_surface.instruction_skill
           ~reference:selected.reference
           ~description:selected.skill.description
           ~body:selected.skill.body
           ())
      partition.instructions
;;

let names (surface : Keeper_effective_tool_surface.t) =
  surface.tools
  |> List.map (fun (tool : Keeper_effective_tool_surface.tool) -> tool.name)
  |> List.sort String.compare
;;

(* The trailing unit is what lets [?snapshot] be left out. Without it every
   argument is labelled, nothing marks the application as finished, and each
   call reads as a function still waiting for the optional rather than as
   the result it is used as. *)
let project
      ?(snapshot = skill_snapshot ())
      ?(skills_left_out = [])
      ?(skill_names = None)
      ~task_skill_references
      ~native_posture
      ()
  =
  let task_selection =
    match
      Keeper_task_skill_turn.resolve_for_task
        ~snapshot
        ~task_id:"task-001"
        task_skill_references
    with
    | Ok selection -> selection
    | Error error -> fail (Keeper_task_skill_turn.error_to_string error)
  in
  Keeper_effective_tool_surface.For_testing.project
    ~keeper_name:"fixture"
    ~runtime_id:"fixture.runtime"
    ~official_client_kind:"codex"
    ~tool_delivery:Keeper_effective_tool_surface.Tools_delivered
    ~native_posture:(Some native_posture)
    ~skill_names
    ~current_task_id:(Some "task-001")
    ~skills_left_out
    ~task_skill_references
    ~task_selection:(Some task_selection)
    ~skill_snapshot:snapshot
;;

let test_skill_name_selection_is_structured_and_filters_task () =
  ignore (Masc_test_deps.init_unified_tool_registry ());
  let snapshot = skill_snapshot () in
  let task_snapshot = reference_by_name snapshot "snapshot" in
  let selected =
    match
      project
        ~snapshot
        ~skill_names:(Some [ "guide"; "missing" ])
        ~task_skill_references:[ task_snapshot ]
        ~native_posture:Runtime_native_tools.Native_read
        ()
    with
    | Ok surface -> surface
    | Error error -> fail (Keeper_task_skill_turn.error_to_string error)
  in
  check int "one selected instruction" 1 (List.length selected.instruction_skills);
  check int "Task composition is filtered" 0 (List.length selected.composition_skills);
  let json = Keeper_effective_tool_surface.to_yojson (Available selected) in
  check string
    "operator projection does not claim to be a frozen executed turn"
    "computed_current"
    Yojson.Safe.Util.(member "projection_basis" json |> to_string);
  check string
    "selection mode"
    "names"
    Yojson.Safe.Util.(member "skill_selection" json |> member "mode" |> to_string);
  check (list string)
    "configured names"
    [ "guide"; "missing" ]
    Yojson.Safe.Util.(member "skill_selection" json |> member "names" |> to_list |> List.map to_string);
  let unavailable = Yojson.Safe.Util.(member "unavailable_skill_names" json |> to_list) in
  check int "one structured unavailable name" 1 (List.length unavailable);
  (match unavailable with
   | [ value ] ->
     check string "unavailable name" "missing" Yojson.Safe.Util.(member "name" value |> to_string);
     check string
       "unavailable reason"
       "not_in_turn_skill_catalog"
       Yojson.Safe.Util.(member "reason" value |> to_string)
   | _ -> fail "unavailable name projection changed shape");
  let selected_reasons =
    Yojson.Safe.Util.(member "skill_profiles" json |> to_list)
    |> List.concat_map (fun profile ->
         Yojson.Safe.Util.(member "load_reasons" profile |> to_list)
         |> List.map (fun reason ->
              Yojson.Safe.Util.(member "kind" reason |> to_string)))
  in
  check (list string)
    "configured Keeper profile is the exact load reason"
    [ "keeper_profile" ]
    selected_reasons;
  let none =
    match
      project
        ~snapshot
        ~skill_names:(Some [])
        ~task_skill_references:[ task_snapshot ]
        ~native_posture:Runtime_native_tools.Native_read
        ()
    with
    | Ok surface -> surface
    | Error error -> fail (Keeper_task_skill_turn.error_to_string error)
  in
  check int "explicit empty has no instruction Skills" 0 (List.length none.instruction_skills);
  check int "explicit empty has no composition Skills" 0 (List.length none.composition_skills)
;;

let test_projection_names_equal_turn_surface_authority () =
  ignore (Masc_test_deps.init_unified_tool_registry ());
  let snapshot = skill_snapshot () in
  let task_reference = reference_by_name snapshot "guide" in
  match
    project
      ~snapshot
      ~skill_names:None
      ~task_skill_references:[ task_reference ]
      ~native_posture:Runtime_native_tools.Native_read
      ()
  with
  | Error error -> fail (Keeper_task_skill_turn.error_to_string error)
  | Ok surface ->
    let descriptors = Keeper_tool_descriptor.model_visible_descriptors () in
    let catalog, diagnostics = Keeper_skill_catalog.of_snapshot snapshot in
    check int "snapshot projection diagnostics" 0 (List.length diagnostics);
    let expected =
      Keeper_run_tools_setup.expected_model_tool_names
        ~identity_names:[]
        ~skill_catalog:catalog
        ~model_visible_descriptors:descriptors
        ()
    in
    check (list string) "projection and turn setup names are identical"
      expected (names surface);
    check string
      "instruction skill is exact"
      (Skill_reference.list_to_yojson [ task_reference ] |> Yojson.Safe.to_string)
      (Skill_reference.list_to_yojson surface.instruction_skills
       |> Yojson.Safe.to_string);
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
    check bool "whole tool surface bytes are measured" true
      (surface.tool_surface_bytes > 0);
    check bool "Skill tool bytes are a strict subset" true
      (surface.skill_tool_surface_bytes > 0
       && surface.skill_tool_surface_bytes < surface.tool_surface_bytes);
    check bool "Skill bodies are measured but never eager" true
      (surface.skill_body_bytes > 0);
    check bool "Skill discovery total is measured" true
      (surface.skill_discovery_bytes > 0);
    check int "Skill eager total remains exact" 0 surface.skill_eager_body_bytes;
    let json = Keeper_effective_tool_surface.to_yojson (Available surface) in
    let profile_reasons =
      Yojson.Safe.Util.(member "skill_profiles" json |> to_list)
      |> List.map (fun profile ->
           Yojson.Safe.Util.(member "load_reasons" profile |> to_list)
           |> List.map (fun reason ->
                Yojson.Safe.Util.(member "kind" reason |> to_string)))
    in
    check (list (list string))
      "exact load reasons distinguish Task and catalog default"
      [ [ "task"; "catalog_default" ]; [ "catalog_default" ] ]
      profile_reasons;
    (match surface.skill_profiles with
     | [ instruction; composition ] ->
       check string "instruction activation" "on_demand" instruction.execution;
       check int "instruction eager bytes" 0 instruction.eager_body_bytes;
       check (option int) "shared instruction schema is not double-counted" None
         instruction.tool_schema_bytes;
       check string "composition execution" "async" composition.execution;
       check int "composition nodes" 2 composition.node_count;
       check int "one concurrent batch" 1 composition.batch_count;
       check int "actual parallel width" 2 composition.max_parallelism;
       check (option bool) "async plan is statically read-only" (Some true)
         composition.statically_read_only;
       check bool "composition schema bytes are exact and positive" true
         (Option.value ~default:0 composition.tool_schema_bytes > 0)
     | profiles -> failf "expected two Skill profiles, got %d" (List.length profiles));
    check (option int) "resource bound follows frozen snapshot" (Some 65536)
      surface.skill_resource_read_max_bytes;
    check string
      "surface names the frozen Skill snapshot"
      (Skill_catalog_snapshot.snapshot_revision snapshot
       |> Skill_catalog_snapshot.snapshot_revision_to_string)
      (Skill_catalog_snapshot.snapshot_revision_to_string
         surface.skill_snapshot_revision);
    let instruction_entries = instruction_entries snapshot [ task_reference ] in
    let tool =
      Keeper_tool_composition_surface.instruction_skill_schema_tool
        ~instruction_skills:instruction_entries
    in
    (
       check string "projection carries the exact Available list"
         (Keeper_tool_composition_surface.For_testing.instruction_skill_description
            instruction_entries)
         tool.schema.description;
       let input_schema =
         match tool.schema.input_schema with
         | Some input_schema -> input_schema
         | None -> fail "keeper_skill omitted its required input schema"
       in
       let required =
         input_schema
         |> Yojson.Safe.Util.member "required"
         |> Yojson.Safe.Util.to_list
         |> List.map Yojson.Safe.Util.to_string
       in
       check (list string) "schema requires the canonical exact reference"
         [ "identity"; "content_revision" ] required;
       check bool "name-only input is absent" true
         (input_schema
          |> Yojson.Safe.Util.member "properties"
          |> Yojson.Safe.Util.member "name"
          = `Null))
;;


let test_external_composition_preserves_snapshot_provenance () =
  ignore (Masc_test_deps.init_unified_tool_registry ());
  match
    Keeper_effective_tool_surface.For_testing.project
      ~keeper_name:"fixture"
      ~runtime_id:"fixture.runtime"
      ~official_client_kind:"codex"
      ~tool_delivery:Keeper_effective_tool_surface.Tools_delivered
      ~native_posture:None
      ~skill_names:None
      ~current_task_id:None
      ~skills_left_out:[]
      ~task_skill_references:[]
      ~task_selection:None
      ~skill_snapshot:(configured_external_skill_snapshot ())
  with
  | Error error -> fail (Keeper_task_skill_turn.error_to_string error)
  | Ok surface ->
    let provenance =
      List.find_map
        (fun (tool : Keeper_effective_tool_surface.tool) ->
           match tool.origin with
           | Keeper_effective_tool_surface.Composition_skill
               { provenance = Some provenance } -> Some provenance
           | Composition_skill { provenance = None }
           | Descriptor
           | Instruction_skill
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


let test_instruction_skill_without_read_is_admitted () =
  ignore (Masc_test_deps.init_unified_tool_registry ());
  let snapshot = skill_snapshot () in
  let task_reference = reference_by_name snapshot "guide" in
  match
    project
      ~snapshot
      ~task_skill_references:[ task_reference ]
      ~native_posture:Runtime_native_tools.Native_read
      ()
  with
  | Error error -> fail (Keeper_task_skill_turn.error_to_string error)
  | Ok surface ->
    check string
      "exact instruction reference is admitted"
      (Skill_reference.list_to_yojson [ task_reference ] |> Yojson.Safe.to_string)
      (Skill_reference.list_to_yojson surface.instruction_skills
       |> Yojson.Safe.to_string);
    check bool "dedicated reader is present" true
      (List.exists (String.equal "keeper_skill") (names surface))
;;

let test_instruction_description_changes_digest () =
  ignore (Masc_test_deps.init_unified_tool_registry ());
  let project_description description =
    let snapshot = skill_snapshot_with_description description in
    project
      ~snapshot
      ~task_skill_references:[ reference_by_name snapshot "guide" ]
      ~native_posture:Runtime_native_tools.Native_read
      ()
  in
  match project_description "first contract", project_description "second contract" with
  | Ok left, Ok right ->
    check bool "instruction description participates in digest" true
      (left.tool_surface_sha256 <> right.tool_surface_sha256)
  | Error error, _ | _, Error error ->
    fail (Keeper_task_skill_turn.error_to_string error)
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
       let snapshot = skill_snapshot () in
       let guide_reference = reference_by_name snapshot "guide" in
       let created =
         match
           Workspace.add_task_with_result
             ~created_by:"fixture"
             ~skills:[ guide_reference ]
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
                ; "trace_id", `String "skill-admission-trace"
                ])
         with
         | Ok meta ->
           { meta with current_task_id }
         | Error detail -> fail detail
       in
       match
         validate_observed_task_skills
           ~config
           ~meta
           ~skill_snapshot:(skill_snapshot ())
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
       let snapshot = skill_snapshot () in
       let guide_reference = reference_by_name snapshot "guide" in
       let agent_name = "skill-held" in
       let add ~skills ~title =
         match
           Workspace.add_task_with_result
             ~created_by:"fixture" ~skills config ~title ~priority:3 ~description:"fixture"
         with
         | Ok created -> created.task_id
         | Error error -> fail (Workspace.add_task_error_to_string error)
       in
       let task_a = add ~skills:[] ~title:"plain work" in
       let task_b = add ~skills:[ guide_reference ] ~title:"skill work" in
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
       let meta () =
         match
           Masc_test_deps.meta_of_json_fixture
             (`Assoc
                [ "name", `String "skill-held"
                ; "trace_id", `String "skill-held-trace"
                ])
         with
         | Ok meta -> { meta with current_task_id }
         | Error detail -> fail detail
       in
       (match
          validate_observed_task_skills
            ~config
            ~meta:(meta ())
            ~skill_snapshot:
              (Skill_catalog_snapshot.config_unreadable ~detail:"fixture")
        with
        | Ok () -> fail "held task's missing skill was not inspected"
        | Error error ->
          let rendered = Agent_core.Error.to_string error in
          check bool "the held exact skill is named" true
            (String_util.contains_substring rendered "guide"));
       (match
          validate_observed_task_skills
            ~config ~meta:(meta ()) ~skill_snapshot:snapshot
        with
        | Ok () -> ()
        | Error error -> fail (Agent_core.Error.to_string error));
       (match
          resolve_observed_task_skills
            ~config
            ~meta:(meta ())
            ~skill_snapshot:snapshot
        with
        | Error error -> fail (Agent_core.Error.to_string error)
        | Ok selection ->
          check int "held exact ref reaches executable selection" 1
            (List.length selection.selected);
          (match selection.selected with
           | [ selected ] ->
             check bool "held reference stays exact" true
               (Skill_reference.equal guide_reference selected.reference);
             check (list string) "held Task provenance stays attached" [ task_b ]
               selected.task_ids
           | _ -> fail "held exact selection cardinality changed");
          let changed = Workspace_backlog.read_backlog config in
          Workspace_backlog.write_backlog config
            { changed with
              tasks =
                List.map
                  (fun (task : Masc_domain.task) ->
                     if String.equal task.id task_b then { task with skills = [] }
                     else task)
                  changed.tasks
            };
          (match
             Keeper_effective_tool_surface.For_testing.project
               ~keeper_name:"skill-held"
               ~runtime_id:"fixture.runtime"
               ~official_client_kind:"agent_core"
               ~tool_delivery:Keeper_effective_tool_surface.Tools_delivered
               ~native_posture:None
               ~skill_names:None
               ~current_task_id:(Some task_a)
               ~skills_left_out:[]
               ~task_skill_references:[]
               ~task_selection:(Some selection)
               ~skill_snapshot:snapshot
           with
           | Error error -> fail (Keeper_task_skill_turn.error_to_string error)
           | Ok surface ->
             check bool "bundle keeps prompt-phase held exact ref" true
               (List.exists
                  (Skill_reference.equal guide_reference)
                  surface.instruction_skills);
             let global, _ = Keeper_skill_catalog.of_snapshot snapshot in
             let projection =
               Keeper_skill_catalog.project_turn
                 ~names:None ~global ~task:(Keeper_task_skill_turn.skills selection)
             in
             let prompt_instruction_refs =
               Keeper_skill_catalog.exact_surfaces
                 projection ~task:(Keeper_task_skill_turn.skills selection)
               |> List.filter_map
                    (fun (row : Keeper_skill_catalog.exact_surface) ->
                       match row.availability with
                       | Keeper_skill_catalog.Instruction_tool -> Some row.reference
                       | Keeper_skill_catalog.Composition_tool _
                       | Keeper_skill_catalog.Exact_unavailable _ -> None)
             in
             check string "frozen prompt surface equals executable bundle"
               (Skill_reference.list_to_yojson prompt_instruction_refs
                |> Yojson.Safe.to_string)
               (Skill_reference.list_to_yojson surface.instruction_skills
                |> Yojson.Safe.to_string)));
       match
         validate_observed_task_skills
           ~config ~meta:(meta ()) ~skill_snapshot:snapshot
       with
       | Ok () -> ()
       | Error error -> fail (Agent_core.Error.to_string error))
;;

(* A document the catalog could not read reaches the surface that answers
   "what can this Keeper call". Left off it, the skill is simply absent, and
   absence with nothing beside it reads as a skill nobody wrote rather than
   one that did not load -- which is how yesterday's outage looked from the
   operator's side once it stopped being fatal. *)
let test_left_out_skills_reach_the_surface () =
  match
    project
      ~skills_left_out:[ "not-a-policy: skill \"not-a-policy\": unsupported" ]
      ~skill_names:None
      ~task_skill_references:[]
      ~native_posture:Runtime_native_tools.Native_read
      ()
  with
  | Error error -> Alcotest.fail (Keeper_task_skill_turn.error_to_string error)
  | Ok surface ->
    Alcotest.(check (list string))
      "the surface carries what was left out"
      [ "not-a-policy: skill \"not-a-policy\": unsupported" ]
      surface.Keeper_effective_tool_surface.skills_left_out;
    (* And a workspace with nothing left out gains nothing: a row drawn on
       every turn stops being read. *)
    (match
       project ~task_skill_references:[]
         ~native_posture:Runtime_native_tools.Native_read ()
     with
     | Error error -> Alcotest.fail (Keeper_task_skill_turn.error_to_string error)
     | Ok clean ->
       Alcotest.(check (list string)) "and says nothing when there is nothing"
         [] clean.Keeper_effective_tool_surface.skills_left_out)
;;

let test_global_instruction_is_present_in_receipt () =
  ignore (Masc_test_deps.init_unified_tool_registry ());
  let snapshot = skill_snapshot () in
  match
    project
      ~snapshot
      ~task_skill_references:[]
      ~native_posture:Runtime_native_tools.Native_read
      ()
  with
  | Error error -> fail (Keeper_task_skill_turn.error_to_string error)
  | Ok surface ->
    check string
      "global instruction receipt is exact"
      (Skill_reference.list_to_yojson
         [ reference_by_name snapshot "guide" ]
       |> Yojson.Safe.to_string)
      (Skill_reference.list_to_yojson surface.instruction_skills
      |> Yojson.Safe.to_string)
;;

let test_runtime_capability_suppression_is_explicit_and_empty () =
  ignore (Masc_test_deps.init_unified_tool_registry ());
  let skill_snapshot = skill_snapshot () in
  match
    Keeper_effective_tool_surface.For_testing.project
      ~keeper_name:"fixture"
      ~runtime_id:"fixture.runtime"
      ~official_client_kind:"agent_core"
      ~tool_delivery:
        Keeper_effective_tool_surface.Tools_suppressed_runtime_unsupported
      ~native_posture:None
      ~skill_names:None
      ~current_task_id:(Some "task-001")
      ~skills_left_out:[]
      ~task_skill_references:[ reference_by_name skill_snapshot "guide" ]
      ~task_selection:None
      ~skill_snapshot
  with
  | Error error -> fail (Keeper_task_skill_turn.error_to_string error)
  | Ok surface ->
    check (list string) "no tool reaches the model" [] (names surface);
    check int "instruction tool is not readable" 0
      (List.length surface.instruction_skills);
    check int "composition tools are not callable" 0
      (List.length surface.composition_skills);
    let open Yojson.Safe.Util in
    let delivery =
      Keeper_effective_tool_surface.to_yojson (Available surface)
      |> member "tool_delivery"
    in
    check string "typed status" "suppressed"
      (delivery |> member "status" |> to_string);
    check string "typed reason" "runtime_tools_unsupported"
      (delivery |> member "reason" |> to_string)
;;

(* #31078 review P1: the earlier freeze assertions stayed green when [project]
   was mutated to ignore [task_selection], because the fixture skill also sat
   in the global effective catalog and [project_turn] always bundles the
   global instruction skills. A shadowed exact reference closes that
   blindness: earlier-source-wins keeps only the primary "guide" on the
   effective catalog, so the shadow source's revision can reach the bundle
   through the frozen selection alone. The empty-selection control pins that
   the shadowed revision has no other route in — a projection that re-resolves
   or drops the selection fails the first check. *)
let shadowed_guide_snapshot () =
  let config_text =
    "[skills]\n\
     resource-read-max-bytes = 65536\n\
     [[skills.sources]]\n\
     id = \"primary-catalog\"\n\
     anchor = \"base-path\"\n\
     path = \"skills\"\n\
     access = \"read-only\"\n\
     [[skills.sources]]\n\
     id = \"shadow-catalog\"\n\
     anchor = \"base-path\"\n\
     path = \"shadow-skills\"\n\
     access = \"read-only\"\n"
  in
  let config =
    match Skill_source_config.parse_text config_text with
    | Ok config -> config
    | Error _ -> fail "shadowed guide fixture config was rejected"
  in
  let primary, shadow =
    match config.Skill_source_config.sources with
    | [ primary; shadow ] -> primary, shadow
    | _ -> fail "shadowed guide fixture did not contain exactly two sources"
  in
  let scan source path documents : Skill_catalog_snapshot.source_scan =
    { source = Skill_source_config.resolve ~base_path:"/workspace" ~user_home:None source
    ; observation =
        Skill_catalog_snapshot.Source_ready
          { resolved_path = path; candidates = List.length documents }
    ; candidates =
        List.map
          (fun (directory, source_text) ->
             Skill_catalog_snapshot.Candidate_document { directory; source_text })
          documents
    }
  in
  let snapshot =
    match
      Skill_catalog_snapshot.configured
        ~config
        [ scan primary "skills" [ "guide", instruction_skill "guide" ]
        ; scan
            shadow
            "shadow-skills"
            [ ( "guide"
              , instruction_skill
                  ~description:"Shadowed revision of the guide."
                  "guide" )
            ]
        ]
    with
    | Ok snapshot -> snapshot
    | Error _ -> fail "shadowed guide fixture snapshot was rejected"
  in
  let package_id =
    match Skill_reference.package_id_of_directory "guide" with
    | Ok value -> value
    | Error _ -> fail "shadowed guide fixture package id was rejected"
  in
  let identity =
    Skill_reference.make_identity
      ~source_id:shadow.Skill_source_config.id
      ~package_id
      ~name:"guide"
  in
  match Skill_catalog_snapshot.find_exact snapshot identity with
  | Some entry -> snapshot, Skill_catalog_snapshot.entry_reference entry
  | None -> fail "shadowed guide entry is absent from the snapshot"
;;

let test_frozen_selection_carries_the_shadowed_exact_reference () =
  let snapshot, shadowed_reference = shadowed_guide_snapshot () in
  let selection =
    match
      Keeper_task_skill_turn.resolve_for_task
        ~snapshot
        ~task_id:"task-shadow"
        [ shadowed_reference ]
    with
    | Ok selection -> selection
    | Error error -> fail (Keeper_task_skill_turn.error_to_string error)
  in
  let project ~task_selection =
    Keeper_effective_tool_surface.For_testing.project
      ~keeper_name:"skill-shadow"
      ~runtime_id:"fixture.runtime"
      ~official_client_kind:"agent_core"
      ~tool_delivery:Keeper_effective_tool_surface.Tools_delivered
      ~native_posture:None
      ~skill_names:None
      ~current_task_id:None
      ~skills_left_out:[]
      ~task_skill_references:[]
      ~task_selection
      ~skill_snapshot:snapshot
  in
  (match project ~task_selection:(Some selection) with
   | Error error -> fail (Keeper_task_skill_turn.error_to_string error)
   | Ok surface ->
     check bool "frozen selection carries the shadowed exact revision" true
       (List.exists
          (Skill_reference.equal shadowed_reference)
          surface.Keeper_effective_tool_surface.instruction_skills));
  match project ~task_selection:(Some Keeper_task_skill_turn.empty) with
  | Error error -> fail (Keeper_task_skill_turn.error_to_string error)
  | Ok control ->
    check bool
      "the shadowed revision has no route besides the frozen selection"
      false
      (List.exists
         (Skill_reference.equal shadowed_reference)
         control.Keeper_effective_tool_surface.instruction_skills)
;;

let () =
  Alcotest.run
    "keeper effective tool surface"
    [ ( "projection"
      , [ test_case "names equal turn setup authority" `Quick
            test_projection_names_equal_turn_surface_authority
        ; test_case "Skill names filter Task and expose unavailable" `Quick
            test_skill_name_selection_is_structured_and_filters_task
        ; test_case
            "external composition preserves snapshot provenance"
            `Quick
            test_external_composition_preserves_snapshot_provenance
        ; test_case "instruction skill does not require Read" `Quick
            test_instruction_skill_without_read_is_admitted
        ; test_case "left out skills reach the surface" `Quick
            test_left_out_skills_reach_the_surface
        ; test_case "instruction description changes digest" `Quick
            test_instruction_description_changes_digest
        ; test_case "turn admission uses dedicated instruction reader" `Quick
            test_turn_admission_uses_dedicated_instruction_reader
        ; test_case "turn admission covers held tasks beyond the current one" `Quick
            test_turn_admission_covers_held_tasks_beyond_current
        ; test_case "global instruction is present in receipt" `Quick
            test_global_instruction_is_present_in_receipt
        ; test_case "runtime capability suppression is explicit and empty" `Quick
            test_runtime_capability_suppression_is_explicit_and_empty
        ; test_case "frozen selection carries the shadowed exact reference" `Quick
            test_frozen_selection_carries_the_shadowed_exact_reference
        ] )
    ]
;;
