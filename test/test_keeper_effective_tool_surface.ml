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
id = "lane"
tool = "keeper_lane_status"
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
      "[skills]\nresource-read-max-bytes = 16384\n[[skills.sources]]\nid = %S\nanchor = %S\npath = %S\naccess = \"read-only\"\n"
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
         Keeper_instruction_skill.instruction_skill
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
    ~tool_deny:[]
    ~sandbox_profile:Masc.Keeper_types_profile.Docker
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
    | Error error -> fail (Keeper_effective_tool_surface.projection_error_to_string error)
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
    | Error error -> fail (Keeper_effective_tool_surface.projection_error_to_string error)
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
  | Error error -> fail (Keeper_effective_tool_surface.projection_error_to_string error)
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
    check bool "official client digest exists" true
      (Option.is_some surface.tool_surface_sha256);
    check bool "whole tool surface bytes are measured" true
      (surface.tool_surface_bytes > 0);
    check bool "Skill tool bytes are a strict subset" true
      (surface.skill_tool_surface_bytes > 0
       && surface.skill_tool_surface_bytes < surface.tool_surface_bytes);
    check bool "Skill bodies are measured" true
      (surface.skill_body_bytes > 0);
    check bool "Skill discovery total is measured" true
      (surface.skill_discovery_bytes > 0);
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
      [ [ "task"; "catalog_default" ] ]
      profile_reasons;
    (match surface.skill_profiles with
     | [ instruction ] ->
       check string "instruction activation" "on_demand"
         (Keeper_skill_observability.execution_label instruction.surface);
       check (option int) "shared instruction schema is not double-counted" None
         instruction.tool_schema_bytes
     | profiles -> failf "expected one instruction Skill profile, got %d" (List.length profiles));
    check (option int) "resource bound follows frozen snapshot" (Some 16384)
      surface.skill_resource_read_max_bytes;
    check string
      "surface names the frozen Skill snapshot"
      (Skill_catalog_snapshot.snapshot_revision snapshot
       |> Skill_catalog_snapshot.snapshot_revision_to_string)
      (Skill_catalog_snapshot.snapshot_revision_to_string
         surface.skill_snapshot_revision);
    let instruction_entries = instruction_entries snapshot [ task_reference ] in
    let tool =
      Keeper_instruction_skill.instruction_skill_schema_tool
        ~instruction_skills:instruction_entries |> Result.get_ok
    in
    (
       check string "projection carries the exact Available list"
         (Keeper_instruction_skill.instruction_skill_description
            instruction_entries)
         tool.schema.description;
       (* The line carries what a call needs and stops there. The revision is
          the larger half of a reference and is no longer asked for, so a line
          still printing it would be spending the surface's bytes on a value
          the tool ignores. *)
       let contains needle text =
         let needle_length = String.length needle in
         let rec search index =
           index + needle_length <= String.length text
           && (String.equal (String.sub text index needle_length) needle
               || search (index + 1))
         in
         search 0
       in
       check bool "the Available line names the identity" true
         (contains
            (Skill_reference.identity_to_yojson task_reference.Skill_reference.identity
             |> Yojson.Safe.to_string)
            tool.schema.description);
       check bool "the Available line drops the revision" false
         (contains
            (Skill_reference.content_revision_to_string
               task_reference.Skill_reference.content_revision)
            tool.schema.description);
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
       (* The identity is required; the revision is not. Requiring it meant the
          caller had to type a 64-hex digest nothing outside this tool's own
          Available list hands them, and 0 of 292 recorded Tasks ever named a
          Skill. Omitted, the turn's frozen list decides — the same list a
          spelled-out revision is matched against, so dropping it reaches
          nothing new. *)
       check (list string) "identity is required, the revision is not"
         [ "identity" ] required;
       check bool "the revision is still an accepted field" true
         (input_schema
          |> Yojson.Safe.Util.member "properties"
          |> Yojson.Safe.Util.member "content_revision"
          <> `Null);
       (* A bare name is still not the input shape: source and package stay
          inside [identity], which is what keeps two sources' same-named Skills
          separable at all. *)
       check bool "name-only input is absent" true
         (input_schema
          |> Yojson.Safe.Util.member "properties"
          |> Yojson.Safe.Util.member "name"
          = `Null))
;;




(* Verify that the surface's JSON serialization writes the expected origin kind
   and skill provenance for every projected tool. *)
let test_the_tui_reads_the_origin_of_every_tool_this_surface_writes () =
  ignore (Masc_test_deps.init_unified_tool_registry ());
  let surface =
    match
      Keeper_effective_tool_surface.For_testing.project
        ~keeper_name:"fixture"
        ~runtime_id:"fixture.runtime"
        ~official_client_kind:"codex"
        ~tool_delivery:Keeper_effective_tool_surface.Tools_delivered
        ~tool_deny:[]
        ~sandbox_profile:Masc.Keeper_types_profile.Docker
        ~native_posture:None
        ~skill_names:None
        ~current_task_id:None
        ~skills_left_out:[]
        ~task_skill_references:[]
        ~task_selection:None
        ~skill_snapshot:(configured_external_skill_snapshot ())
    with
    | Ok surface -> surface
    | Error error -> fail (Keeper_effective_tool_surface.projection_error_to_string error)
  in
  let expected =
    List.map
      (fun (tool : Keeper_effective_tool_surface.tool) ->
         ( tool.name
         , match tool.origin with
           | Keeper_effective_tool_surface.Descriptor -> ("descriptor", None)
           | Instruction_skill -> ("instruction_skill", None)
           | Composition_skill { provenance = Some provenance } ->
             ( "composition_skill"
             , Some (Skill_source_config.source_id_to_string provenance.identity.source_id) )
           | Composition_skill { provenance = None } -> ("composition_skill", None)
           | Composition_control -> ("composition_control", None) ))
      surface.tools
  in
  check bool "the fixture carries a descriptor" true
    (List.exists (fun (_, (k, _)) -> String.equal k "descriptor") expected);
  let wire = Keeper_effective_tool_surface.to_yojson (Available surface) in
  let open Yojson.Safe.Util in
  let actual =
    wire |> member "tools" |> to_list
    |> List.map (fun row ->
      let name = row |> member "name" |> to_string in
      let origin = member "origin" row in
      let kind = origin |> member "kind" |> to_string in
      let src =
        match member "skill_provenance" origin with
        | `Assoc _ as prov ->
          Some (prov |> member "identity" |> member "source_id" |> to_string)
        | _ -> None
      in
      (name, (kind, src)))
  in
  check bool "every tool serializes to the exact origin written by the surface" true
    (actual = expected)

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
  | Error error -> fail (Keeper_effective_tool_surface.projection_error_to_string error)
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
    fail (Keeper_effective_tool_surface.projection_error_to_string error)
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
       (* A snapshot whose configuration is unreadable holds no entries, so a
          held Task's pin is not known to be deleted. Resolution fails with
          the typed configuration error rather than listing the pin as an
          unavailable Skill and letting the turn run without it. *)
       (match
          resolve_observed_task_skills
            ~config
            ~meta:(meta ())
            ~skill_snapshot:
              (Skill_catalog_snapshot.config_unreadable ~detail:"fixture")
        with
        | Ok _ -> fail "an unreadable Skill configuration did not stop resolution"
        | Error error ->
          (match Keeper_task_skill_turn.of_core_error error with
           | Some (Keeper_task_skill_turn.Skill_config_unreadable { detail }) ->
             check string "the unreadable detail is carried" "fixture" detail
           | Some _ | None -> fail "the failure is not the typed unreadable error"));
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
                              ~tool_deny:[]
                              ~sandbox_profile:Masc.Keeper_types_profile.Docker
~native_posture:None
               ~skill_names:None
               ~current_task_id:(Some task_a)
               ~skills_left_out:[]
               ~task_skill_references:[]
               ~task_selection:(Some selection)
               ~skill_snapshot:snapshot
           with
           | Error error -> fail (Keeper_effective_tool_surface.projection_error_to_string error)
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
  | Error error -> Alcotest.fail (Keeper_effective_tool_surface.projection_error_to_string error)
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
     | Error error -> Alcotest.fail (Keeper_effective_tool_surface.projection_error_to_string error)
     | Ok clean ->
       Alcotest.(check (list string)) "and says nothing when there is nothing"
         [] clean.Keeper_effective_tool_surface.skills_left_out)
;;

(* A Task that pins a Skill the snapshot holds but the catalog cannot project
   (here a blank instruction body) still gets a surface. The pinned Skill is a
   typed row with its Task and catalog error, the renderers' left-out list
   names it, and the wire carries the row: a pinned Skill with no row reads as
   one nobody pinned. Meanwhile a valid >16 KiB Skill body is projected cleanly
   without refusal. *)
let test_unprojectable_task_skill_is_a_typed_row () =
  let oversized =
    Printf.sprintf
      "---\nname: huge\ndescription: Large valid fixture.\n---\n\n%s"
      (String.make (Common.max_tool_result_wire_bytes + 1) 'x')
  in
  let blank = "---\nname: blank\ndescription: Blank fixture.\n---\n\n   " in
  let snapshot =
    configured_snapshot
      ~source_id:"fixture-catalog"
      ~anchor:"base-path"
      ~path:"skills"
      [ "guide", instruction_skill "guide"; "huge", oversized; "blank", blank ]
  in
  let huge = reference_by_name snapshot "huge" in
  let blank_ref = reference_by_name snapshot "blank" in
  match
    project
      ~snapshot
      ~task_skill_references:[ huge; blank_ref ]
      ~native_posture:Runtime_native_tools.Native_read
      ()
  with
  | Error error -> fail (Keeper_effective_tool_surface.projection_error_to_string error)
  | Ok surface ->
    let row =
      match surface.Keeper_effective_tool_surface.unavailable_task_skills with
      | [ row ] -> row
      | rows -> failf "expected one unavailable Task Skill row, got %d" (List.length rows)
    in
    check bool "the row is the pinned blank reference" true
      (Skill_reference.equal row.Keeper_task_skill_turn.reference blank_ref);
    check (list string) "the row keeps the Task that pinned it" [ "task-001" ] row.task_ids;
    check bool "the row carries the typed blank-body refusal" true
      (match row.reason with
       | Keeper_task_skill_turn.Catalog_entry_unprojectable
           (Keeper_skill_catalog.Body_blank { skill = "blank" }) ->
         true
       | Catalog_entry_unprojectable _ | Pin_unresolved _ -> false);
    check (list string) "the left-out list the renderers draw names the row"
      [ Printf.sprintf "%s: %s"
          (Skill_catalog_snapshot.identity_to_yojson blank_ref.Skill_reference.identity
           |> Yojson.Safe.to_string)
          (Keeper_task_skill_turn.unavailable_reason_to_string row.reason)
      ; Keeper_task_skill_turn.unprojectable_to_string row
      ]
      surface.skills_left_out;
    let open Yojson.Safe.Util in
    (match
       Keeper_effective_tool_surface.to_yojson (Keeper_effective_tool_surface.Available surface)
       |> member "unavailable_task_skills"
     with
     | `List [ wire ] ->
       check string "the wire row names the catalog error code"
         (Keeper_task_skill_turn.unavailable_reason_code row.reason)
         (wire |> member "error_code" |> to_string);
       check (list string) "the wire row names the Task" [ "task-001" ]
         (wire |> member "task_ids" |> to_list |> List.map to_string)
     | wire ->
       failf "unavailable_task_skills on the wire: %s" (Yojson.Safe.to_string wire))
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
  | Error error -> fail (Keeper_effective_tool_surface.projection_error_to_string error)
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
            ~tool_deny:[]
            ~sandbox_profile:Masc.Keeper_types_profile.Docker
~native_posture:None
      ~skill_names:None
      ~current_task_id:(Some "task-001")
      ~skills_left_out:[]
      ~task_skill_references:[ reference_by_name skill_snapshot "guide" ]
      ~task_selection:None
      ~skill_snapshot
  with
  | Error error -> fail (Keeper_effective_tool_surface.projection_error_to_string error)
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
     resource-read-max-bytes = 16384\n\
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
  Eio_main.run @@ fun _ ->
  let module O = Keeper_skill_preparation_observation in
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
  let project ~task_skill_references ~task_selection =
    Keeper_effective_tool_surface.For_testing.project
      ~keeper_name:"skill-shadow"
      ~runtime_id:"fixture.runtime"
      ~official_client_kind:"agent_core"
      ~tool_delivery:Keeper_effective_tool_surface.Tools_delivered
            ~tool_deny:[]
            ~sandbox_profile:Masc.Keeper_types_profile.Docker
~native_posture:None
      ~skill_names:None
      ~current_task_id:None
      ~skills_left_out:[]
      ~task_skill_references
      ~task_selection
      ~skill_snapshot:snapshot
  in
  let frozen = match project ~task_skill_references:[] ~task_selection:(Some selection) with
   | Error error -> fail (Keeper_effective_tool_surface.projection_error_to_string error)
   | Ok surface ->
     check bool "frozen selection carries the shadowed exact revision" true
       (List.exists
          (Skill_reference.equal shadowed_reference)
          surface.Keeper_effective_tool_surface.instruction_skills);
     surface in
  let reports = ref [] in
  (match O.capture_result ~on_report:(fun report -> reports := report :: !reports)
      (fun () -> project ~task_skill_references:[shadowed_reference] ~task_selection:None) with
   | Error error -> fail (Keeper_effective_tool_surface.projection_error_to_string error)
   | Ok fresh ->
     check (list string) "fresh exact references and supplied selection expose the same tools"
       (names frozen) (names fresh);
     check bool "fresh references retain the shadowed revision instead of a name winner" true
       (List.exists (Skill_reference.equal shadowed_reference) fresh.instruction_skills));
  let report = match !reports with [report] -> report | _ -> fail "one fresh surface report expected" in
  check bool "fresh effective surface reports its actual successful preparation" true
    (report.coverage=O.Fiber_capture && report.outcome=O.Returned);
  let retained = List.filter (fun (sample : O.sample) -> sample.component=O.Retained_turn_surface) report.samples in
  check int "one retained surface for the fresh effective projection" 1 (List.length retained);
  List.iter (fun (sample : O.sample) -> check bool "retained surface belongs to the exact source and completed access" true
    (sample.snapshot_revision=Skill_catalog_snapshot.snapshot_revision snapshot
     && sample.outcome=O.Returned && sample.decision=Some O.Reused)) retained;
  match project ~task_skill_references:[shadowed_reference]
      ~task_selection:(Some Keeper_task_skill_turn.empty) with
  | Error error -> fail (Keeper_effective_tool_surface.projection_error_to_string error)
  | Ok control ->
    check bool
      "supplied empty selection cannot borrow fresh references"
      false
      (List.exists
         (Skill_reference.equal shadowed_reference)
         control.Keeper_effective_tool_surface.instruction_skills)
;;

let addon_descriptor name =
  let tool = match Mcp_protocol.Mcp_types.tool_of_yojson
    (`Assoc [ "name", `String name;
              "inputSchema", `Assoc [ "type", `String "object" ] ]) with
    | Ok tool -> tool
    | Error detail -> fail detail in
  Keeper_lane_addon_descriptor.create
    (Lane_addon_tool_export.create
      ~owner:(Lane_addon_tool_export.create_owner ~instance_id:"composition-worker") ~tool)
;;

let test_addon_plan_preserves_factory_authority () =
  let module Plan = Keeper_tool_plan in
  let module Descriptor = Keeper_tool_descriptor in
  let canonical = addon_descriptor "fixture_machine_input" in
  let id = match Plan.Node_id.make "input" with
    | Ok id -> id | Error _ -> fail "invalid fixture node id" in
  let node = Plan.node ~id ~tool_name:canonical.public_name
    ~input:(Plan.Json_template.literal (`Assoc [])) () in
  (match Plan.create ~descriptors:[canonical] [node] with
   | Error error -> fail (Plan.error_to_string error)
   | Ok plan -> check bool "plan retains the frozen execution object" true
       (match Plan.descriptor plan id with Some found -> found == canonical | None -> false));
  List.iter (fun forged ->
    match Plan.create ~descriptors:[forged] [node] with
    | Error (Plan.Unknown_descriptor_id _) -> ()
    | Error error -> fail (Plan.error_to_string error)
    | Ok _ -> fail "copied Add-on authority was accepted")
    [ { canonical with Descriptor.execution = Descriptor.Ordinary Descriptor.Concurrent }
    ; { canonical with Descriptor.input_schema = `Assoc ["type", `String "string"] }
    ; { canonical with Descriptor.policy = { canonical.policy with readonly_of_input = (fun _ -> Some true) } }
    ];
  let collision = addon_descriptor "keeper_lane_status" in
  match Plan.create ~descriptors:[collision]
    [Plan.node ~id ~tool_name:collision.public_name
       ~input:(Plan.Json_template.literal (`Assoc [])) ()] with
  | Error (Plan.Duplicate_tool_name "keeper_lane_status") -> ()
  | Error error -> fail (Plan.error_to_string error)
  | Ok _ -> fail "Add-on shadowed a static name absent from the supplied subset"
;;

let[@inline never] unowned_addon_generation tool =
  let owner = Lane_addon_tool_export.create_owner ~instance_id:"same-fixture-id" in
  let export = Lane_addon_tool_export.create ~owner ~tool in
  let descriptor = Keeper_lane_addon_descriptor.create export in
  let owner_weak = Weak.create 1 and export_weak = Weak.create 1 and descriptor_weak = Weak.create 1 in
  Weak.set owner_weak 0 (Some owner);
  Weak.set export_weak 0 (Some export);
  Weak.set descriptor_weak 0 (Some descriptor);
  owner_weak,export_weak,descriptor_weak
;;

let test_addon_factory_ownership_survives_concurrency_and_releases_retired_inputs () =
  let tool = match Mcp_protocol.Mcp_types.tool_of_yojson
      (`Assoc ["name",`String "fixture_owned_machine";"inputSchema",`Assoc ["type",`String "object"]]) with
    | Ok tool -> tool | Error detail -> fail detail in
  let owner = Lane_addon_tool_export.create_owner ~instance_id:"same-fixture-id" in
  let ready = Semaphore.Counting.make 0 and start = Semaphore.Counting.make 0 in
  let build () =
    Semaphore.Counting.release ready;
    Semaphore.Counting.acquire start;
    Keeper_lane_addon_descriptor.create (Lane_addon_tool_export.create ~owner ~tool) in
  let left = Domain.spawn build and right = Domain.spawn build in
  Semaphore.Counting.acquire ready;
  Semaphore.Counting.acquire ready;
  Semaphore.Counting.release start;
  Semaphore.Counting.release start;
  let left = Domain.join left and right = Domain.join right in
  check bool "concurrent observations publish one canonical descriptor" true (left == right);
  let dead_owner,dead_export,dead_descriptor = unowned_addon_generation tool in
  Gc.full_major ();
  check bool "owned inputs survive collection of temporary key containers" true
    (left == Keeper_lane_addon_descriptor.create (Lane_addon_tool_export.create ~owner ~tool));
  check bool "unowned generation is not kept by its cached export" false (Weak.check dead_owner 0);
  check bool "unowned export is not kept by its cached descriptor" false (Weak.check dead_export 0);
  check bool "factory issuance does not retain a retired descriptor" false (Weak.check dead_descriptor 0)
;;

let test_addon_composition_diagnostics_follow_frozen_authority () =
  ignore (Masc_test_deps.init_unified_tool_registry ());
  let source = {|---
name: machine-command
description: Call the attached machine.
---
```toml composition
[[compositions]]
name = "machine-command"
description = "Call the attached machine."
execution = "inline"
[[compositions.nodes]]
id = "input"
tool = "fixture_machine_input"
[compositions.nodes.input]
kind = "literal"
value = {}
```
|} in
  let snapshot = configured_snapshot ~source_id:"machine-skills" ~anchor:"absolute"
    ~path:"/srv/machine-skills"
    [ "machine-command", source
    ; "snapshot", composition_skill ~name:"snapshot" ~execution:"async" ] in
  let project_with descriptors =
    let selection = match Keeper_task_skill_turn.bind_surface ~descriptors
      ~snapshot Keeper_task_skill_turn.empty with
      | Ok (selection,_) -> selection
      | Error error -> fail (Keeper_task_skill_turn.error_to_string error) in
    match Keeper_effective_tool_surface.For_testing.project
      ~keeper_name:"fixture" ~runtime_id:"fixture.runtime" ~skills_left_out:[]
      ~official_client_kind:"agent_core"
      ~tool_delivery:Keeper_effective_tool_surface.Tools_delivered
      ~native_posture:None ~tool_deny:[] ~sandbox_profile:Keeper_types_profile.Docker
      ~skill_names:None ~current_task_id:None ~task_skill_references:[]
      ~task_selection:(Some selection) ~skill_snapshot:snapshot with
    | Ok surface -> surface
    | Error error -> fail (Keeper_effective_tool_surface.projection_error_to_string error) in
  let static = Keeper_tool_descriptor.all_descriptors () in
  let attached = project_with (static @ [addon_descriptor "fixture_machine_input"]) in
  check bool "attached machine composition is callable" true
    (List.mem "keeper_compose_machine-command" (names attached));
  check bool "unrelated static composition remains callable with Add-on present" true
    (List.mem "keeper_compose_snapshot" (names attached));
  check (list string) "attached composition is not falsely reported unavailable" []
    attached.skills_left_out;
  let detached = project_with static in
  check bool "new detached projection omits machine composition" false
    (List.mem "keeper_compose_machine-command" (names detached));
  check bool "new detached projection reports missing tool" true
    (detached.skills_left_out <> []);
  check bool "frozen attached surface retains its original view" true
    (List.mem "keeper_compose_machine-command" (names attached))
;;

let test_masc_disabled_withholds_all_tools_skills_and_composition_controls () =
  let snapshot =
    configured_snapshot ~source_id:"masc-disabled-skills" ~anchor:"absolute"
      ~path:"/srv/masc-disabled-skills"
      [ "guide", instruction_skill "guide"
      ; "snap", composition_skill ~name:"snap" ~execution:"async"
      ]
  in
  let descriptors = Keeper_tool_descriptor.all_descriptors () in
  let selection =
    match Keeper_task_skill_turn.bind_surface ~descriptors ~snapshot Keeper_task_skill_turn.empty with
    | Ok (selection, _) -> selection
    | Error error -> fail (Keeper_task_skill_turn.error_to_string error)
  in
  let project_with masc_enabled =
    match
      Keeper_effective_tool_surface.For_testing.project_with_masc_enabled
        ~masc_enabled
        ~keeper_name:"person-keeper" ~runtime_id:"account.claude" ~skills_left_out:[]
        ~official_client_kind:"agent_core"
        ~tool_delivery:Keeper_effective_tool_surface.Tools_delivered
        ~native_posture:None ~tool_deny:[] ~sandbox_profile:Keeper_types_profile.Docker
        ~skill_names:None ~current_task_id:None ~task_skill_references:[]
        ~task_selection:(Some selection) ~skill_snapshot:snapshot
    with
    | Ok surface -> surface
    | Error error -> fail (Keeper_effective_tool_surface.projection_error_to_string error)
  in
  let enabled_surface = project_with true in
  check bool "masc_enabled=true marks masc_enabled true" true enabled_surface.masc_enabled;
  check bool "masc_enabled=true exposes host/composition tools" true (enabled_surface.tools <> []);
  let disabled_surface = project_with false in
  check bool "masc_enabled=false marks masc_enabled false" false disabled_surface.masc_enabled;
  check (list string) "masc_enabled=false exposes zero tools (no descriptors or async controls)" []
    (names disabled_surface);
  check int "masc_enabled=false emits zero instruction skills" 0
    (List.length disabled_surface.instruction_skills);
  check int "masc_enabled=false emits zero composition skills" 0
    (List.length disabled_surface.composition_skills);
  check int "masc_enabled=false yields zero tool_surface_bytes" 0 disabled_surface.tool_surface_bytes;
  check int "masc_enabled=false yields zero skill_tool_surface_bytes" 0
    disabled_surface.skill_tool_surface_bytes
;;

let () =
  Alcotest.run
    "keeper effective tool surface"
    [ ( "projection"
      , [ test_case "Add-on plans preserve factory authority" `Quick
            test_addon_plan_preserves_factory_authority
        ; test_case "Add-on factory ownership survives concurrency and releases retired inputs" `Quick
            test_addon_factory_ownership_survives_concurrency_and_releases_retired_inputs
        ; test_case "Add-on composition diagnostics follow frozen authority" `Quick
            test_addon_composition_diagnostics_follow_frozen_authority
        ; test_case "names equal turn setup authority" `Quick
            test_projection_names_equal_turn_surface_authority
        ; test_case "Skill names filter Task and expose unavailable" `Quick
            test_skill_name_selection_is_structured_and_filters_task
        ; test_case "unprojectable Task Skill is a typed row" `Quick
            test_unprojectable_task_skill_is_a_typed_row
        ; test_case "the TUI reads the origin of every tool this surface writes" `Quick
            test_the_tui_reads_the_origin_of_every_tool_this_surface_writes
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
        ; test_case "masc_enabled false withholds all descriptors, skills, and composition controls" `Quick
            test_masc_disabled_withholds_all_tools_skills_and_composition_controls
        
] )
    ]
;;
