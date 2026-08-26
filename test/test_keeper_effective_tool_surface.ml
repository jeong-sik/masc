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

let test_instruction_skill_does_not_require_a_named_read_tool () =
  ignore (Masc_test_deps.init_unified_tool_registry ());
  match
    project
      ~tool_groups:(Some [ "board" ])
      ~task_skill_names:[ "guide" ]
      ~native_posture:Runtime_native_tools.Native_read
  with
  | Error (_, detail) -> fail detail
  | Ok surface ->
    check (list string) "instruction remains declared" [ "guide" ]
      surface.instruction_skills
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
        ] )
    ]
;;
