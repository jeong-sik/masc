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

let configured_snapshot ~source_id ~anchor ~path documents =
  let config_text =
    Printf.sprintf
      "[skills]\nactivation-lifetime = \"session\"\nprecedence = \"earlier-source-wins\"\n[[skills.sources]]\nid = %S\nanchor = %S\npath = %S\naccess = \"read-only\"\n"
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

let skill_snapshot () =
  configured_snapshot
    ~source_id:"fixture-catalog"
    ~anchor:"base-path"
    ~path:"skills"
    [ "guide", instruction_skill "guide"
    ; "snapshot", composition_skill ~name:"snapshot" ~execution:"async"
    ]
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

let names (surface : Keeper_effective_tool_surface.t) =
  surface.tools
  |> List.map (fun (tool : Keeper_effective_tool_surface.tool) -> tool.name)
  |> List.sort String.compare
;;

let project ~tool_groups ~task_skill_references ~native_posture =
  let skill_snapshot = skill_snapshot () in
  Keeper_effective_tool_surface.For_testing.project
    ~keeper_name:"fixture"
    ~runtime_id:"fixture.runtime"
    ~official_client_kind:"codex"
    ~tool_delivery:Keeper_effective_tool_surface.Tools_delivered
    ~native_posture:(Some native_posture)
    ~tool_groups
    ~current_task_id:(Some "task-001")
    ~task_skill_references
    ~skill_snapshot
;;

let test_projection_names_equal_turn_surface_authority () =
  ignore (Masc_test_deps.init_unified_tool_registry ());
  match
    project
      ~tool_groups:None
      ~task_skill_references:[ reference_by_name (skill_snapshot ()) "guide" ]
      ~native_posture:Runtime_native_tools.Native_read
  with
  | Error error -> fail (Keeper_task_skill_turn.error_to_string error)
  | Ok surface ->
    let descriptors = Keeper_tool_descriptor.model_visible_descriptors () in
    let expected =
      Keeper_run_tools_setup.expected_model_tool_names
        ~skill_catalog:(Keeper_skill_catalog.of_snapshot (skill_snapshot ()) |> fst)
        ~model_visible_descriptors:descriptors
        ()
    in
    check (list string) "projection and turn setup names are identical"
      expected (names surface);
    check string
      "instruction skill is exact"
      (Skill_reference.list_to_yojson [ reference_by_name (skill_snapshot ()) "guide" ]
       |> Yojson.Safe.to_string)
      (Skill_reference.list_to_yojson surface.instruction_skills
       |> Yojson.Safe.to_string);
    check bool "composition provenance exists" true
      (List.exists
         (fun (tool : Keeper_effective_tool_surface.tool) ->
            match tool.origin with
            | Keeper_effective_tool_surface.Composition_skill _ -> true
            | _ -> false)
         surface.tools);
    check bool "official client digest exists" true
      (Option.is_some surface.tool_surface_sha256)
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
      ~tool_groups:None
      ~current_task_id:None
      ~task_skill_references:[]
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
           | Descriptor _
           | Instruction_skill
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
      ~task_skill_references:[]
      ~native_posture:Runtime_native_tools.Native_read
  in
  let narrow =
    project
      ~tool_groups:(Some [ "fs" ])
      ~task_skill_references:[]
      ~native_posture:Runtime_native_tools.Native_full
  in
  match all, narrow with
  | Ok left, Ok right ->
    check bool "effective names differ" true (names left <> names right);
    check bool "session digests differ" true
      (left.tool_surface_sha256 <> right.tool_surface_sha256)
  | Error error, _ | _, Error error ->
    fail (Keeper_task_skill_turn.error_to_string error)
;;

let test_instruction_skill_does_not_require_a_named_read_tool () =
  ignore (Masc_test_deps.init_unified_tool_registry ());
  match
    project
      ~tool_groups:(Some [ "board" ])
      ~task_skill_references:[ reference_by_name (skill_snapshot ()) "guide" ]
      ~native_posture:Runtime_native_tools.Native_read
  with
  | Error error -> fail (Keeper_task_skill_turn.error_to_string error)
  | Ok surface ->
    check int "instruction remains declared" 1
      (List.length surface.instruction_skills)
;;

let test_global_instruction_is_present_in_receipt () =
  ignore (Masc_test_deps.init_unified_tool_registry ());
  match
    project
      ~tool_groups:None
      ~task_skill_references:[]
      ~native_posture:Runtime_native_tools.Native_read
  with
  | Error error -> fail (Keeper_task_skill_turn.error_to_string error)
  | Ok surface ->
    check string
      "global instruction receipt is exact"
      (Skill_reference.list_to_yojson
         [ reference_by_name (skill_snapshot ()) "guide" ]
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
      ~tool_groups:None
      ~current_task_id:(Some "task-001")
      ~task_skill_references:[ reference_by_name skill_snapshot "guide" ]
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
        ; test_case "instruction Skill is independent of a named Read tool" `Quick
            test_instruction_skill_does_not_require_a_named_read_tool
        ; test_case "global instruction is present in receipt" `Quick
            test_global_instruction_is_present_in_receipt
        ; test_case "runtime capability suppression is explicit and empty" `Quick
            test_runtime_capability_suppression_is_explicit_and_empty
        ] )
    ]
;;
