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

let async_composition_document =
  {|---
name: quiet-clock
description: Read the clock through the durable async broker.
---

```toml composition
[[compositions]]
name = "quiet-clock"
description = "Read the clock through the durable async broker."
execution = "async"

[[compositions.nodes]]
id = "clock"
tool = "keeper_time_now"
[compositions.nodes.input]
kind = "literal"
value = {}
```
|}
;;

let composition_document_with_tool_surface ?(key = "masc-composition-tool") value =
  Printf.sprintf
    {|---
name: manual-clock
description: Read the clock only when a task explicitly names this skill.
%s: %s
---

```toml composition
[[compositions]]
name = "manual-clock"
description = "Read the clock only when a task explicitly names this skill."
execution = "inline"

[[compositions.nodes]]
id = "clock"
tool = "keeper_time_now"
[compositions.nodes.input]
kind = "literal"
value = {}
```
|}
    key value
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

let documented_composition_document =
  {|---
name: how-to-write-a-skill
description: Show how a composition skill declares its plan.
---

# Writing a composition skill

A composition skill carries exactly one fence. The example below is escaped the
CommonMark way, with a longer outer fence, so it is documentation and not a
declaration:

````markdown
```toml composition
[[compositions]]
name = "example-plan"
description = "An example, not a declaration."
execution = "inline"

[[compositions.nodes]]
id = "clock"
tool = "keeper_time_now"
[compositions.nodes.input]
kind = "literal"
value = {}
```
````

Nothing above is declared by this file.
|}
;;

let tilde_documented_composition_document =
  {|---
name: how-to-write-a-skill
description: Show how a composition skill declares its plan.
---

~~~markdown
```toml composition
[[compositions]]
name = "example-plan"
description = "An example, not a declaration."
execution = "inline"
```
~~~
|}
;;

let fenced_prose_then_composition_document =
  {|---
name: time-memory-query
description: Feed the exact clock result into memory search.
---

Check the runtime first:

```sh
masc keeper status
```

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
```
|}
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

(* #30205 rejected a mismatch outright; #30680 relaxed it to keep the skill
   loadable. What the relaxation must not do is leave the name ambiguous: a
   task names a skill by its directory (docs/SKILLS.md), so the directory is
   what the skill answers to and the frontmatter is the one that gave way.
   Asserting the declared name here read the relaxation backwards, and the PR
   that wrote it never ran this file. *)
let test_directory_name_mismatch_is_runtime_compatible () =
  let skill = parsed ~directory:"another-name" instruction_document in
  check string "the directory is what a task can name" "another-name" skill.name;
  match skill.conformance with
  | Agent_core.Skill_document.Conformant -> fail "name mismatch lost its diagnostic"
  | Runtime_compatible diagnostics ->
    check
      bool
      "turn catalog retains the mismatch diagnostic"
      true
      (List.exists
         (function
           | Agent_core.Skill_document.Name_mismatch
               { declared = "release-checklist"; directory = "another-name" } ->
             true
           | _ -> false)
         diagnostics)
;;

let test_missing_required_frontmatter_rejected () =
  (* [name] is optional in the standard: the directory supplies it. *)
  let no_name = "---\ndescription: something\n---\nbody\n" in
  let named_by_directory = parsed ~directory:"anything" no_name in
  check string "name comes from the directory" "anything" named_by_directory.Skill_catalog.name;
  let no_description = "---\nname: quiet\n---\nbody\n" in
  match rejected ~directory:"quiet" no_description with
  | Skill_catalog.Definition_rejected { diagnostics; directory = _ } ->
    check bool "has decoder diagnostic" true (diagnostics <> [])
  | error -> fail ("unexpected error: " ^ Skill_catalog.error_to_string error)
;;

(* A skill that documents the composition grammar must stay a document. Before
   this was enforced, the inner fence of an escaped example was read as a
   declaration — and since [of_documents] fails the whole catalog on the first
   bad file, one such skill took every keeper turn down. *)
let test_escaped_example_stays_an_instruction () =
  let skill = parsed ~directory:"how-to-write-a-skill" documented_composition_document in
  check
    string
    "surface"
    "instruction"
    (Skill_catalog.surface_to_string skill.Skill_catalog.surface);
  check
    bool
    "body keeps the example verbatim"
    true
    (contains ~needle:"name = \"example-plan\"" skill.Skill_catalog.body)
;;

let test_tilde_fence_also_escapes_an_example () =
  let skill =
    parsed ~directory:"how-to-write-a-skill" tilde_documented_composition_document
  in
  check
    string
    "surface"
    "instruction"
    (Skill_catalog.surface_to_string skill.Skill_catalog.surface)
;;

(* The other direction: an ordinary fence before the declaration must not
   swallow it. Skipping enclosed fences is only correct if it ends at the
   closing run. *)
let test_ordinary_fence_does_not_hide_a_declaration () =
  let skill =
    parsed ~directory:"time-memory-query" fenced_prose_then_composition_document
  in
  match skill.Skill_catalog.surface with
  | Skill_catalog.Instruction -> fail "the declaration after a shell fence was lost"
  | Skill_catalog.Composition entry ->
    check
      string
      "tool name"
      "keeper_compose_time-memory-query"
      (Catalog.tool_name entry)
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
  (match Skill_catalog.composition_entries catalog with
   | [ entry ] ->
     check
       string
       "composition entries surface the validated tool"
       "keeper_compose_time-memory-query"
       (Catalog.tool_name entry)
   | entries ->
     fail
       (Printf.sprintf
          "expected 1 composition entry, got %d"
          (List.length entries)));
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

let write_file path content =
  let channel = open_out_bin path in
  Fun.protect
    ~finally:(fun () -> close_out channel)
    (fun () -> output_string channel content)
;;

let rec remove_tree path =
  if Sys.file_exists path
  then
    if Sys.is_directory path
    then (
      Sys.readdir path
      |> Array.iter (fun name -> remove_tree (Filename.concat path name));
      Unix.rmdir path)
    else Unix.unlink path
;;

let test_loader_scans_the_skills_directory () =
  let base_path = Filename.temp_file "keeper-skill-loader" "" in
  Unix.unlink base_path;
  Unix.mkdir base_path 0o755;
  Fun.protect
    ~finally:(fun () -> remove_tree base_path)
    (fun () ->
       (match Masc.Keeper_run_tools_setup.load_skill_catalog ~base_path with
        | Ok catalog ->
          check
            int
            "missing skills dir loads an empty catalog"
            0
            (List.length (Skill_catalog.skills catalog))
        | Error _ -> fail "missing skills directory did not load as empty");
       let skills_dir =
         Masc.Keeper_run_tools_setup.skills_dir_of_base_path ~base_path
       in
       Unix.mkdir (Filename.dirname skills_dir) 0o755;
       Unix.mkdir skills_dir 0o755;
       let skill_dir = Filename.concat skills_dir "release-checklist" in
       Unix.mkdir skill_dir 0o755;
       write_file (Filename.concat skill_dir "SKILL.md") instruction_document;
       Unix.mkdir (Filename.concat skills_dir "half-installed") 0o755;
       write_file (Filename.concat skills_dir "README.md") "not a skill\n";
       (match Masc.Keeper_run_tools_setup.load_skill_catalog ~base_path with
        | Ok catalog ->
          (match Skill_catalog.skills catalog with
           | [ skill ] ->
             check
               string
               "the SKILL.md-carrying directory is the only skill"
               "release-checklist"
               skill.Skill_catalog.name
           | skills ->
             fail
               (Printf.sprintf "expected 1 skill, got %d" (List.length skills)))
        | Error _ -> fail "valid skills directory failed to load");
       (* A missing description, not a missing name: the directory supplies a
          name, so that is no longer the defect a broken install shows. *)
       write_file
         (Filename.concat (Filename.concat skills_dir "half-installed") "SKILL.md")
         "---\nname: half-installed\n---\n";
       match Masc.Keeper_run_tools_setup.load_skill_catalog ~base_path with
       | Error
           (Agent_core.Error.Config
             (Agent_core.Error.InvalidConfig { field = "skills"; detail })) ->
         check bool "detail names the defect" true (String.length detail > 0)
       | Ok _ | Error _ ->
         fail "broken SKILL.md did not return a typed config error")
;;

let skill_catalog_of documents =
  match Skill_catalog.of_documents documents with
  | Ok catalog -> catalog
  | Error error ->
    fail ("valid skill catalog was rejected: " ^ Skill_catalog.error_to_string error)
;;

let test_masc_composition_tool_controls_dedicated_tool () =
  let disabled =
    skill_catalog_of
      [ "manual-clock", composition_document_with_tool_surface "false" ]
  in
  (match Skill_catalog.find disabled "manual-clock" with
   | Some skill ->
     check
       string
       "disabled composition remains task-readable"
       "instruction"
       (Skill_catalog.surface_to_string skill.Skill_catalog.surface)
   | None -> fail "disabled composition disappeared from the task skill catalog");
  check
    int
    "disabled composition has no dedicated entry"
    0
    (List.length (Skill_catalog.composition_entries disabled));
  let disabled_surface =
    Masc.Keeper_run_tools_setup.expected_model_tool_names
      ~identity_tool_names:[]
      ~skill_catalog:disabled
      ~model_visible_descriptors:[]
  in
  check
    bool
    "generic task-routed reader remains"
    true
    (List.mem Catalog.skill_tool_name disabled_surface);
  check
    bool
    "dedicated composition tool is absent"
    false
    (List.mem "keeper_compose_manual-clock" disabled_surface);
  let enabled =
    skill_catalog_of
      [ "manual-clock", composition_document_with_tool_surface "true" ]
  in
  let enabled_surface =
    Masc.Keeper_run_tools_setup.expected_model_tool_names
      ~identity_tool_names:[]
      ~skill_catalog:enabled
      ~model_visible_descriptors:[]
  in
  check
    bool
    "boolean true preserves dedicated composition tool"
    true
    (List.mem "keeper_compose_manual-clock" enabled_surface)
;;

let test_masc_composition_tool_rejects_non_boolean_values () =
  List.iter
    (fun (source, expected_kind) ->
       match
         Skill_catalog.parse_skill
           ~directory:"manual-clock"
           (composition_document_with_tool_surface source)
       with
       | Error
           (Skill_catalog.Invalid_masc_composition_tool
             { skill = "manual-clock"; actual }) ->
         check string ("value " ^ source) expected_kind actual
       | Error error ->
         fail
           (Printf.sprintf
              "value %s returned the wrong error: %s"
              source
              (Skill_catalog.error_to_string error))
       | Ok _ -> fail ("non-boolean value was silently accepted: " ^ source))
    [ {|"true"|}, "string"
    ; "1", "number"
    ; "null", "null"
    ; "[true]", "sequence"
    ; "{ enabled: true }", "mapping"
    ]
;;

let test_legacy_disable_model_invocation_is_rejected () =
  match
    Skill_catalog.parse_skill
      ~directory:"manual-clock"
      (composition_document_with_tool_surface
         ~key:"disable-model-invocation"
         "true")
  with
  | Error (Skill_catalog.Removed_disable_model_invocation { skill }) ->
    check string "error names the skill" "manual-clock" skill
  | Error error ->
    fail ("legacy key returned the wrong error: " ^ Skill_catalog.error_to_string error)
  | Ok _ -> fail "legacy key was silently assigned MASC-specific semantics"
;;

let test_allowed_tools_is_rejected () =
  let document =
    {|---
name: release-checklist
description: Walk the release checklist before shipping.
allowed-tools: Read Bash(git:*)
---

# Release checklist
|}
  in
  match Skill_catalog.parse_skill ~directory:"release-checklist" document with
  | Error (Skill_catalog.Removed_allowed_tools { skill }) ->
    check string "error names the skill" "release-checklist" skill
  | Error error ->
    fail ("allowed-tools returned the wrong error: " ^ Skill_catalog.error_to_string error)
  | Ok _ -> fail "allowed-tools was silently accepted without approval semantics"
;;

let test_composition_skill_joins_projection () =
  let descriptors = Masc.Keeper_tool_descriptor.model_visible_descriptors () in
  let expected_instruction =
    Masc.Keeper_run_tools_setup.expected_model_tool_names
        ~identity_tool_names:[]
      ~skill_catalog:(skill_catalog_of [ "release-checklist", instruction_document ])
      ~model_visible_descriptors:descriptors
  in
  check
    bool
    "instruction skill joins the descriptor projection"
    true
    (List.mem Catalog.skill_tool_name expected_instruction);
  let expected =
    Masc.Keeper_run_tools_setup.expected_model_tool_names
        ~identity_tool_names:[]
      ~skill_catalog:
        (skill_catalog_of [ "time-memory-query", composition_document ])
      ~model_visible_descriptors:descriptors
  in
  check
    bool
    "composition skill joins the descriptor projection"
    true
    (List.mem "keeper_compose_time-memory-query" expected);
  check
    bool
    "inline-only skills add no async controls"
    false
    (List.mem Catalog.status_tool_name expected);
  let expected_async =
    Masc.Keeper_run_tools_setup.expected_model_tool_names
        ~identity_tool_names:[]
      ~skill_catalog:(skill_catalog_of [ "quiet-clock", async_composition_document ])
      ~model_visible_descriptors:descriptors
  in
  check
    bool
    "async skill adds the shared status and cancel controls"
    true
    (List.mem Catalog.status_tool_name expected_async
     && List.mem Catalog.cancel_tool_name expected_async)
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
            "directory name mismatch remains runtime-compatible"
            `Quick
            test_directory_name_mismatch_is_runtime_compatible
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
            "an example escaped by a longer outer fence stays an instruction"
            `Quick
            test_escaped_example_stays_an_instruction
        ; test_case
            "a tilde outer fence escapes an example too"
            `Quick
            test_tilde_fence_also_escapes_an_example
        ; test_case
            "an ordinary fence does not hide a later declaration"
            `Quick
            test_ordinary_fence_does_not_hide_a_declaration
        ; test_case
            "composition name must equal the skill name"
            `Quick
            test_composition_name_must_match_skill
        ; test_case
            "of_documents sorts by name and rejects duplicates"
            `Quick
            test_of_documents_sorts_and_rejects_duplicates
        ; test_case
            "loader scans the skills directory"
            `Quick
            test_loader_scans_the_skills_directory
        ; test_case
            "masc-composition-tool controls the dedicated tool"
            `Quick
            test_masc_composition_tool_controls_dedicated_tool
        ; test_case
            "masc-composition-tool rejects non-booleans"
            `Quick
            test_masc_composition_tool_rejects_non_boolean_values
        ; test_case
            "legacy disable-model-invocation is rejected"
            `Quick
            test_legacy_disable_model_invocation_is_rejected
        ; test_case
            "allowed-tools is rejected"
            `Quick
            test_allowed_tools_is_rejected
        ; test_case
            "composition skill joins the model projection"
            `Quick
            test_composition_skill_joins_projection
        ] )
    ]
;;
