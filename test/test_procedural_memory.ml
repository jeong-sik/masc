(** Regression tests for procedural-memory crystallization thresholds. *)

open Alcotest
module P = Masc.Procedural_memory
module S = Masc.Skill_candidate_projection
module Store = Masc.Skill_candidate_store
module M = Masc.Keeper_memory_os_types
module Memory_io = Masc.Keeper_memory_os_io

let procedure ?(evidence = []) ?(success_count = 0) ?(failure_count = 0)
    ?(confidence = 0.0) ?(id = "proc-test") ?(pattern = "When a pattern appears, reuse the learned action") () : P.procedure =
  {
    id;
    agent_name = "keeper";
    pattern;
    evidence;
    success_count;
    failure_count;
    confidence;
    created_at = 0.0;
    last_applied = 0.0;
  }
;;

let test_standard_threshold_crystallizes () =
  let p =
    procedure ~evidence:[ "a"; "b"; "c" ] ~success_count:7 ~failure_count:3
      ~confidence:0.7 ()
  in
  check bool "3 evidence at 70 percent crystallizes" true (P.is_crystallized p)
;;

let test_standard_threshold_rejects_low_confidence () =
  let p =
    procedure ~evidence:[ "a"; "b"; "c" ] ~success_count:2 ~failure_count:1
      ~confidence:0.69 ()
  in
  check bool "3 evidence below confidence threshold is not crystallized" false
    (P.is_crystallized p)
;;

let test_rare_perfect_crystallizes () =
  let p =
    procedure ~evidence:[ "a"; "b" ] ~success_count:2 ~failure_count:0
      ~confidence:1.0 ()
  in
  check bool "2 perfect outcomes crystallize" true (P.is_crystallized p)
;;

let test_rare_near_perfect_does_not_crystallize () =
  let p =
    procedure ~evidence:[ "a"; "b" ] ~success_count:99 ~failure_count:1
      ~confidence:0.99 ()
  in
  check bool "2 near-perfect outcomes do not bypass standard threshold" false
    (P.is_crystallized p)
;;

let test_single_perfect_does_not_crystallize () =
  let p =
    procedure ~evidence:[ "a" ] ~success_count:1 ~failure_count:0
      ~confidence:1.0 ()
  in
  check bool "single perfect outcome is not enough evidence" false
    (P.is_crystallized p)
;;

let require_candidate p =
  match S.candidate_of_procedure p with
  | Some c -> c
  | None -> fail "expected skill candidate"
;;

let contains_substring ~needle haystack =
  let needle_len = String.length needle in
  let haystack_len = String.length haystack in
  let rec loop i =
    if i + needle_len > haystack_len
    then false
    else if String.equal (String.sub haystack i needle_len) needle
    then true
    else loop (i + 1)
  in
  String.equal needle "" || loop 0
;;

let test_skill_candidate_projects_crystallized_procedure () =
  let p =
    procedure ~id:"Proc Review Loop" ~evidence:[ "task://T-1"; "decision 2" ]
      ~success_count:3 ~failure_count:0 ~confidence:1.0 ()
  in
  let c = require_candidate p in
  check string "candidate id" "skill-candidate-proc-review-loop" c.id;
  check string "state" "candidate" (S.promotion_state_to_string c.promotion_state);
  check (list string) "evidence refs"
    [ "procedure://keeper/proc-review-loop"
    ; "task://T-1"
    ; "procedure://keeper/proc-review-loop/evidence/decision-2"
    ]
    c.evidence_refs
;;

let test_skill_candidate_rejects_uncrystallized_procedure () =
  let p = procedure ~evidence:[ "only-once" ] ~success_count:1 ~confidence:1.0 () in
  check bool "not a candidate" true (Option.is_none (S.candidate_of_procedure p))
;;

let memory_fact ?(category = M.Validated_approach) ?(trace_id = "trace-1") ?(turn = 7)
    ?tool_call_id claim : M.fact =
  let source : M.provenance_event = { trace_id; turn; tool_call_id } in
  {
    claim;
    category;
    external_ref = None;
    source;
    observed_by = [];
    first_seen = 0.0;
    valid_until = None;
    last_verified_at = None;
    schema_version = M.schema_version;
  }
;;

let test_skill_candidate_projects_memory_os_lesson () =
  let fact =
    memory_fact ~category:M.Lesson ~tool_call_id:"tool 42"
      "When rate-limit retry succeeds, use bounded backoff"
  in
  let c =
    match S.candidate_of_memory_fact ~agent_name:"keeper" fact with
    | Some c -> c
    | None -> fail "expected memory fact candidate"
  in
  check string "source kind" "memory_os_fact" c.source_kind;
  check string "state" "candidate" (S.promotion_state_to_string c.promotion_state);
  check (float 0.0) "confidence awaits outcome evidence" 0.0 c.confidence;
  check (list string) "memory evidence refs"
    [ "memory-os-fact://keeper/trace-1/when-rate-limit-retry-succeeds-use-bounded-backoff"
    ; "keeper-turn://trace-1/7"
    ; "tool-call://tool-42"
    ]
    c.evidence_refs
;;

let test_skill_candidate_rejects_generic_memory_fact () =
  let fact = memory_fact ~category:M.Fact "The repo uses OCaml 5" in
  check bool "generic facts are not skill candidates" true
    (Option.is_none (S.candidate_of_memory_fact ~agent_name:"keeper" fact))
;;

let test_skill_candidate_json_and_draft_are_candidate_only () =
  let p =
    procedure
      ~evidence:[ "proof-store://abc"; "proof-store://def"; "proof-store://ghi" ]
      ~success_count:3 ~failure_count:1 ~confidence:0.75 ()
  in
  let c = require_candidate p in
  let json = S.to_json c in
  let member key = function
    | `Assoc fields -> List.assoc key fields
    | _ -> `Null
  in
  check string "schema" "masc.skill_candidate_projection.v1"
    (match member "schema" json with `String s -> s | _ -> "");
  check string "promotion_state" "candidate"
    (match member "promotion_state" json with `String s -> s | _ -> "");
  let draft = S.render_skill_draft c in
  check bool "draft status is explicit" true
    (contains_substring ~needle:"Status: candidate" draft);
  check bool "approval guard is explicit" true
    (contains_substring ~needle:"requires human approval" draft)
;;

let read_file path =
  let ic = open_in path in
  let len = in_channel_length ic in
  let content = really_input_string ic len in
  close_in ic;
  content
;;

let with_temp_base_path f =
  let marker = Filename.temp_file "skill-candidate-store-" ".tmp" in
  Sys.remove marker;
  Unix.mkdir marker 0o755;
  f marker
;;

let test_skill_candidate_store_writes_reviewable_draft_files () =
  with_temp_base_path
  @@ fun base_path ->
  let p =
    procedure ~id:"Repeatable Debug Loop"
      ~evidence:[ "proof-store://abc"; "proof-store://def"; "proof-store://ghi" ]
      ~success_count:3 ~failure_count:0 ~confidence:1.0 ()
  in
  let c = require_candidate p in
  let stored =
    match Store.write_candidate ~base_path c with
    | Ok stored -> stored
    | Error msg -> fail msg
  in
  check string "draft dir"
    (Store.draft_dir ~base_path c)
    stored.dir;
  check string "draft dir parent" (Store.drafts_dir ~base_path) (Filename.dirname stored.dir);
  check bool "candidate json exists" true (Sys.file_exists stored.json_path);
  check bool "candidate toml exists" true (Sys.file_exists stored.toml_path);
  check bool "skill md exists" true (Sys.file_exists stored.skill_md_path);
  check bool "index exists" true (Sys.file_exists stored.index_path);
  let toml = read_file stored.toml_path in
  check bool "toml is candidate only" true
    (contains_substring ~needle:"promotion_state = \"candidate\"" toml);
  check bool "toml is not installable" true
    (contains_substring ~needle:"installable = false" toml);
  check bool "approval remains required" true
    (contains_substring ~needle:"requires_human_approval = true" toml);
  let skill_md = read_file stored.skill_md_path in
  check bool "skill draft status is explicit" true
    (contains_substring ~needle:"Status: candidate" skill_md);
  let index = read_file stored.index_path in
  check bool "index references candidate" true (contains_substring ~needle:c.id index)
;;

let test_skill_candidate_store_toml_handles_control_text () =
  let control_text = "before" ^ String.make 1 (Char.chr 12) ^ "after" in
  let p =
    procedure ~id:"Control TOML Candidate" ~pattern:control_text
      ~evidence:[ "proof-store://abc"; "proof-store://def"; "proof-store://ghi" ]
      ~success_count:3 ~failure_count:0 ~confidence:1.0 ()
  in
  let c = require_candidate p in
  let toml = Store.render_candidate_toml c in
  let parsed =
    match Otoml.Parser.from_string_result toml with
    | Ok parsed -> parsed
    | Error msg -> fail msg
  in
  let parsed_pattern =
    match Otoml.find_result parsed Otoml.get_string [ "pattern" ] with
    | Ok pattern -> pattern
    | Error msg -> fail msg
  in
  check string "control text pattern round trips" c.pattern parsed_pattern
;;

let test_skill_candidate_store_lists_latest_reviewable_drafts () =
  with_temp_base_path
  @@ fun base_path ->
  let p =
    procedure ~id:"Listable Candidate"
      ~evidence:[ "proof-store://abc"; "proof-store://def"; "proof-store://ghi" ]
      ~success_count:3 ~failure_count:0 ~confidence:1.0 ()
  in
  let c = require_candidate p in
  let _stored =
    match Store.write_candidate ~base_path c with
    | Ok stored -> stored
    | Error msg -> fail msg
  in
  let listing =
    match Store.list_drafts ~base_path ~limit:10 with
    | Ok listing -> listing
    | Error msg -> fail msg
  in
  check int "total" 1 listing.total;
  check int "shown" 1 listing.shown;
  check string "index path"
    (Store.index_path ~base_path)
    listing.index_path;
  let summary =
    match listing.items with
    | [ item ] -> item
    | _ -> fail "expected one draft summary"
  in
  check string "id" c.id summary.id;
  check string "agent" c.agent_name summary.agent_name;
  check string "state" "candidate" summary.promotion_state;
  check string "source ref" c.source_ref summary.source_ref;
  check bool "created_at present" true (Option.is_some summary.created_at)
;;

let test_skill_candidate_store_lists_newest_unique_draft_per_id () =
  with_temp_base_path
  @@ fun base_path ->
  let c1 =
    require_candidate
      (procedure ~id:"Duplicate Candidate"
         ~evidence:[ "proof-store://abc"; "proof-store://def"; "proof-store://ghi" ]
         ~success_count:3 ~failure_count:0 ~confidence:1.0 ())
  in
  let c2 : S.skill_candidate =
    { c1 with pattern = "When a duplicate candidate is re-written, show latest" }
  in
  let write c =
    match Store.write_candidate ~base_path c with
    | Ok _ -> ()
    | Error msg -> fail msg
  in
  write c1;
  write c2;
  let listing =
    match Store.list_drafts ~base_path ~limit:10 with
    | Ok listing -> listing
    | Error msg -> fail msg
  in
  check int "deduplicated total" 1 listing.total;
  check int "shown" 1 listing.shown;
  let summary =
    match listing.items with
    | [ item ] -> item
    | _ -> fail "expected one draft summary"
  in
  check string "keeps same candidate id" c1.id summary.id
;;

let test_skill_candidate_store_writes_post_turn_memory_fact_candidates () =
  with_temp_base_path
  @@ fun base_path ->
  let keepers_dir = Filename.concat base_path "keepers" in
  Memory_io.For_testing.with_keepers_dir keepers_dir (fun () ->
    let fact =
      memory_fact ~category:M.Lesson ~trace_id:"trace-skill" ~turn:11
        ~tool_call_id:"tool-skill"
        "When a recurring review succeeds, preserve the review checklist"
    in
    Memory_io.append_fact ~keeper_id:"keeper" fact;
    let stored =
      match
        Store.write_post_turn_candidates ~base_path ~keeper_id:"keeper"
          ~fact_tail_limit:16 ~procedure_limit:0
      with
      | Ok stored -> stored
      | Error msg -> fail msg
    in
    check int "one draft written" 1 (List.length stored);
    let summary =
      match stored with
      | [ item ] -> item
      | _ -> fail "expected one stored candidate"
    in
    check string "source kind" "memory_os_fact" summary.candidate.source_kind;
    check bool "candidate json exists" true (Sys.file_exists summary.json_path);
    let second =
      match
        Store.write_post_turn_candidates ~base_path ~keeper_id:"keeper"
          ~fact_tail_limit:16 ~procedure_limit:0
      with
      | Ok stored -> stored
      | Error msg -> fail msg
    in
    check int "unchanged candidate skipped" 0 (List.length second))
;;

let test_skill_candidate_store_recovers_partial_candidate_artifacts () =
  with_temp_base_path
  @@ fun base_path ->
  let keepers_dir = Filename.concat base_path "keepers" in
  Memory_io.For_testing.with_keepers_dir keepers_dir (fun () ->
    let fact =
      memory_fact ~category:M.Lesson ~trace_id:"trace-partial-skill" ~turn:12
        ~tool_call_id:"tool-partial-skill"
        "When a draft candidate write is partial, rewrite the missing artifacts"
    in
    let c =
      match S.candidates_of_memory_facts ~agent_name:"keeper" [ fact ] with
      | [ candidate ] -> candidate
      | _ -> fail "expected one projected candidate"
    in
    let dir = Store.draft_dir ~base_path c in
    let json_path = Filename.concat dir "candidate.json" in
    let toml_path = Filename.concat dir "candidate.toml" in
    let skill_md_path = Filename.concat dir "SKILL.md" in
    Fs_compat.mkdir_p dir;
    (match
       Fs_compat.save_file_atomic json_path (Yojson.Safe.pretty_to_string (S.to_json c) ^ "\n")
     with
     | Ok () -> ()
     | Error msg -> fail msg);
    check bool "partial json preexists" true (Sys.file_exists json_path);
    check bool "partial toml absent" false (Sys.file_exists toml_path);
    Memory_io.append_fact ~keeper_id:"keeper" fact;
    let stored =
      match
        Store.write_post_turn_candidates ~base_path ~keeper_id:"keeper"
          ~fact_tail_limit:16 ~procedure_limit:0
      with
      | Ok stored -> stored
      | Error msg -> fail msg
    in
    check int "partial candidate rewritten" 1 (List.length stored);
    check bool "toml recovered" true (Sys.file_exists toml_path);
    check bool "skill draft recovered" true (Sys.file_exists skill_md_path))
;;

let test_skill_candidate_store_sanitizes_candidate_id_path () =
  with_temp_base_path
  @@ fun base_path ->
  let base =
    require_candidate
      (procedure ~id:"Normal"
         ~evidence:[ "proof-store://abc"; "proof-store://def"; "proof-store://ghi" ]
         ~success_count:3 ~failure_count:0 ~confidence:1.0 ())
  in
  let c : S.skill_candidate = { base with id = "../Escape Candidate" } in
  let stored =
    match Store.write_candidate ~base_path c with
    | Ok stored -> stored
    | Error msg -> fail msg
  in
  check string "sanitized draft dir"
    (Store.draft_dir ~base_path c)
    stored.dir;
  check string "sanitized draft parent"
    (Store.drafts_dir ~base_path)
    (Filename.dirname stored.dir);
  check bool "sanitized draft keeps readable prefix" true
    (contains_substring ~needle:"escape-candidate" (Filename.basename stored.dir));
  check bool "sanitized draft removes traversal marker" false
    (contains_substring ~needle:".." (Filename.basename stored.dir));
  check bool "escaped parent not written" false
    (Sys.file_exists
       (Filename.concat (Filename.concat base_path ".masc") "Escape Candidate"))
;;

let () =
  run "procedural_memory"
    [
      ( "crystallization",
        [
          test_case "standard threshold crystallizes" `Quick
            test_standard_threshold_crystallizes;
          test_case "standard threshold rejects low confidence" `Quick
            test_standard_threshold_rejects_low_confidence;
          test_case "rare perfect crystallizes" `Quick test_rare_perfect_crystallizes;
          test_case "rare near-perfect does not crystallize" `Quick
            test_rare_near_perfect_does_not_crystallize;
          test_case "single perfect does not crystallize" `Quick
            test_single_perfect_does_not_crystallize;
        ] );
      ( "skill candidates",
        [
          test_case "projects crystallized procedure" `Quick
            test_skill_candidate_projects_crystallized_procedure;
          test_case "rejects uncrystallized procedure" `Quick
            test_skill_candidate_rejects_uncrystallized_procedure;
          test_case "projects Memory OS lesson" `Quick
            test_skill_candidate_projects_memory_os_lesson;
          test_case "rejects generic Memory OS fact" `Quick
            test_skill_candidate_rejects_generic_memory_fact;
          test_case "renders candidate-only JSON and draft" `Quick
            test_skill_candidate_json_and_draft_are_candidate_only;
          test_case "writes durable reviewable draft files" `Quick
            test_skill_candidate_store_writes_reviewable_draft_files;
          test_case "renders parseable TOML for control text" `Quick
            test_skill_candidate_store_toml_handles_control_text;
          test_case "lists latest reviewable draft files" `Quick
            test_skill_candidate_store_lists_latest_reviewable_drafts;
          test_case "lists newest unique draft per id" `Quick
            test_skill_candidate_store_lists_newest_unique_draft_per_id;
          test_case "writes post-turn memory fact candidates" `Quick
            test_skill_candidate_store_writes_post_turn_memory_fact_candidates;
          test_case "recovers partial candidate artifacts" `Quick
            test_skill_candidate_store_recovers_partial_candidate_artifacts;
          test_case "sanitizes candidate id path" `Quick
            test_skill_candidate_store_sanitizes_candidate_id_path;
        ] );
    ]
;;
