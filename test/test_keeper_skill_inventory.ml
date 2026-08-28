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
        ] )
    ]
;;
