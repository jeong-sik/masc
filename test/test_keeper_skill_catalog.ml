open Alcotest

module Skill_catalog = Masc.Keeper_skill_catalog
module Catalog = Masc.Keeper_tool_composition_catalog

let instruction_document =
  {|---
name: release-checklist
description: Walk the release checklist before shipping.
---

# Release checklist

1. Read the diff.
2. Check CI.
|}
;;

let composition_document =
  {|---
name: time-memory-query
description: Feed the exact clock result into memory search.
---

Use when durable memory should be searched at the current instant.

```toml composition
[[compositions]]
name = "time-memory-query"
description = "Feed the exact clock result into memory search."
execution = "inline"

[[compositions.nodes]]
id = "time"
tool = "keeper_time_now"
[compositions.nodes.input]
kind = "literal"
value = {}

[[compositions.nodes]]
id = "search"
tool = "keeper_memory_search"
after = ["time"]
[compositions.nodes.input]
kind = "object"
[[compositions.nodes.input.fields]]
name = "query"
[compositions.nodes.input.fields.value]
kind = "output"
node = "time"
pointer = "/now_iso"
```
|}
;;

let parsed ~directory document =
  match Skill_catalog.parse_skill ~directory document with
  | Ok skill -> skill
  | Error error ->
    fail ("valid skill document was rejected: " ^ Skill_catalog.error_to_string error)
;;

let rejected ~directory document =
  match Skill_catalog.parse_skill ~directory document with
  | Ok _ -> fail "invalid skill document was accepted"
  | Error error -> error
;;

let contains ~needle haystack =
  let needle_length = String.length needle in
  let haystack_length = String.length haystack in
  let rec probe index =
    if index + needle_length > haystack_length
    then false
    else if String.equal (String.sub haystack index needle_length) needle
    then true
    else probe (index + 1)
  in
  probe 0
;;

let test_instruction_skill_parses () =
  let skill = parsed ~directory:"release-checklist" instruction_document in
  check string "name" "release-checklist" skill.Skill_catalog.name;
  check
    string
    "description"
    "Walk the release checklist before shipping."
    skill.Skill_catalog.description;
  check
    string
    "surface"
    "instruction"
    (Skill_catalog.surface_to_string skill.Skill_catalog.surface);
  check
    bool
    "body keeps the markdown"
    true
    (contains ~needle:"# Release checklist" skill.Skill_catalog.body)
;;

let test_composition_skill_materializes_entry () =
  let skill = parsed ~directory:"time-memory-query" composition_document in
  match skill.Skill_catalog.surface with
  | Skill_catalog.Instruction ->
    fail "composition document parsed as an instruction skill"
  | Skill_catalog.Composition entry ->
    check
      string
      "tool name"
      "keeper_compose_time-memory-query"
      (Catalog.tool_name entry);
    check
      string
      "execution"
      "inline"
      (Catalog.execution_mode_to_string entry.Catalog.execution);
    check
      bool
      "body keeps the fence for keeper_skill readers"
      true
      (contains ~needle:"```toml composition" skill.Skill_catalog.body)
;;

let test_directory_name_mismatch_rejected () =
  match rejected ~directory:"another-name" instruction_document with
  | Skill_catalog.Directory_name_mismatch { directory; declared } ->
    check string "directory" "another-name" directory;
    check string "declared" "release-checklist" declared
  | error -> fail ("unexpected error: " ^ Skill_catalog.error_to_string error)
;;

let test_missing_required_frontmatter_rejected () =
  let no_name = "---\ndescription: something\n---\nbody\n" in
  (match rejected ~directory:"anything" no_name with
   | Skill_catalog.Missing_name { directory } ->
     check string "directory" "anything" directory
   | error -> fail ("unexpected error: " ^ Skill_catalog.error_to_string error));
  let no_description = "---\nname: quiet\n---\nbody\n" in
  match rejected ~directory:"quiet" no_description with
  | Skill_catalog.Missing_description { skill } -> check string "skill" "quiet" skill
  | error -> fail ("unexpected error: " ^ Skill_catalog.error_to_string error)
;;

let test_unterminated_block_rejected () =
  let document =
    "---\nname: broken\ndescription: never closes the fence\n---\n\n```toml composition\n[[compositions]]\n"
  in
  match rejected ~directory:"broken" document with
  | Skill_catalog.Unterminated_composition_block { skill } ->
    check string "skill" "broken" skill
  | error -> fail ("unexpected error: " ^ Skill_catalog.error_to_string error)
;;

let test_multiple_blocks_rejected () =
  let document =
    "---\nname: doubled\ndescription: two fences\n---\n\n```toml composition\n```\n\n```toml composition\n```\n"
  in
  match rejected ~directory:"doubled" document with
  | Skill_catalog.Multiple_composition_blocks { skill; count } ->
    check string "skill" "doubled" skill;
    check int "count" 2 count
  | error -> fail ("unexpected error: " ^ Skill_catalog.error_to_string error)
;;

let test_composition_name_must_match_skill () =
  let document =
    String.concat
      "\n"
      [ "---"
      ; "name: outer-name"
      ; "description: block declares a different composition name"
      ; "---"
      ; ""
      ; "```toml composition"
      ; "[[compositions]]"
      ; "name = \"inner-name\""
      ; "execution = \"inline\""
      ; ""
      ; "[[compositions.nodes]]"
      ; "id = \"time\""
      ; "tool = \"keeper_time_now\""
      ; "[compositions.nodes.input]"
      ; "kind = \"literal\""
      ; "value = {}"
      ; "```"
      ; ""
      ]
  in
  match rejected ~directory:"outer-name" document with
  | Skill_catalog.Composition_name_mismatch { skill; declared } ->
    check string "skill" "outer-name" skill;
    check string "declared" "inner-name" declared
  | error -> fail ("unexpected error: " ^ Skill_catalog.error_to_string error)
;;

let test_of_documents_sorts_and_rejects_duplicates () =
  let catalog =
    match
      Skill_catalog.of_documents
        [ "time-memory-query", composition_document
        ; "release-checklist", instruction_document
        ]
    with
    | Ok catalog -> catalog
    | Error error ->
      fail ("valid catalog was rejected: " ^ Skill_catalog.error_to_string error)
  in
  (match Skill_catalog.skills catalog with
   | [ first; second ] ->
     check string "sorted first" "release-checklist" first.Skill_catalog.name;
     check string "sorted second" "time-memory-query" second.Skill_catalog.name
   | skills -> fail (Printf.sprintf "expected 2 skills, got %d" (List.length skills)));
  (match Skill_catalog.find catalog "time-memory-query" with
   | Some skill ->
     check
       string
       "find returns the composition skill"
       "composition"
       (Skill_catalog.surface_to_string skill.Skill_catalog.surface)
   | None -> fail "find missed an existing skill");
  match
    Skill_catalog.of_documents
      [ "release-checklist", instruction_document
      ; "release-checklist", instruction_document
      ]
  with
  | Ok _ -> fail "duplicate skill directories were accepted"
  | Error (Skill_catalog.Duplicate_skill { name }) ->
    check string "duplicate name" "release-checklist" name
  | Error error -> fail ("unexpected error: " ^ Skill_catalog.error_to_string error)
;;

let () =
  run
    "keeper_skill_catalog"
    [ ( "skill catalog"
      , [ test_case "instruction skill parses" `Quick test_instruction_skill_parses
        ; test_case
            "composition skill materializes a catalog entry"
            `Quick
            test_composition_skill_materializes_entry
        ; test_case
            "directory and frontmatter name must agree"
            `Quick
            test_directory_name_mismatch_rejected
        ; test_case
            "missing required frontmatter is rejected"
            `Quick
            test_missing_required_frontmatter_rejected
        ; test_case
            "unterminated composition fence is rejected"
            `Quick
            test_unterminated_block_rejected
        ; test_case
            "multiple composition fences are rejected"
            `Quick
            test_multiple_blocks_rejected
        ; test_case
            "composition name must equal the skill name"
            `Quick
            test_composition_name_must_match_skill
        ; test_case
            "of_documents sorts by name and rejects duplicates"
            `Quick
            test_of_documents_sorts_and_rejects_duplicates
        ] )
    ]
;;
