open Alcotest

module Skill_catalog = Masc.Keeper_skill_catalog
module Catalog = Masc.Keeper_tool_composition_catalog
module Snapshot = Skill_catalog_snapshot

let snapshot_of_document ~directory source_text =
  let config_text =
    {|[skills]
activation-lifetime = "session"
precedence = "earlier-source-wins"
[[skills.sources]]
id = "fixture"
anchor = "base-path"
path = "skills"
access = "read-write"
|}
  in
  let config =
    match Skill_source_config.parse_text config_text with
    | Ok config -> config
    | Error _ -> fail "Skill source fixture config was rejected"
  in
  let source =
    match config.Skill_source_config.sources with
    | [ source ] -> source
    | _ -> fail "Skill source fixture did not contain exactly one source"
  in
  let resolved =
    Skill_source_config.resolve ~base_path:"/workspace" ~user_home:None source
  in
  let scan : Snapshot.source_scan =
    { source = resolved
    ; observation =
        Snapshot.Source_ready { resolved_path = "/workspace/skills"; candidates = 1 }
    ; candidates = [ Snapshot.Candidate_document { directory; source_text } ]
    }
  in
  match Snapshot.configured ~config [ scan ] with
  | Ok snapshot -> snapshot
  | Error _ -> fail "Skill snapshot fixture was rejected"
;;

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

let composition_document_with_invocation_policy ~key value =
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
   declaration and the skill was rejected or promoted by accident. *)
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

let test_malformed_composition_is_diagnostic_only () =
  let malformed =
    "---\nname: broken\ndescription: Invalid composition fixture.\n---\n\n```toml composition\n[[compositions]]\n"
  in
  let snapshot = snapshot_of_document ~directory:"broken" malformed in
  let catalog, diagnostics = Skill_catalog.of_snapshot snapshot in
  (match Skill_catalog.skills catalog with
   | [ skill ] ->
     check string "instruction name survives" "broken" skill.name;
     check string "frozen body survives" "```toml composition\n[[compositions]]\n" skill.body;
     (match skill.provenance with
      | Some provenance ->
        check string "frozen provenance survives" "broken" provenance.directory
      | None -> fail "frozen snapshot provenance was lost");
     (match skill.surface with
      | Skill_catalog.Instruction -> ()
      | Skill_catalog.Composition _ ->
        fail "malformed composition remained executable")
   | skills ->
     failf "expected one fallback instruction, got %d" (List.length skills));
  match diagnostics with
  | [ diagnostic ] ->
    (match diagnostic.Skill_catalog.error with
     | Skill_catalog.Unterminated_composition_block { skill } ->
       check string "typed diagnostic retains skill" "broken" skill
     | error ->
       fail
         ("unexpected projection diagnostic: "
          ^ Skill_catalog.error_to_string error))
  | diagnostics ->
    failf "expected one projection diagnostic, got %d" (List.length diagnostics)
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

let test_partition_documents_sorts_and_reports_duplicates () =
  let catalog, rejected =
    Skill_catalog.partition_documents
      [ "time-memory-query", composition_document
      ; "release-checklist", instruction_document
      ]
  in
  check int "valid catalog has no rejections" 0 (List.length rejected);
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
  let _catalog, rejected =
    Skill_catalog.partition_documents
      [ "release-checklist", instruction_document
      ; "release-checklist", instruction_document
      ]
  in
  match rejected with
  | [ { Skill_catalog.error = Skill_catalog.Duplicate_skill { name }; _ } ] ->
    check string "duplicate name" "release-checklist" name
  | _ -> fail "duplicate skill directory was not reported exactly once"
;;

let test_partition_documents_isolates_rejections () =
  let catalog, rejections =
    Skill_catalog.partition_documents
      [ "release-checklist", instruction_document
      ; "broken", "---\nname: broken\n---\n\n# Missing description\n"
      ]
  in
  check
    (list string)
    "valid skill remains usable"
    [ "release-checklist" ]
    (Skill_catalog.skills catalog
     |> List.map (fun skill -> skill.Skill_catalog.name));
  match rejections with
  | [ { Skill_catalog.directory; error = Skill_catalog.Definition_rejected _ } ] ->
    check string "rejection names its package" "broken" directory
  | [ rejected ] ->
    fail
      ("wrong rejection: " ^ Skill_catalog.error_to_string rejected.error)
  | rejected ->
    failf "expected one isolated rejection, got %d" (List.length rejected)
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
        | Ok (catalog, _left_out) ->
          check
            int
            "missing skills dir loads an empty catalog"
            0
            (List.length (Skill_catalog.skills catalog))
        | Error _ -> fail "missing skills directory did not load as empty");
       let skills_dir = Filename.concat (Filename.concat base_path ".masc") "skills" in
       Unix.mkdir (Filename.dirname skills_dir) 0o755;
       Unix.mkdir skills_dir 0o755;
       let skill_dir = Filename.concat skills_dir "release-checklist" in
       Unix.mkdir skill_dir 0o755;
       write_file (Filename.concat skill_dir "SKILL.md") instruction_document;
       Unix.mkdir (Filename.concat skills_dir "half-installed") 0o755;
       write_file (Filename.concat skills_dir "README.md") "not a skill\n";
       (match Masc.Keeper_run_tools_setup.load_skill_catalog ~base_path with
        | Ok (catalog, _left_out) ->
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
       let agents_root = Filename.concat base_path ".agents" in
       let agents_skills = Filename.concat agents_root "skills" in
       Unix.mkdir agents_root 0o755;
       Unix.mkdir agents_skills 0o755;
       let agent_skill_dir = Filename.concat agents_skills "agent-review" in
       Unix.mkdir agent_skill_dir 0o755;
       write_file
         (Filename.concat agent_skill_dir "SKILL.md")
         "---\nname: agent-review\ndescription: Review through the configured Agent Skills source.\n---\n\n# Agent review\n";
       (match Masc.Keeper_run_tools_setup.load_skill_catalog ~base_path with
        | Ok (catalog, _left_out) ->
          check
            (list string)
            "turn consumes the configured multi-source snapshot"
            [ "agent-review"; "release-checklist" ]
            (Skill_catalog.skills catalog
             |> List.map (fun skill -> skill.Skill_catalog.name))
        | Error _ -> fail "configured .agents skill source did not reach the turn");
       (* A missing description, not a missing name: the directory supplies a
          name, so that is no longer the defect a broken install shows. *)
       write_file
         (Filename.concat (Filename.concat skills_dir "half-installed") "SKILL.md")
         "---\nname: half-installed\n---\n";
       match Masc.Keeper_run_tools_setup.load_skill_catalog ~base_path with
       | Ok (catalog, _left_out) ->
         check
           (list string)
           "one broken optional skill does not stop unrelated turns"
           [ "agent-review"; "release-checklist" ]
           (Skill_catalog.skills catalog
            |> List.map (fun skill -> skill.Skill_catalog.name))
       | Error _ -> fail "one broken Skill stopped the whole Keeper catalog")
;;

let skill_catalog_of documents =
  match Skill_catalog.partition_documents documents with
  | catalog, [] -> catalog
  | _, { error; _ } :: _ ->
    fail ("valid skill catalog was rejected: " ^ Skill_catalog.error_to_string error)
;;

let test_invocation_policy_fields_are_rejected () =
  List.iter
    (fun (key, value) ->
       match
         Skill_catalog.parse_skill
           ~directory:"manual-clock"
           (composition_document_with_invocation_policy ~key value)
       with
       | Error (Skill_catalog.Removed_invocation_policy { skill; field }) ->
         check string "error names the skill" "manual-clock" skill;
         check string "error names the removed field" key field
       | Error error ->
         fail
           (Printf.sprintf
              "%s returned the wrong error: %s"
              key
              (Skill_catalog.error_to_string error))
       | Ok _ -> fail (key ^ " was silently assigned invocation semantics"))
    [ "masc-composition-tool", "false"
    ; "masc-composition-tool", "true"
    ; "disable-model-invocation", "true"
    ; "allowed-tools", "Read Bash(git:*)"
    ]
;;

let test_composition_skill_joins_projection () =
  let descriptors = Masc.Keeper_tool_descriptor.model_visible_descriptors () in
  let expected_instruction =
    Masc.Keeper_run_tools_setup.expected_model_tool_names
        ~identity_tool_names:[]
      ~skill_catalog:(skill_catalog_of [ "release-checklist", instruction_document ])
      ~model_visible_descriptors:descriptors
      ()
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
      ()
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
      ()
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
            "malformed snapshot composition is diagnostic-only"
            `Quick
            test_malformed_composition_is_diagnostic_only
        ; test_case
            "composition name must equal the skill name"
            `Quick
            test_composition_name_must_match_skill
        ; test_case
            "partition sorts by name and reports duplicates"
            `Quick
            test_partition_documents_sorts_and_reports_duplicates
        ; test_case
            "partition_documents isolates rejections"
            `Quick
            test_partition_documents_isolates_rejections
        ; test_case
            "loader scans the skills directory"
            `Quick
            test_loader_scans_the_skills_directory
        ; test_case
            "invocation policy fields are rejected"
            `Quick
            test_invocation_policy_fields_are_rejected
        ; test_case
            "composition skill joins the model projection"
            `Quick
            test_composition_skill_joins_projection
        ] )
    ]
;;
