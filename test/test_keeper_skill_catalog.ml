open Alcotest

module Skill_catalog = Masc.Keeper_skill_catalog
module Snapshot = Skill_catalog_snapshot

let snapshot_of_document ~directory source_text =
  let config_text =
    {|[skills]
resource-read-max-bytes = 16384
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

let shadowed_snapshot () =
  let config_text =
    {|[skills]
resource-read-max-bytes = 16384
[[skills.sources]]
id = "first"
anchor = "base-path"
path = "first-skills"
access = "read-write"
[[skills.sources]]
id = "second"
anchor = "base-path"
path = "second-skills"
access = "read-write"
|}
  in
  let config =
    match Skill_source_config.parse_text config_text with
    | Ok config -> config
    | Error _ -> fail "two-source Skill fixture config was rejected"
  in
  let documents =
    [ "---\nname: review\ndescription: First source.\n---\nfirst body"
    ; "---\nname: review\ndescription: Second source.\n---\nsecond body"
    ]
  in
  let scans =
    List.map2
      (fun source source_text ->
         let resolved =
           Skill_source_config.resolve ~base_path:"/workspace" ~user_home:None source
         in
         let resolved_path =
           match resolved.Skill_source_config.resolution with
           | Resolved path -> path
           | _ -> fail "two-source Skill fixture did not resolve"
         in
         { Snapshot.source = resolved
         ; observation = Snapshot.Source_ready { resolved_path; candidates = 1 }
         ; candidates = [ Snapshot.Candidate_document { directory = "review"; source_text } ]
         })
      config.Skill_source_config.sources
      documents
  in
  match Snapshot.configured ~config scans with
  | Ok snapshot -> snapshot
  | Error _ -> fail "two-source Skill snapshot fixture was rejected"
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
name: status-memory-query
description: Feed the lane profile into memory search.
---

Use when durable memory should be searched for the current lane.

```toml composition
[[compositions]]
name = "status-memory-query"
description = "Feed the lane profile into memory search."
execution = "inline"

[[compositions.nodes]]
id = "lane"
tool = "keeper_lane_status"
[compositions.nodes.input]
kind = "literal"
value = {}

[[compositions.nodes]]
id = "search"
tool = "keeper_memory_search"
after = ["lane"]
[compositions.nodes.input]
kind = "object"
[[compositions.nodes.input.fields]]
name = "query"
[compositions.nodes.input.fields.value]
kind = "output"
node = "lane"
pointer = "/profile"
```
|}
;;

let _async_composition_document =
  {|---
name: quiet-lane
description: Read the lane status through the durable async broker.
---

```toml composition
[[compositions]]
name = "quiet-lane"
description = "Read the lane status through the durable async broker."
execution = "async"

[[compositions.nodes]]
id = "lane"
tool = "keeper_lane_status"
[compositions.nodes.input]
kind = "literal"
value = {}
```
|}
;;

let composition_document_with_invocation_policy ~key value =
  Printf.sprintf
    {|---
name: manual-lane
description: Read the lane status only when a task explicitly names this skill.
%s: %s
---

```toml composition
[[compositions]]
name = "manual-lane"
description = "Read the lane status only when a task explicitly names this skill."
execution = "inline"

[[compositions.nodes]]
id = "lane"
tool = "keeper_lane_status"
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
id = "lane"
tool = "keeper_lane_status"
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

let _fenced_prose_then_composition_document =
  {|---
name: status-memory-query
description: Feed the lane profile into memory search.
---

Check the runtime first:

```sh
masc keeper status
```

```toml composition
[[compositions]]
name = "status-memory-query"
description = "Feed the lane profile into memory search."
execution = "inline"

[[compositions.nodes]]
id = "lane"
tool = "keeper_lane_status"
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


let test_directory_name_mismatch_is_rejected () =
  match rejected ~directory:"another-name" instruction_document with
  | Skill_catalog.Definition_rejected { diagnostics; _ } ->
    check
      bool
      "catalog retains the exact mismatch diagnostic"
      true
      (List.exists
         (function
           | Agent_core.Skill_document.Name_mismatch
               { declared = "release-checklist"; directory = "another-name" } ->
             true
           | _ -> false)
         diagnostics)
  | error -> fail ("unexpected error: " ^ Skill_catalog.error_to_string error)
;;

let test_missing_required_frontmatter_rejected () =
  let no_name = "---\ndescription: something\n---\nbody\n" in
  (match rejected ~directory:"anything" no_name with
   | Skill_catalog.Definition_rejected { diagnostics; _ } ->
     check
       bool
       "missing name"
       true
       (List.mem Agent_core.Skill_document.Missing_name diagnostics)
   | error -> fail ("unexpected error: " ^ Skill_catalog.error_to_string error));
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

let test_operator_projection_keeps_shadowed_exact_entries () =
  let snapshot = shadowed_snapshot () in
  let effective, effective_diagnostics = Skill_catalog.of_snapshot snapshot in
  let all, all_diagnostics = Skill_catalog.all_entries_of_snapshot snapshot in
  check int "runtime catalog keeps one effective Skill" 1
    (List.length (Skill_catalog.skills effective));
  check int "operator surface keeps both exact Skills" 2
    (List.length (Skill_catalog.skills all));
  check int "effective projection diagnostics" 0 (List.length effective_diagnostics);
  check int "all-entry projection diagnostics" 0 (List.length all_diagnostics);
  match
    Skill_catalog.skills all
    |> List.filter_map (fun (skill : Skill_catalog.skill) -> skill.reference)
  with
  | [ first; second ] ->
    check bool "shadow references are distinct" false (Skill_reference.equal first second)
  | references -> failf "expected two exact references, got %d" (List.length references)
;;


let test_partition_documents_sorts_and_reports_duplicates () =
  let catalog, rejected =
    Skill_catalog.partition_documents
      [ "status-memory-query", composition_document
      ; "release-checklist", instruction_document
      ]
  in
  check int "valid catalog has no rejections" 0 (List.length rejected);
  (match Skill_catalog.skills catalog with
   | [ first; second ] ->
     check string "sorted first" "release-checklist" first.Skill_catalog.name;
     check string "sorted second" "status-memory-query" second.Skill_catalog.name
   | skills -> fail (Printf.sprintf "expected 2 skills, got %d" (List.length skills)));
  (match Skill_catalog.find catalog "status-memory-query" with
   | Some skill ->
     check
       string
       "find returns the skill"
       "instruction"
       (Skill_catalog.surface_to_string skill.Skill_catalog.surface)
   | None -> fail "find missed an existing skill");
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

(* Valid SKILL.md bodies exceeding the 16 KiB inline tool-result boundary are
   accepted cleanly (never arbitrarily refused); large bodies are delivered on
   demand via [keeper_skill] and offloaded to a structured blob handle when
   over the provider wire boundary. *)
let test_unreadable_body_is_rejected_not_offered () =
  let max_bytes = Common.max_tool_result_wire_bytes in
  let long_body = String.make (max_bytes + 1) 'x' in
  let document =
    "---\nname: long-guide\ndescription: A body past the inline read boundary.\n---\n"
    ^ long_body
  in
  let catalog, rejections =
    Skill_catalog.partition_documents
      [ "release-checklist", instruction_document; "long-guide", document ]
  in
  check
    (list string)
    "both readable and long skills are offered"
    [ "long-guide"; "release-checklist" ]
    (Skill_catalog.skills catalog
     |> List.map (fun skill -> skill.Skill_catalog.name));
  check int "no rejection for valid long SKILL.md" 0 (List.length rejections);
  let snapshot_catalog, diagnostics =
    Skill_catalog.of_snapshot (snapshot_of_document ~directory:"long-guide" document)
  in
  check
    int
    "snapshot catalog offers long SKILL.md"
    1
    (List.length (Skill_catalog.skills snapshot_catalog));
  check int "no projection diagnostics for valid long SKILL.md" 0 (List.length diagnostics);
  match Skill_catalog.find snapshot_catalog "long-guide" with
  | Some skill -> check int "full body preserved" (max_bytes + 1) (String.length skill.body)
  | None -> fail "expected long-guide in snapshot catalog"
;;

(* keeper_skill returns the body as the instruction. A skill with no text in
   it would be offered and then teach nothing, so both catalog paths reject
   it with the typed reason instead. *)
let test_blank_body_is_rejected_not_offered () =
  (* ASCII spaces and U+00A0 no-break spaces alike: the gate uses the
     document's Unicode blank predicate, not [String.trim]. *)
  let cases = [ "ascii spaces", "   "; "no-break spaces", "\xc2\xa0\xc2\xa0" ] in
  let expect_blank_rejection label = function
    | Skill_catalog.Body_blank { skill } ->
      check string (label ^ ": skill") "stub-guide" skill
    | error ->
      fail (label ^ ": wrong rejection: " ^ Skill_catalog.error_to_string error)
  in
  List.iter
    (fun (case, blanks) ->
      let document =
        Printf.sprintf
          "---\nname: stub-guide\ndescription: A stub with no instruction text.\n---\n\n%s\n"
          blanks
      in
      let catalog, rejections =
        Skill_catalog.partition_documents
          [ "release-checklist", instruction_document; "stub-guide", document ]
      in
      check
        (list string)
        (case ^ ": readable skill stays offered")
        [ "release-checklist" ]
        (Skill_catalog.skills catalog
         |> List.map (fun skill -> skill.Skill_catalog.name));
      (match rejections with
       | [ { Skill_catalog.directory; error } ] ->
         check string (case ^ ": rejection names its package") "stub-guide" directory;
         expect_blank_rejection (case ^ ": document catalog") error
       | rejections ->
         failf "%s: expected one rejection, got %d" case (List.length rejections));
      let snapshot_catalog, diagnostics =
        Skill_catalog.of_snapshot
          (snapshot_of_document ~directory:"stub-guide" document)
      in
      check
        int
        (case ^ ": snapshot catalog does not offer it")
        0
        (List.length (Skill_catalog.skills snapshot_catalog));
      (match diagnostics with
       | [ diagnostic ] ->
         expect_blank_rejection
           (case ^ ": snapshot catalog")
           diagnostic.Skill_catalog.error
       | diagnostics ->
         failf
           "%s: expected one projection diagnostic, got %d"
           case
           (List.length diagnostics)))
    cases
;;

(* Long instruction bodies with embedded fenced blocks remain offered cleanly
   instead of failing a 16 KiB size gate. *)
let test_oversized_frozen_fallback_is_unavailable () =
  let max_bytes = Common.max_tool_result_wire_bytes in
  let document =
    "---\nname: broken-long\ndescription: Long body with fenced block.\n---\n\n```toml composition\n[[compositions]]\n"
    ^ String.make max_bytes 'x'
  in
  let catalog, diagnostics =
    Skill_catalog.of_snapshot (snapshot_of_document ~directory:"broken-long" document)
  in
  check
    int
    "long skill body is offered"
    1
    (List.length (Skill_catalog.skills catalog));
  check int "no projection diagnostics" 0 (List.length diagnostics)
;;

let skill_catalog_of documents =
  match Skill_catalog.partition_documents documents with
  | catalog, [] -> catalog
  | _, { error; _ } :: _ ->
    fail ("valid skill catalog was rejected: " ^ Skill_catalog.error_to_string error)
;;

let test_unknown_policy_fields_are_document_rejections () =
  List.iter
    (fun (key, value) ->
       match
         Skill_catalog.parse_skill
           ~directory:"manual-lane"
           (composition_document_with_invocation_policy ~key value)
       with
       | Error (Skill_catalog.Definition_rejected { diagnostics; _ }) ->
         check
           bool
           "error names the unknown field"
           true
           (List.mem
              (Agent_core.Skill_document.Unexpected_frontmatter_field key)
              diagnostics)
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
    ]
;;

let test_tool_preapproval_hint_has_no_keeper_policy () =
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
  | Error error ->
    fail
      ("the official optional field stopped the skill loading: "
       ^ Skill_catalog.error_to_string error)
  | Ok skill ->
    check string "the skill is the one it names" "release-checklist" skill.name;
    check bool "frontmatter does not become instruction policy" false
      (String_util.contains_substring skill.body "Bash(git:*)")
;;

let test_composition_skill_joins_projection () =
  let descriptors = Masc.Keeper_tool_descriptor.model_visible_descriptors () in
  let expected_instruction =
    Masc.Keeper_run_tools_setup.expected_model_tool_names
        ~identity_names:[]
      ~skill_catalog:(skill_catalog_of [ "release-checklist", instruction_document ])
      ~model_visible_descriptors:descriptors
      ()
  in
  check
    bool
    "instruction skill joins the descriptor projection"
    true
    (List.mem Masc.Keeper_instruction_skill.skill_tool_name expected_instruction)
;;

(* The entries of one published snapshot are projected once, and every
   projection of that snapshot gets the same projected skills: the effective
   catalog, the operator catalog, and an entry resolved on its own as a
   task's skill or an inventory row is. A snapshot built again from the same
   document is projected afresh, and two snapshots asked about in turn each
   get their own skills. *)
let test_a_snapshot_is_projected_once () =
  let document name =
    Printf.sprintf "---\nname: %s\ndescription: Projected once.\n---\n\nRead me.\n" name
  in
  let skills (catalog, _diagnostics) = Skill_catalog.skills catalog in
  let names projection =
    List.map (fun (skill : Skill_catalog.skill) -> skill.name) (skills projection)
  in
  let same_skills left right =
    List.length left = List.length right && List.for_all2 ( == ) left right
  in
  let snapshot = snapshot_of_document ~directory:"once" (document "once") in
  let preparation = Skill_catalog.prepare_snapshot
      ~descriptors:(Masc.Keeper_tool_descriptor.all_descriptors ()) snapshot in
  let first = skills (Skill_catalog.of_snapshot snapshot) in
  check bool "the same snapshot gives back its projected skills" true
    (same_skills first (skills (Skill_catalog.of_snapshot snapshot)));
  check bool "the operator catalog shares them" true
    (same_skills first (skills (Skill_catalog.all_entries_of_snapshot snapshot)));
  (match Snapshot.entries snapshot with
   | [ entry ] ->
     (match Skill_catalog.project_entry_or_fallback snapshot entry with
      | Skill_catalog.Projected skill ->
        check bool "an entry resolved on its own shares it" true (same_skills first [ skill ])
      | Skill_catalog.Entry_unavailable _ ->
        fail "the fixture entry did not project")
   | _ -> fail "the fixture snapshot does not hold one entry");
  let rebuilt = snapshot_of_document ~directory:"once" (document "once") in
  let fresh = skills (Skill_catalog.of_snapshot rebuilt) in
  check bool "a snapshot built again is projected afresh" false (same_skills first fresh);
  check (list string) "into the same skills" [ "once" ]
    (names (Skill_catalog.of_snapshot rebuilt));
  let other = snapshot_of_document ~directory:"other" (document "other") in
  check (list string) "another snapshot gets its own skills" [ "other" ]
    (names (Skill_catalog.of_snapshot other));
  Gc.full_major ();
  check bool "interleaving and collecting list containers preserves the owned original binding" true
    (same_skills first (skills (Skill_catalog.of_snapshot snapshot)));
  check (list string) "and the first one its own again" [ "once" ]
    (names (Skill_catalog.of_snapshot rebuilt));
  let changed = snapshot_of_document ~directory:"once"
      "---\nname: once\ndescription: Changed source.\n---\nCHANGED_BODY\n" in
  (match Snapshot.entries changed with
   | [entry] ->
     (match Skill_catalog.project_prepared_entry preparation entry with
      | Skill_catalog.Projected skill ->
        check string "foreign same-identity entry keeps its changed content" "Changed source." skill.description;
        check bool "foreign same-identity entry keeps its own revision" true
          (match skill.reference with
           | Some reference -> Skill_reference.equal reference (Snapshot.entry_reference entry)
           | None -> false)
      | Entry_unavailable _ -> fail "changed instruction did not project")
   | _ -> fail "changed source fixture did not retain its entry");
  check bool "foreign fallback does not mutate the original retained catalog" true
    (same_skills first (skills (Skill_catalog.prepared_catalog preparation)))
;;

(* Each entry resolved on its own gets its own projection, a shadowed one
   included. *)
let test_each_entry_gets_its_own_projection () =
  let snapshot = shadowed_snapshot () in
  List.iter
    (fun (entry : Snapshot.entry) ->
       match Skill_catalog.project_entry_or_fallback snapshot entry with
       | Skill_catalog.Projected { reference = Some reference; _ } ->
         check bool
           ("the projection names its own entry: " ^ entry.directory)
           true
           (Skill_reference.equal reference (Snapshot.entry_reference entry))
       | Skill_catalog.Projected { reference = None; _ }
       | Skill_catalog.Entry_unavailable _ -> fail "a shadowed fixture entry did not project")
    (Snapshot.entries snapshot)
;;

let () =
  run
    "keeper_skill_catalog"
    [ ( "skill catalog"
      , [ test_case "instruction skill parses" `Quick test_instruction_skill_parses
        ; test_case
            "directory name mismatch is rejected"
            `Quick
            test_directory_name_mismatch_is_rejected
        ; test_case
            "missing required frontmatter is rejected"
            `Quick
            test_missing_required_frontmatter_rejected
        ; test_case
            "an example escaped by a longer outer fence stays an instruction"
            `Quick
            test_escaped_example_stays_an_instruction
        ; test_case
            "a tilde outer fence escapes an example too"
            `Quick
            test_tilde_fence_also_escapes_an_example
        ; test_case
            "operator projection keeps shadowed exact entries"
            `Quick
            test_operator_projection_keeps_shadowed_exact_entries
        ; test_case "a snapshot is projected once" `Quick
            test_a_snapshot_is_projected_once
        ; test_case "each entry gets its own projection" `Quick
            test_each_entry_gets_its_own_projection
        ; test_case
            "partition sorts by name and reports duplicates"
            `Quick
            test_partition_documents_sorts_and_reports_duplicates
        ; test_case
            "unreadable body is rejected, not offered"
            `Quick
            test_unreadable_body_is_rejected_not_offered
        ; test_case
            "blank body is rejected, not offered"
            `Quick
            test_blank_body_is_rejected_not_offered
        ; test_case
            "oversized frozen fallback is unavailable"
            `Quick
            test_oversized_frozen_fallback_is_unavailable
        ; test_case
            "partition_documents isolates rejections"
            `Quick
            test_partition_documents_isolates_rejections
        ; test_case
            "invocation policy fields are rejected"
            `Quick
            test_unknown_policy_fields_are_document_rejections
        ; test_case "allowed-tools has no Keeper policy" `Quick
            test_tool_preapproval_hint_has_no_keeper_policy
        ; test_case
            "composition skill joins the model projection"
            `Quick
            test_composition_skill_joins_projection
        
] )
    ]
;;
