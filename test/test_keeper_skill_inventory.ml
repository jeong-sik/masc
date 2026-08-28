open Alcotest

module Inventory = Masc.Keeper_skill_inventory
module Snapshot = Skill_catalog_snapshot

let config_text sources =
  "[skills]\nactivation-lifetime = \"session\"\nprecedence = \"earlier-source-wins\"\nresource-read-max-bytes = 65536\n"
  ^ sources
;;

let source_row ~id ~path =
  Printf.sprintf
    "[[skills.sources]]\nid = %S\nanchor = \"base-path\"\npath = %S\naccess = \"read-write\"\n"
    id
    path
;;

let parse_config text =
  match Skill_source_config.parse_text text with
  | Ok config -> config
  | Error diagnostics ->
    fail
      (String.concat
         "; "
         (List.map Skill_source_config.diagnostic_to_string diagnostics))
;;

let scans config candidates_by_source =
  List.map2
    (fun source candidates ->
       let resolved =
         Skill_source_config.resolve ~base_path:"/workspace" ~user_home:None source
       in
       let resolved_path =
         match resolved.Skill_source_config.resolution with
         | Resolved path -> path
         | Anchor_unavailable _ | Anchor_invalid _ | Path_rejected _ ->
           fail "fixture Skill source did not resolve"
       in
       { Snapshot.source = resolved
       ; observation = Source_ready { resolved_path; candidates = List.length candidates }
       ; candidates
       })
    config.Skill_source_config.sources
    candidates_by_source
;;

let snapshot config candidates_by_source =
  match Snapshot.configured ~config (scans config candidates_by_source) with
  | Ok snapshot -> snapshot
  | Error _ -> fail "fixture Skill snapshot was rejected"
;;

let candidate ~directory source_text =
  Snapshot.Candidate_document { directory; source_text }
;;

let instruction_document =
  {|---
name: release-checklist
description: Check the release before shipping.
---

# Release checklist

Read the diff.
|}
;;

let composition_document =
  {|---
name: clock-plan
description: Read the current time through a named plan.
---

```toml composition
[[compositions]]
name = "clock-plan"
description = "Read the current time through a named plan."
execution = "inline"

[[compositions.nodes]]
id = "clock"
tool = "keeper_time_now"
[compositions.nodes.input]
kind = "literal"
value = {}
```
|}
;;

let valid_items inventory =
  Inventory.items inventory
  |> List.filter_map (function
       | Inventory.Valid valid -> Some valid
       | Invalid _ -> None)
;;

let invalid_items inventory =
  Inventory.items inventory
  |> List.filter_map (function
       | Inventory.Invalid invalid -> Some invalid
       | Valid _ -> None)
;;

let valid_named name inventory =
  valid_items inventory
  |> List.find_opt (fun (valid : Inventory.valid_skill) ->
    String.equal valid.reference.identity.name name)
  |> function
  | Some valid -> valid
  | None -> failf "valid Skill %S missing from inventory" name
;;

let capability_surface ?(skill_names = None) ?(tool_groups = None) frozen =
  ignore (Masc_test_deps.init_unified_tool_registry ());
  let global_skill_catalog, diagnostics =
    Masc.Keeper_skill_catalog.of_snapshot frozen
  in
  check int "catalog diagnostics" 0 (List.length diagnostics);
  Masc.Keeper_capability_surface.create
    ~tool_groups
    ~skill_names
    ~global_skill_catalog
    ~skill_inventory:(Inventory.of_snapshot frozen)
    ~task_skills:[]
;;

let exact_capability_by_reference surface reference =
  Masc.Keeper_capability_surface.skill_capabilities surface
  |> List.find_opt (fun (capability : Masc.Keeper_capability_surface.skill_capability) ->
    match capability.identity with
    | Exact_skill (Inventory.Valid valid) ->
      Skill_reference.equal valid.reference reference
    | Exact_skill (Inventory.Invalid invalid) ->
      Option.exists (Skill_reference.equal reference) invalid.reference
    | Missing_configured_skill_name _ -> false)
  |> function
  | Some capability -> capability
  | None -> fail "exact Skill capability is absent"
;;

let search_candidates surface query =
  let documents =
    Masc.Keeper_capability_surface.candidates surface
    |> List.map (fun candidate ->
      Masc.Keeper_capability_search.
        { payload = candidate
        ; name = Masc.Keeper_capability_surface.candidate_name candidate
        ; description =
            Masc.Keeper_capability_surface.candidate_description candidate
        ; category = Masc.Keeper_capability_surface.candidate_category candidate
        ; invocation_name =
            Masc.Keeper_capability_surface.candidate_invocation_name candidate
        })
  in
  match Masc.Keeper_capability_search.search ~query documents with
  | Ok hits -> hits
  | Error error ->
    fail
      (Yojson.Safe.to_string
         (Masc.Keeper_capability_search.error_to_yojson error))
;;

let test_valid_instruction_and_exact_reference () =
  let config = parse_config (config_text (source_row ~id:"only" ~path:"skills")) in
  let frozen =
    snapshot config [ [ candidate ~directory:"release-checklist" instruction_document ] ]
  in
  let inventory = Inventory.of_snapshot frozen in
  let valid = valid_named "release-checklist" inventory in
  (match valid.kind with
   | Inventory.Instruction -> ()
   | Composition _ -> fail "instruction Skill was classified as a composition");
  (match valid.catalog_status with
   | Inventory.Effective -> ()
   | Shadowed -> fail "effective instruction Skill was marked shadowed");
  let entry =
    match Snapshot.entries frozen with
    | [ entry ] -> entry
    | entries -> failf "expected one snapshot entry, got %d" (List.length entries)
  in
  check bool
    "exact snapshot reference"
    true
    (Skill_reference.equal valid.reference (Snapshot.entry_reference entry));
  check
    string
    "exact source digest"
    (Skill_reference.content_revision_of_source_text instruction_document
     |> Skill_reference.content_revision_to_string)
    (valid.reference.content_revision |> Skill_reference.content_revision_to_string);
  check
    string
    "inventory names its frozen snapshot"
    (Snapshot.snapshot_revision frozen |> Snapshot.snapshot_revision_to_string)
    (Inventory.snapshot_revision inventory |> Snapshot.snapshot_revision_to_string)
;;

let test_valid_composition () =
  let config = parse_config (config_text (source_row ~id:"only" ~path:"skills")) in
  let inventory =
    snapshot config [ [ candidate ~directory:"clock-plan" composition_document ] ]
    |> Inventory.of_snapshot
  in
  let valid = valid_named "clock-plan" inventory in
  match valid.kind with
  | Inventory.Instruction -> fail "composition Skill was classified as instruction"
  | Composition entry ->
    check
      string
      "named composition tool"
      "keeper_compose_clock-plan"
      (Masc.Keeper_tool_composition_catalog.tool_name entry)
;;

let test_invalid_sibling_isolated_with_digest () =
  let config = parse_config (config_text (source_row ~id:"only" ~path:"skills")) in
  let malformed = "---\nname: broken\n---\nbody\n" in
  let inventory =
    snapshot
      config
      [ [ candidate ~directory:"broken" malformed
        ; candidate ~directory:"release-checklist" instruction_document
        ] ]
    |> Inventory.of_snapshot
  in
  ignore (valid_named "release-checklist" inventory);
  match invalid_items inventory with
  | [ invalid ] ->
    check string "invalid directory" "broken" invalid.directory;
    check bool "snapshot rejection has no fabricated reference" true
      (Option.is_none invalid.reference);
    (match invalid.error with
     | Inventory.Snapshot_rejection (Snapshot.Document_rejected diagnostics) ->
       check bool "typed parser diagnostics retained" true (diagnostics <> [])
     | Snapshot_rejection _ -> fail "invalid document has the wrong snapshot reason"
     | Catalog_rejection _ -> fail "invalid document bypassed snapshot rejection");
    (match invalid.content_revision with
     | None -> fail "readable invalid document lost its source digest"
     | Some revision ->
       check
         string
         "invalid source digest"
         (Skill_reference.content_revision_of_source_text malformed
          |> Skill_reference.content_revision_to_string)
         (Skill_reference.content_revision_to_string revision))
  | invalid -> failf "expected one invalid item, got %d" (List.length invalid)
;;

let test_catalog_status_tracks_source_precedence () =
  let config =
    parse_config
      (config_text
         (source_row ~id:"first" ~path:"first-skills"
          ^ source_row ~id:"second" ~path:"second-skills"))
  in
  let first =
    "---\nname: review\ndescription: First source.\n---\nfirst body\n"
  in
  let second =
    "---\nname: review\ndescription: Second source.\n---\nsecond body\n"
  in
  let inventory =
    snapshot
      config
      [ [ candidate ~directory:"review" first ]
      ; [ candidate ~directory:"review" second ]
      ]
    |> Inventory.of_snapshot
  in
  match valid_items inventory with
  | [ first; second ] ->
    check string "winner" "First source." first.description;
    check string "shadow" "Second source." second.description;
    (match first.catalog_status, second.catalog_status with
     | Inventory.Effective, Inventory.Shadowed -> ()
     | _ -> fail "inventory lost the typed source-precedence result");
    check bool
      "shadow keeps a different exact reference"
      false
      (Skill_reference.equal first.reference second.reference)
  | valid -> failf "expected two exact valid items, got %d" (List.length valid)
;;

let test_capability_surface_keeps_active_and_outside_tools () =
  let config = parse_config (config_text (source_row ~id:"only" ~path:"skills")) in
  let frozen = snapshot config [ [] ] in
  let surface = capability_surface ~tool_groups:(Some [ "board" ]) frozen in
  let capabilities = Masc.Keeper_capability_surface.tool_capabilities surface in
  check bool "restricted surface has active Tools" true
    (List.exists
       (fun (capability : Masc.Keeper_capability_surface.tool_capability) ->
          capability.availability = Masc.Keeper_capability_surface.Active)
       capabilities);
  check bool "restricted surface retains outside Tools" true
    (List.exists
       (fun (capability : Masc.Keeper_capability_surface.tool_capability) ->
          capability.availability
          = Masc.Keeper_capability_surface.Outside_tool_surface)
       capabilities)
;;

let test_empty_selection_makes_valid_skill_operator_only () =
  let config = parse_config (config_text (source_row ~id:"only" ~path:"skills")) in
  let frozen =
    snapshot config [ [ candidate ~directory:"release-checklist" instruction_document ] ]
  in
  let reference =
    match Snapshot.entries frozen with
    | [ entry ] -> Snapshot.entry_reference entry
    | _ -> fail "fixture entry count changed"
  in
  let capability =
    capability_surface ~skill_names:(Some []) frozen
    |> fun surface -> exact_capability_by_reference surface reference
  in
  check bool "empty selection is outside Skill surface" true
    (capability.availability = Masc.Keeper_capability_surface.Outside_skill_surface);
  check bool "outside Skill is operator-only" true
    (capability.exposure = Masc.Keeper_capability_surface.Operator_only)
;;

let test_shadowed_and_invalid_skills_keep_typed_availability () =
  let config =
    parse_config
      (config_text
         (source_row ~id:"first" ~path:"first-skills"
          ^ source_row ~id:"second" ~path:"second-skills"))
  in
  let first = "---\nname: review\ndescription: First source.\n---\nfirst body\n" in
  let second = "---\nname: review\ndescription: Second source.\n---\nsecond body\n" in
  let malformed = "---\nname: broken\n---\nbody\n" in
  let frozen =
    snapshot
      config
      [ [ candidate ~directory:"review" first; candidate ~directory:"broken" malformed ]
      ; [ candidate ~directory:"review" second ]
      ]
  in
  let inventory = Inventory.of_snapshot frozen in
  let shadow =
    match
      valid_items inventory
      |> List.find_opt (fun (valid : Inventory.valid_skill) ->
        valid.catalog_status = Inventory.Shadowed)
    with
    | Some shadow -> shadow
    | None -> fail "shadowed Skill is absent"
  in
  let shadow_capability =
    capability_surface frozen
    |> fun surface -> exact_capability_by_reference surface shadow.reference
  in
  check bool "shadow is not model invocable" true
    (shadow_capability.availability
     = Masc.Keeper_capability_surface.Not_model_invocable);
  let broken_capabilities =
    Masc.Keeper_capability_surface.skill_capabilities
      (capability_surface ~skill_names:(Some [ "broken" ]) frozen)
  in
  let invalid_capabilities =
    broken_capabilities
    |> List.filter (fun capability ->
      capability.Masc.Keeper_capability_surface.availability
      = Masc.Keeper_capability_surface.Invalid_definition)
  in
  check int "configured broken Skill has one invalid row" 1
    (List.length invalid_capabilities);
  let invalid_capability =
    match invalid_capabilities with
    | [ capability ] -> capability
    | _ -> fail "invalid Skill capability count changed after assertion"
  in
  check bool "invalid definition stays typed" true
    (invalid_capability.availability
     = Masc.Keeper_capability_surface.Invalid_definition);
  let missing_count =
    broken_capabilities
    |> List.filter (fun capability ->
      capability.Masc.Keeper_capability_surface.availability
      = Masc.Keeper_capability_surface.Missing_configured_skill)
    |> List.length
  in
  check int "invalid configured Skill is not double-reported missing" 0 missing_count
;;

let test_search_keeps_duplicate_exact_skill_references () =
  let config =
    parse_config
      (config_text
         (source_row ~id:"first" ~path:"first-skills"
          ^ source_row ~id:"second" ~path:"second-skills"))
  in
  let first = "---\nname: review\ndescription: Review first.\n---\nbody\n" in
  let second = "---\nname: review\ndescription: Review second.\n---\nbody\n" in
  let surface =
    snapshot
      config
      [ [ candidate ~directory:"review" first ]
      ; [ candidate ~directory:"review" second ]
      ]
    |> capability_surface
  in
  let references =
    search_candidates surface "review"
    |> List.filter_map (fun hit ->
      match hit.Masc.Keeper_capability_search.document.payload with
      | Masc.Keeper_capability_surface.Skill
          { identity = Exact_skill (Inventory.Valid valid); _ } ->
        Some valid.reference
      | Ordinary_tool _
      | Skill
          { identity = (Exact_skill (Inventory.Invalid _)
                       | Missing_configured_skill_name _)
          ; _
          } -> None)
  in
  check int "both same-name Skills survive" 2 (List.length references);
  match references with
  | [ first; second ] ->
    check bool "same-name hits retain different exact refs" false
      (Skill_reference.equal first second)
  | _ -> fail "expected two exact Skill references"
;;

let test_search_includes_outside_tool_and_skill () =
  let config = parse_config (config_text (source_row ~id:"only" ~path:"skills")) in
  let frozen =
    snapshot config [ [ candidate ~directory:"release-checklist" instruction_document ] ]
  in
  let surface =
    capability_surface
      ~tool_groups:(Some [ "board" ])
      ~skill_names:(Some [])
      frozen
  in
  let outside_tool =
    search_candidates surface "tool_read_file"
    |> List.exists (fun hit ->
      match hit.Masc.Keeper_capability_search.document.payload with
      | Masc.Keeper_capability_surface.Ordinary_tool capability ->
        capability.availability = Masc.Keeper_capability_surface.Outside_tool_surface
      | Skill _ -> false)
  in
  check bool "outside Tool is searchable" true outside_tool;
  let outside_skill =
    search_candidates surface "\"release-checklist\""
    |> List.exists (fun hit ->
      match hit.Masc.Keeper_capability_search.document.payload with
      | Masc.Keeper_capability_surface.Skill capability ->
        capability.availability
        = Masc.Keeper_capability_surface.Outside_skill_surface
      | Ordinary_tool _ -> false)
  in
  check bool "outside Skill is searchable" true outside_skill
;;

let test_invalid_skill_search_is_isolated () =
  let config = parse_config (config_text (source_row ~id:"only" ~path:"skills")) in
  let frozen =
    snapshot
      config
      [ [ candidate ~directory:"release-checklist" instruction_document
        ; candidate ~directory:"broken" "---\nname: broken\n---\nbody\n"
        ] ]
  in
  let hits = search_candidates (capability_surface frozen) "broken" in
  check int "only invalid Skill matches" 1 (List.length hits);
  match hits with
  | [ hit ] ->
    (match hit.Masc.Keeper_capability_search.document.payload with
     | Masc.Keeper_capability_surface.Skill capability ->
       check bool "invalid availability retained" true
         (capability.availability = Masc.Keeper_capability_surface.Invalid_definition)
     | Ordinary_tool _ -> fail "invalid Skill query returned a Tool")
  | _ -> fail "invalid Skill search count changed after assertion"
;;

let test_search_returns_every_fts_hit_without_cutoff () =
  let documents =
    List.init 32 (fun index ->
      Masc.Keeper_capability_search.
        { payload = index
        ; name = Printf.sprintf "candidate-%d" index
        ; description = "sharedneedle"
        ; category = "test"
        ; invocation_name = None
        })
  in
  match Masc.Keeper_capability_search.search ~query:"sharedneedle" documents with
  | Ok hits -> check int "no top-N cutoff" 32 (List.length hits)
  | Error error ->
    fail
      (Yojson.Safe.to_string
         (Masc.Keeper_capability_search.error_to_yojson error))
;;

let test_surface_digest_binds_exact_tool_input_schema () =
  let config = parse_config (config_text (source_row ~id:"only" ~path:"skills")) in
  let surface = capability_surface (snapshot config [ [] ]) in
  let descriptor =
    Masc.Keeper_capability_surface.tool_capabilities surface
    |> List.find_opt (fun (capability : Masc.Keeper_capability_surface.tool_capability) ->
      String.equal capability.descriptor.internal_name "tool_read_file")
    |> function
    | Some capability -> capability.descriptor
    | None -> fail "Read capability is absent from digest fixture"
  in
  let material = Masc.Keeper_capability_surface.digest_material_to_yojson surface in
  let row =
    Yojson.Safe.Util.(material |> member "candidates" |> to_list)
    |> List.find_opt (fun row ->
      String.equal
        "tool_read_file"
        Yojson.Safe.Util.(
          row
          |> member "candidate"
          |> member "capability"
          |> member "internal_name"
          |> to_string))
    |> function
    | Some row -> row
    | None -> fail "Read digest material is absent"
  in
  check string "digest material retains exact input schema"
    (Yojson.Safe.to_string (Yojson.Safe.sort descriptor.input_schema))
    Yojson.Safe.Util.(row |> member "input_schema" |> Yojson.Safe.sort |> Yojson.Safe.to_string);
  let altered_material =
    match material with
    | `Assoc fields ->
      `Assoc
        (List.map
           (fun (name, value) ->
              if String.equal name "candidates"
              then
                ( name
                , match value with
                  | `List rows ->
                    `List
                      (List.map
                         (fun row ->
                            let is_read =
                              match
                                Yojson.Safe.Util.(
                                  row
                                  |> member "candidate"
                                  |> member "capability"
                                  |> member "internal_name")
                              with
                              | `String name -> String.equal name "tool_read_file"
                              | _ -> false
                            in
                            if not is_read
                            then row
                            else
                              match row with
                              | `Assoc fields ->
                                `Assoc
                                  (List.map
                                     (fun (field, value) ->
                                        if String.equal field "input_schema"
                                        then field, `Assoc []
                                        else field, value)
                                     fields)
                              | other -> other)
                         rows)
                  | other -> other )
              else name, value)
           fields)
    | other -> other
  in
  let altered_digest =
    altered_material
    |> Yojson.Safe.sort
    |> Yojson.Safe.to_string
    |> Digestif.SHA256.digest_string
    |> Digestif.SHA256.to_hex
  in
  check bool "input schema change changes digest" false
    (String.equal (Masc.Keeper_capability_surface.digest surface) altered_digest)
;;

let () =
  run
    "keeper_skill_inventory"
    [ ( "inventory"
      , [ test_case "valid instruction and exact reference" `Quick
            test_valid_instruction_and_exact_reference
        ; test_case "valid composition" `Quick test_valid_composition
        ; test_case "invalid sibling isolation" `Quick
            test_invalid_sibling_isolated_with_digest
        ; test_case "catalog source precedence" `Quick
            test_catalog_status_tracks_source_precedence
        ; test_case "restricted Tool availability" `Quick
            test_capability_surface_keeps_active_and_outside_tools
        ; test_case "empty Skill selection" `Quick
            test_empty_selection_makes_valid_skill_operator_only
        ; test_case "shadowed and invalid Skill availability" `Quick
            test_shadowed_and_invalid_skills_keep_typed_availability
        ; test_case "duplicate-name search keeps exact refs" `Quick
            test_search_keeps_duplicate_exact_skill_references
        ; test_case "outside Tool and Skill search" `Quick
            test_search_includes_outside_tool_and_skill
        ; test_case "invalid Skill search isolation" `Quick
            test_invalid_skill_search_is_isolated
        ; test_case "search has no cutoff" `Quick
            test_search_returns_every_fts_hit_without_cutoff
        ; test_case "surface digest binds exact Tool schema" `Quick
            test_surface_digest_binds_exact_tool_input_schema
        ] )
    ]
;;
