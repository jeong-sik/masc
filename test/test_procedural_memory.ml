(** Regression tests for procedural-memory crystallization thresholds. *)

open Alcotest
module P = Masc.Procedural_memory
module S = Masc.Skill_candidate_projection
module Store = Masc.Skill_candidate_store
module M = Masc.Keeper_memory_os_types
module Memory_io = Masc.Keeper_memory_os_io

let procedure ?(evidence = []) ?(success_count = 0) ?(failure_count = 0)
    ?(confidence = 0.0) ?(id = "proc-test") ?(agent_name = "keeper")
    ?(pattern = "When a pattern appears, reuse the learned action") () : P.procedure =
  {
    id;
    agent_name;
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
    claim_kind = None;
    source;
    observed_by = [];
    first_seen = 0.0;
    valid_until = None;
    last_verified_at = None;
    schema_version = M.schema_version;
    claim_id = None;
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

let read_file = Fs_compat.load_file

let write_file_or_fail path content =
  match Fs_compat.save_file_atomic path content with
  | Ok () -> ()
  | Error msg -> fail msg
;;

let with_env name value f =
  let previous = Sys.getenv_opt name in
  Unix.putenv name value;
  Fun.protect
    ~finally:(fun () ->
      match previous with
      | Some value -> Unix.putenv name value
      | None -> Unix.putenv name "")
    f
;;

let write_facts_for_base_path ~base_path ~keeper_id facts =
  Memory_io.rewrite_facts_atomically_for_base_path ~base_path ~keeper_id facts
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

let test_skill_candidate_store_keeps_same_id_distinct_sources () =
  with_temp_base_path
  @@ fun base_path ->
  let candidate_for agent_name =
    require_candidate
      (procedure ~id:"Shared Procedure" ~agent_name
         ~evidence:[ "proof-store://abc"; "proof-store://def"; "proof-store://ghi" ]
         ~success_count:3 ~failure_count:0 ~confidence:1.0 ())
  in
  let alpha = candidate_for "alpha" in
  let beta = candidate_for "beta" in
  check string "display ids intentionally collide" alpha.id beta.id;
  let write c =
    match Store.write_candidate ~base_path c with
    | Ok stored -> stored
    | Error msg -> fail msg
  in
  let alpha_stored = write alpha in
  let beta_stored = write beta in
  check bool "source identity has distinct draft dirs" true
    (not (String.equal alpha_stored.dir beta_stored.dir));
  check bool "source identity has distinct json paths" true
    (not (String.equal alpha_stored.json_path beta_stored.json_path));
  check bool "alpha json remains readable" true (Sys.file_exists alpha_stored.json_path);
  check bool "beta json remains readable" true (Sys.file_exists beta_stored.json_path);
  let listing =
    match Store.list_drafts ~base_path ~limit:10 with
    | Ok listing -> listing
    | Error msg -> fail msg
  in
  check int "distinct source total" 2 listing.total;
  check int "distinct source shown" 2 listing.shown;
  let agents =
    listing.items
    |> List.map (fun (item : Store.draft_summary) -> item.agent_name)
    |> List.sort String.compare
  in
  check (list string) "both source agents listed" [ "alpha"; "beta" ] agents
;;

let test_skill_candidate_store_writes_post_turn_memory_fact_candidates () =
  with_temp_base_path
  @@ fun base_path ->
  let fact =
    memory_fact ~category:M.Lesson ~trace_id:"trace-skill" ~turn:11
      ~tool_call_id:"tool-skill"
      "When a recurring review succeeds, preserve the review checklist"
  in
  write_facts_for_base_path ~base_path ~keeper_id:"keeper" [ fact ];
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
  check int "unchanged candidate skipped" 0 (List.length second)
;;

let noisy_index_event ~i =
  let suffix = Printf.sprintf "%03d" i in
  let noise_path name = Filename.concat "/tmp/masc-skill-candidate-noise" name in
  `Assoc
    [ "schema", `String "masc.skill_candidate.index.v1"
    ; "id", `String ("noise-" ^ suffix)
    ; "agent_name", `String "noise"
    ; "source_kind", `String "memory_os_fact"
    ; "source_ref", `String ("noise-ref-" ^ suffix)
    ; "promotion_state", `String "candidate"
    ; "dir", `String (noise_path suffix)
    ; "json_path", `String (noise_path (suffix ^ "/candidate.json"))
    ; "toml_path", `String (noise_path (suffix ^ "/candidate.toml"))
    ; "skill_md_path", `String (noise_path (suffix ^ "/SKILL.md"))
    ; "ts", `Float 0.0
    ]
;;

let append_noisy_index_rows ~base_path ~count =
  let index_path = Store.index_path ~base_path in
  for i = 1 to count do
    Fs_compat.append_file index_path
      (Yojson.Safe.to_string (noisy_index_event ~i) ^ "\n")
  done
;;

let skill_candidate_index_row_matches candidate json =
  let open Yojson.Safe.Util in
  match
    ( member "id" json
    , member "agent_name" json
    , member "source_kind" json
    , member "source_ref" json )
  with
  | `String id, `String agent_name, `String source_kind, `String source_ref ->
    String.equal id candidate.S.id
    && String.equal agent_name candidate.agent_name
    && String.equal source_kind candidate.source_kind
    && String.equal source_ref candidate.source_ref
  | _ -> false
;;

let test_skill_candidate_store_skips_unchanged_candidate_with_noisy_index () =
  with_temp_base_path
  @@ fun base_path ->
  let fact =
    memory_fact ~category:M.Lesson ~trace_id:"trace-noisy-index-skill" ~turn:14
      ~tool_call_id:"tool-noisy-index-skill"
      "When draft skill indexes grow, keep unchanged candidate checks bounded"
  in
  let candidate =
    match S.candidates_of_memory_facts ~agent_name:"keeper" [ fact ] with
    | [ candidate ] -> candidate
    | _ -> fail "expected one projected candidate"
  in
  write_facts_for_base_path ~base_path ~keeper_id:"keeper" [ fact ];
  let first =
    match
      Store.write_post_turn_candidates ~base_path ~keeper_id:"keeper"
        ~fact_tail_limit:16 ~procedure_limit:0
    with
    | Ok stored -> stored
    | Error msg -> fail msg
  in
  check int "initial candidate written" 1 (List.length first);
  append_noisy_index_rows ~base_path ~count:250;
  let second =
    match
      Store.write_post_turn_candidates ~base_path ~keeper_id:"keeper"
        ~fact_tail_limit:16 ~procedure_limit:0
    with
    | Ok stored -> stored
    | Error msg -> fail msg
  in
  check int "unchanged candidate skipped despite noisy index" 0 (List.length second);
  let index_rows = Fs_compat.load_jsonl (Store.index_path ~base_path) in
  let candidate_rows =
    List.filter (skill_candidate_index_row_matches candidate) index_rows
  in
  check int "no duplicate index append" 251 (List.length index_rows);
  check int "candidate indexed once" 1 (List.length candidate_rows)
;;

let test_skill_candidate_store_recovers_partial_candidate_artifacts () =
  with_temp_base_path
  @@ fun base_path ->
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
  write_file_or_fail json_path (Yojson.Safe.pretty_to_string (S.to_json c) ^ "\n");
  check bool "partial json preexists" true (Sys.file_exists json_path);
  check bool "partial toml absent" false (Sys.file_exists toml_path);
  write_facts_for_base_path ~base_path ~keeper_id:"keeper" [ fact ];
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
  check bool "skill draft recovered" true (Sys.file_exists skill_md_path)
;;

let test_skill_candidate_store_recovers_missing_index_for_complete_artifacts () =
  with_temp_base_path
  @@ fun base_path ->
  let fact =
    memory_fact ~category:M.Lesson ~trace_id:"trace-index-skill" ~turn:13
      ~tool_call_id:"tool-index-skill"
      "When draft candidate artifacts already exist, missing index rows are repaired"
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
  write_file_or_fail json_path (Yojson.Safe.pretty_to_string (S.to_json c) ^ "\n");
  write_file_or_fail toml_path (Store.render_candidate_toml c);
  write_file_or_fail skill_md_path (S.render_skill_draft c);
  check bool "index absent before recovery" false
    (Sys.file_exists (Store.index_path ~base_path));
  write_facts_for_base_path ~base_path ~keeper_id:"keeper" [ fact ];
  let stored =
    match
      Store.write_post_turn_candidates ~base_path ~keeper_id:"keeper"
        ~fact_tail_limit:16 ~procedure_limit:0
    with
    | Ok stored -> stored
    | Error msg -> fail msg
  in
  check int "complete artifacts re-indexed" 1 (List.length stored);
  let listing =
    match Store.list_drafts ~base_path ~limit:10 with
    | Ok listing -> listing
    | Error msg -> fail msg
  in
  check int "missing index repaired" 1 listing.total;
  match listing.items with
  | [ item ] -> check string "indexed candidate id" c.id item.id
  | _ -> fail "expected one indexed draft"
;;

let test_skill_candidate_store_scopes_post_turn_reads_to_base_path () =
  with_temp_base_path
  @@ fun global_base ->
  with_temp_base_path
  @@ fun target_base ->
  with_env "MASC_BASE_PATH" global_base
  @@ fun () ->
  with_env "MASC_BASE_PATH_INPUT" global_base
  @@ fun () ->
  let global_fact =
    memory_fact ~category:M.Lesson ~trace_id:"trace-global-skill" ~turn:21
      ~tool_call_id:"tool-global-skill"
      "When a global workspace lesson exists, it must not seed target drafts"
  in
  write_facts_for_base_path ~base_path:global_base ~keeper_id:"keeper" [ global_fact ];
  let global_procedure =
    procedure ~id:"Global Workspace Procedure"
      ~pattern:"When global workspace procedure exists, keep it out of target drafts"
      ~evidence:[ "global-a"; "global-b"; "global-c" ] ~success_count:3
      ~failure_count:0 ~confidence:1.0 ()
  in
  P.save_procedure ~base_path:global_base ~agent_name:"keeper" global_procedure;
  let leaked =
    match
      Store.write_post_turn_candidates ~base_path:target_base ~keeper_id:"keeper"
        ~fact_tail_limit:16 ~procedure_limit:5
    with
    | Ok stored -> stored
    | Error msg -> fail msg
  in
  check int "global post-turn candidates ignored" 0 (List.length leaked);
  let empty_listing =
    match Store.list_drafts ~base_path:target_base ~limit:10 with
    | Ok listing -> listing
    | Error msg -> fail msg
  in
  check int "target draft store stays empty" 0 empty_listing.total;
  let target_procedure =
    procedure ~id:"Target Workspace Procedure"
      ~pattern:"When target workspace procedure exists, write a target draft"
      ~evidence:[ "target-a"; "target-b"; "target-c" ] ~success_count:3
      ~failure_count:0 ~confidence:1.0 ()
  in
  P.save_procedure ~base_path:target_base ~agent_name:"keeper" target_procedure;
  let target_stored =
    match
      Store.write_post_turn_candidates ~base_path:target_base ~keeper_id:"keeper"
        ~fact_tail_limit:16 ~procedure_limit:5
    with
    | Ok stored -> stored
    | Error msg -> fail msg
  in
  let target_summary =
    match target_stored with
    | [ item ] -> item
    | _ -> fail "expected one target-scoped procedure candidate"
  in
  check string "target source kind" "procedure" target_summary.candidate.source_kind;
  check string "target source id" target_procedure.id target_summary.candidate.source_id
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

let test_load_procedures_strict_ok () =
  with_temp_base_path
  @@ fun base_path ->
  let p = procedure ~id:"strict-ok" ~evidence:[ "a"; "b"; "c" ]
    ~success_count:3 ~failure_count:0 ~confidence:1.0 () in
  (match P.rewrite_procedures ~base_path ~agent_name:"keeper" [ p ] with
   | Ok () -> ()
   | Error msg -> fail msg);
  match P.load_procedures_strict ~base_path ~agent_name:"keeper" () with
  | Ok procs -> check int "one procedure loaded" 1 (List.length procs)
  | Error errs -> failf "unexpected strict errors: %d" (List.length errs)
;;

let test_load_procedures_strict_rejects_bad_json () =
  with_temp_base_path
  @@ fun base_path ->
  let path = P.procedures_path ~base_path ~agent_name:"keeper" () in
  Fs_compat.mkdir_p (Filename.dirname path);
  write_file_or_fail path "this is not json\n";
  match P.load_procedures_strict ~base_path ~agent_name:"keeper" () with
  | Ok _ -> fail "expected strict load to reject bad json"
  | Error errs ->
    check int "one error" 1 (List.length errs);
    let err = List.hd errs in
    check string "error path" path err.P.path;
    check int "error line" 1 err.P.line_number
;;

let test_load_procedures_strict_rejects_schema_mismatch () =
  with_temp_base_path
  @@ fun base_path ->
  let path = P.procedures_path ~base_path ~agent_name:"keeper" () in
  Fs_compat.mkdir_p (Filename.dirname path);
  write_file_or_fail path {|{"unknown_field":"x"}|};
  match P.load_procedures_strict ~base_path ~agent_name:"keeper" () with
  | Ok _ -> fail "expected strict load to reject schema mismatch"
  | Error errs -> check int "one error" 1 (List.length errs)
;;

let test_rewrite_procedures_returns_error_on_bad_path () =
  (* Use a path that is a file, not a directory, so the atomic write fails. *)
  let marker = Filename.temp_file "proc-bad-path-" ".tmp" in
  let base_path = marker ^ "_not_a_dir" in
  let p = procedure ~id:"bad-path" () in
  match P.rewrite_procedures ~base_path ~agent_name:"keeper" [ p ] with
  | Ok () -> fail "expected rewrite to fail on bad path"
  | Error _ -> check bool "rewrite failed" true true
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
      ( "io",
        [
          test_case "strict loader accepts valid file" `Quick
            test_load_procedures_strict_ok;
          test_case "strict loader rejects malformed json" `Quick
            test_load_procedures_strict_rejects_bad_json;
          test_case "strict loader rejects schema mismatch" `Quick
            test_load_procedures_strict_rejects_schema_mismatch;
          test_case "rewrite returns error on bad path" `Quick
            test_rewrite_procedures_returns_error_on_bad_path;
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
          test_case "keeps same id candidates with distinct sources" `Quick
            test_skill_candidate_store_keeps_same_id_distinct_sources;
          test_case "writes post-turn memory fact candidates" `Quick
            test_skill_candidate_store_writes_post_turn_memory_fact_candidates;
          test_case "skips unchanged candidate with noisy index" `Quick
            test_skill_candidate_store_skips_unchanged_candidate_with_noisy_index;
          test_case "recovers partial candidate artifacts" `Quick
            test_skill_candidate_store_recovers_partial_candidate_artifacts;
          test_case "recovers missing index for complete artifacts" `Quick
            test_skill_candidate_store_recovers_missing_index_for_complete_artifacts;
          test_case "scopes post-turn reads to base path" `Quick
            test_skill_candidate_store_scopes_post_turn_reads_to_base_path;
          test_case "sanitizes candidate id path" `Quick
            test_skill_candidate_store_sanitizes_candidate_id_path;
        ] );
    ]
;;
