(* L6g synthetic evaluation corpus and prompt contract verification
   (RFC librarian-call-only-proposes §5.5, §6.1, §6.2, #53538, #53543, and
   2026-11-16 dated usable-until research, plus empirical findings from
   Mem0 #4573, arXiv 2609.36457, arXiv 2608.11775, arXiv 2608.22752,
   Graphiti #1728, and runtime recall telemetry code-reviewer 0/925).

   Verifies two contracts deterministically without model calls:
   1. Curated 12-case synthetic corpus scored via [Librarian_scoring] and settled
      via [Librarian_plan] covering:
      - Dated usable-until memories with closed unit timestamps BEFORE target
        date (must NOT be dropped, both with new facts and as a no-op).
      - Dated usable-until memories whose closed unit timestamps and event
        evidence show completion (cleanly dropped with causal reason).
      - Cross-category facts merged into synthesis (scored via [must_keep]
        without silent schema rejection, preserving earliest [first_seen]).
      - Standing architectural identity constraints kept vs transient one-off
        queue status dropped (including Board provenance).
      - [revise] + [working_state] updates without duplicate [drop]
        ([Ref_used_twice] guardrail) and [Read_item_alone] ([Not_valid_alone]
        guardrail).
      - Keeper self-echo of existing Memory / [working_state] producing empty
        [ops: []] rather than spurious duplicate [add] (Mem0 #4573 97.8%).
      - Targeted contradiction [revise] with relative-to-absolute date
        resolution against §5.5 closed unit timestamps without collateral drops
        (Graphiti #1728 41%).
      - Progressive-aspect + numeric-qualifier [merge] preservation
        (arXiv 2609.36457, arXiv 2608.11775) and dual-kept constraint +
        claim-prose [working_state] bridge (arXiv 2608.22752,
        code-reviewer 0/925 recall).
      - Paired unknowing-reply non-erasure vs explicit operator retraction
        with original claim language preserved (Ollama 18936 regression).
   2. Legacy prompt guard: leaves [config/prompts/librarian.md] untouched and
      confirms removed [librarian-l6.md] stays absent without asserting on
      [librarian.ask.md] (owned by PR #53583, so both PRs can land in any
      order). *)

open Alcotest
module Answer = Masc.Librarian_answer
module Effects = Masc.Librarian_effects
module Plan = Masc.Librarian_plan
module Question_id = Masc.Librarian_question_id
module Scoring = Masc.Librarian_scoring
module Types = Masc.Keeper_memory_os_types

let front = "0123456789abcdef0123456789abcdef"
let back = "fedcba9876543210fedcba9876543210"

let asked =
  match Question_id.of_halves ~front ~back with
  | Some id -> id
  | None -> fail "test question id must be two 32-char lowercase hex halves"
;;

let authored : Types.origin = { kind = Types.Authored; trace_id = "synthetic-turn" }

let held ?(first_seen = 100.0) ?(category = Types.Fact) claim : Types.fact =
  { claim
  ; category
  ; first_seen
  ; last_seen = first_seen
  ; origin = authored
  ; basis = Types.Observed Types.Transcript
  }
;;

let id = Types.memory_id

let shown_of ?(units = [ "u1", 10 ]) facts : Plan.shown =
  { memory =
      Some (List.mapi (fun index fact -> Printf.sprintf "m%d" (index + 1), id fact) facts)
  ; units
  }
;;

let board_post = "p-0123456789abcdef0123456789abcdef"

let board_ref_post =
  match Types.board_ref_of_ids ~post_id:board_post ~comment_id:None with
  | Ok board -> board
  | Error err -> fail (Types.wire_error_to_string err)
;;

let observed_basis_json = {|{"kind":"observed"}|}

let json_str s = Yojson.Safe.to_string (`String s)

let observed_board_basis_json post_id =
  Printf.sprintf {|{"kind":"observed","board":{"post_id":%s}}|} (json_str post_id)
;;

let answer_json ?(working_state = "null") ops =
  Printf.sprintf
    {|{"question":%s,"question_end":%s,"working_state":%s,"ops":[%s]}|}
    (json_str front) (json_str back) working_state (String.concat "," ops)
;;

let op_add ?(category = "fact") ?(basis = observed_basis_json) ?(from = [ "u1" ]) claim =
  Printf.sprintf
    {|{"op":"add","claim":%s,"category":%s,"basis":%s,"from":[%s]}|}
    (json_str claim) (json_str category) basis
    (String.concat "," (List.map json_str from))
;;

let op_drop ref_ reason =
  Printf.sprintf {|{"op":"drop","ref":%s,"reason":%s}|} (json_str ref_) (json_str reason)
;;

let op_merge ?(category = "fact") ?(basis = observed_basis_json) ?(from = []) refs claim =
  Printf.sprintf
    {|{"op":"merge","refs":[%s],"claim":%s,"category":%s,"basis":%s,"from":[%s]}|}
    (String.concat "," (List.map json_str refs))
    (json_str claim) (json_str category) basis
    (String.concat "," (List.map json_str from))
;;

let op_revise ?(category = "fact") ?(basis = observed_basis_json) ?(from = [ "u1" ]) ref_ claim
  =
  Printf.sprintf
    {|{"op":"revise","ref":%s,"claim":%s,"category":%s,"basis":%s,"from":[%s]}|}
    (json_str ref_) (json_str claim) (json_str category) basis
    (String.concat "," (List.map json_str from))
;;

let read_scored label (case : Scoring.case) text =
  match Scoring.score case text with
  | Scoring.Read reading -> reading
  | Scoring.Thrown_away rejection ->
    failf "%s: thrown away as %s" label (Answer.rejection_kind rejection)
;;

let settle_plan label (case : Scoring.case) text =
  match Answer.of_string ~asked:case.question text with
  | Error rejection ->
    failf "%s: decode rejected as %s" label (Answer.rejection_kind rejection)
  | Ok answer ->
    Plan.of_answer ~shown:case.shown ~facts:case.facts ~removed_since:[] ~at:1795090000.0
      ~trace_id:"l6g-corpus" answer
;;

let has_claim claim (facts : Types.fact list) =
  List.exists (fun (fact : Types.fact) -> String.equal fact.claim claim) facts
;;

let dropped_claims (plan : Plan.t) =
  List.filter_map
    (fun ((fact : Types.fact), (removal : Effects.removal)) ->
       match removal with
       | Effects.Dropped _ -> Some fact.claim
       | Effects.Merged_into _ | Effects.Revised_into _ | Effects.Support_lost _
       | Effects.Superseded_by _ | Effects.Retracted _ -> None)
    plan.effects.removed
;;

let merged_claims (plan : Plan.t) =
  List.filter_map
    (fun ((fact : Types.fact), (removal : Effects.removal)) ->
       match removal with
       | Effects.Merged_into _ -> Some fact.claim
       | Effects.Dropped _ | Effects.Revised_into _ | Effects.Support_lost _
       | Effects.Superseded_by _ | Effects.Retracted _ -> None)
    plan.effects.removed
;;

(* --- Curated L6g Synthetic Corpus --- *)

(* Case 1: Dated usable-until memory where closed unit u1 timestamp
   (2026-11-19T13:00:00Z) is BEFORE target date (2026-11-23). Must NOT drop. *)
let c1_dated_hold =
  held ~first_seen:1794873600.0 ~category:Types.Constraint
    "Hold maintenance reminder until 2026-11-23 deploy freeze ends; drain active keeper jobs first."
;;

let c1_coord = held ~first_seen:1794873600.0 "Release coordinator is platform-team."

let case_upcoming_usable_until : Scoring.case =
  { name = "upcoming usable-until record before closed unit timestamp"
  ; question = asked
  ; shown = shown_of [ c1_dated_hold; c1_coord ]
  ; facts = [ c1_dated_hold; c1_coord ]
  ; planted = [ "8935" ]
  ; must_keep = []
  }
;;

let ans_upcoming_usable_until =
  answer_json [ op_add ~category:"fact" ~from:[ "u1" ] "The build server listens on port 8935." ]
;;

(* Case 2: Same upcoming dated usable-until memory when closed unit u1
   (2026-11-19T14:00:00Z) carries only routine heartbeat with no new facts. *)
let case_upcoming_usable_until_noop : Scoring.case =
  { name = "upcoming usable-until record preserved on empty-change unit"
  ; question = asked
  ; shown = shown_of [ c1_dated_hold; c1_coord ]
  ; facts = [ c1_dated_hold; c1_coord ]
  ; planted = []
  ; must_keep = []
  }
;;

let ans_upcoming_usable_until_noop = answer_json []

(* Case 3: Dated usable-until memory whose closed unit u1 timestamp
   (2026-11-19T09:15:00Z) and unit evidence confirm the 2026-11-18 canary
   completed. Cleanly dropped while standing lesson stays and new constraint
   is added. *)
let c3_completed_canary =
  held ~first_seen:1794873600.0 ~category:Types.Goal
    "Run schema migration canary for release-v4 on 2026-11-18 before promoting traffic."
;;

let c3_lesson =
  held ~first_seen:1794873600.0 ~category:Types.Lesson
    "Canary smoke tests must run with empty cache before traffic shift."
;;

let case_completed_usable_until : Scoring.case =
  { name = "completed usable-until record dropped causally"
  ; question = asked
  ; shown = shown_of [ c3_completed_canary; c3_lesson ]
  ; facts = [ c3_completed_canary; c3_lesson ]
  ; planted = [ "schema version 14" ]
  ; must_keep = []
  }
;;

let ans_completed_usable_until =
  answer_json
    [ op_drop "m1"
        "Closed unit u1 at 2026-11-19T09:15:00Z confirmed the 2026-11-18 release-v4 migration canary completed."
    ; op_add ~category:"constraint" ~from:[ "u1" ]
        "Pin schema version 14 in release-v4 manifests."
    ]
;;

(* Case 4: Cross-category synthesis (Constraint + Preference) into one merged
   fact retaining multi-faceted essence via [must_keep] without silent schema
   rejection. *)
let c4_constraint =
  held ~first_seen:100.0 ~category:Types.Constraint
    "Never run force-push on protected main branches."
;;

let c4_preference =
  held ~first_seen:250.0 ~category:Types.Preference
    "Operator prefers stacked PR branches with gh-stack rebase."
;;

let c4_fact = held ~first_seen:300.0 "Primary build runner uses OCaml 5.5 with Eio."

let case_cross_category_merge : Scoring.case =
  { name = "cross-category Constraint + Preference merge preserves facets"
  ; question = asked
  ; shown = shown_of [ c4_constraint; c4_preference; c4_fact ]
  ; facts = [ c4_constraint; c4_preference; c4_fact ]
  ; planted = [ "top-PR merge" ]
  ; must_keep =
      [ id c4_constraint, [ "force-push"; "main" ]
      ; id c4_preference, [ "stacked PR"; "gh-stack rebase" ]
      ]
  }
;;

let ans_cross_category_merge =
  answer_json
    [ op_merge ~category:"constraint" ~from:[ "u1" ] [ "m1"; "m2" ]
        "Never run force-push on protected main branches; operator prefers stacked PR branches updated with gh-stack rebase and green checks before top-PR merge."
    ]
;;

(* Case 5: Standing architectural identity constraint kept despite old
   first_seen vs transient one-off queue snapshot dropped; Board provenance
   fact added. *)
let c5_identity =
  held ~first_seen:10.0 ~category:Types.Constraint
    "Keeper identity boundary: never edit files outside assigned worktree."
;;

let c5_transient_queue =
  held ~first_seen:200.0 ~category:Types.Fact
    "Queue status snapshot: 3 pending items awaiting CI check at commit abc123."
;;

let c5_approach =
  held ~first_seen:220.0 ~category:Types.Validated_approach
    "Run scoped dune exec inside worktree with --root . to isolate build artifacts."
;;

let case_standing_vs_transient : Scoring.case =
  { name = "standing architectural constraint kept vs transient queue status dropped"
  ; question = asked
  ; shown = shown_of [ c5_identity; c5_transient_queue; c5_approach ]
  ; facts = [ c5_identity; c5_transient_queue; c5_approach ]
  ; planted = [ "One writer fiber" ]
  ; must_keep = []
  }
;;

let ans_standing_vs_transient =
  answer_json
    [ op_drop "m2"
        "Transient point-in-time CI queue snapshot at commit abc123 superseded by closed unit u1 completion."
    ; op_add ~category:"constraint" ~basis:(observed_board_basis_json board_post)
        ~from:[ "u1" ] "One writer fiber per keeper commits memory lines atomically."
    ]
;;

(* Case 6: [revise] replaces [ref] cleanly alongside [working_state] update. *)
let c6_endpoint = held ~first_seen:150.0 "Staging endpoint listens on port 8080."
let c6_snapshot = held ~first_seen:150.0 ~category:Types.Constraint "Use atomic rename for snapshot updates."

let case_revise_working_state : Scoring.case =
  { name = "revise updates endpoint and working_state cleanly"
  ; question = asked
  ; shown = shown_of [ c6_endpoint; c6_snapshot ]
  ; facts = [ c6_endpoint; c6_snapshot ]
  ; planted = [ "9443" ]
  ; must_keep = []
  }
;;

let ans_revise_working_state =
  answer_json
    ~working_state:{|"verify TLS handshakes on port 9443"|}
    [ op_revise ~category:"fact" ~from:[ "u1" ] "m1"
        "Staging endpoint listens on port 9443."
    ]
;;

(* Case 7: [Read_item_alone] mode (shown.memory = None): only [add] +
   [working_state = null] apply cleanly. *)
let case_read_item_alone : Scoring.case =
  { name = "Read_item_alone accepts add with working_state null"
  ; question = asked
  ; shown = { memory = None; units = [ "u1", 10 ] }
  ; facts = [ c5_identity ]
  ; planted = [ "8443" ]
  ; must_keep = []
  }
;;

let ans_read_item_alone =
  answer_json [ op_add ~category:"fact" ~from:[ "u1" ] "Metrics endpoint binds port 8443." ]
;;

(* Case 8: Keeper self-echo of existing Memory / working_state with zero
   external user/stimulus/tool/board confirmation yields empty [ops: []]
   and [working_state: null] (Mem0 #4573 97.8% self-echo loop prevention). *)
let c8_constraint =
  held ~first_seen:90.0 ~category:Types.Constraint
    "Never run force-push on protected main branches."
;;

let c8_endpoint = held ~first_seen:120.0 "Staging endpoint listens on port 9443."

let case_keeper_echo_noop : Scoring.case =
  { name = "keeper self-echo without external confirmation yields empty ops"
  ; question = asked
  ; shown = shown_of [ c8_constraint; c8_endpoint ]
  ; facts = [ c8_constraint; c8_endpoint ]
  ; planted = []
  ; must_keep = []
  }
;;

let ans_keeper_echo_noop = answer_json []

(* Case 9: Targeted contradiction [revise] resolving a relative date
   ("yesterday" relative to unit u1 closed at 2026-11-19T12:00:00Z ->
   2026-11-18) while leaving collateral facts untouched (Graphiti #1728 41%
   collateral drop prevention). *)
let c9_region = held ~first_seen:120.0 "Staging deploy region is us-east-1."

let c9_freeze =
  held ~first_seen:100.0 ~category:Types.Constraint
    "Release freeze runs every Friday at 18:00 UTC."
;;

let c9_worktree =
  held ~first_seen:110.0 "Unit tests execute inside an isolated worktree root."
;;

let case_targeted_contradiction_relative_date : Scoring.case =
  { name = "targeted contradiction revise with relative-to-absolute date resolution"
  ; question = asked
  ; shown = shown_of [ c9_region; c9_freeze; c9_worktree ]
  ; facts = [ c9_region; c9_freeze; c9_worktree ]
  ; planted = [ "eu-west-1"; "2026-11-18" ]
  ; must_keep = []
  }
;;

let ans_targeted_contradiction_relative_date =
  answer_json
    [ op_revise ~category:"fact" ~from:[ "u1" ] "m1"
        "Staging deploy region moved to eu-west-1 on 2026-11-18."
    ]
;;

(* Case 10: Merge preserves progressive aspect, numbers, and dates
   (arXiv 2609.36457 210/381 collapse; arXiv 2608.11775 3.05% temporal
   retention), while keeping user constraints in BOTH Memory facts and literal
   [working_state] claim prose rather than bare mN refs
   (arXiv 2608.22752 47%-90% compaction loss; code-reviewer 0/925 recall). *)
let c10_progressive =
  held ~first_seen:80.0 ~category:Types.Goal
    "Migrating worker pool to Eio domains (3 of 5 shards moved as of 2026-11-18)."
;;

let c10_limit =
  held ~first_seen:140.0 ~category:Types.Constraint
    "Migration batch size must remain at most 2 shards per deploy window."
;;

let case_progressive_merge_and_bridge : Scoring.case =
  { name = "progressive merge preservation and dual constraint working_state bridge"
  ; question = asked
  ; shown = shown_of [ c10_progressive; c10_limit ]
  ; facts = [ c10_progressive; c10_limit ]
  ; planted = [ "rollback gate" ]
  ; must_keep =
      [ id c10_progressive, [ "Migrating"; "3 of 5"; "2026-11-18" ]
      ; id c10_limit, [ "at most 2 shards" ]
      ]
  }
;;

let ans_progressive_merge_and_bridge =
  answer_json
    ~working_state:
      {|"Next: run Shard 4 canary check with rollback gate. Constraint: migration batch size must remain at most 2 shards per deploy window."|}
    [ op_merge ~category:"constraint" ~from:[ "u1" ] [ "m1"; "m2" ]
        "Migrating worker pool to Eio domains (3 of 5 shards moved as of 2026-11-18); batch size must remain at most 2 shards per deploy window."
    ; op_add ~category:"constraint" ~from:[ "u1" ]
        "Require automated rollback gate before promoting Shard 4."
    ]
;;

(* Case 11: Paired contrast (A) — Keeper unknowing reply ("모른다" / "확인 불가")
   without explicit unit contradiction MUST produce empty [ops: []] rather than
   dropping or rewriting existing Memory facts into English boilerplate. *)
let c11_ci_owner =
  held ~first_seen:60.0 ~category:Types.Constraint
    "Core auth CI requires OCAMLRUNPARAM=b on macOS runners."
;;

let c11_endpoint =
  held ~first_seen:95.0 ~category:Types.Fact
    "Primary staging endpoint is staging-eu2.internal."
;;

let case_unknowing_reply_non_erasure : Scoring.case =
  { name = "keeper unknowing reply keeps existing facts untouched"
  ; question = asked
  ; shown = shown_of [ c11_ci_owner; c11_endpoint ]
  ; facts = [ c11_ci_owner; c11_endpoint ]
  ; planted = []
  ; must_keep = []
  }
;;

let ans_unknowing_reply_non_erasure = answer_json []

(* Case 12: Paired contrast (B) — Explicit operator retraction + unit host update
   drops the lifted freeze rule and revises only the superseded endpoint while
   preserving original claim language and unrelated standing preferences. *)
let c12_freeze_rule =
  held ~first_seen:90.0 ~category:Types.Constraint
    "화요일 CI 핫픽스 머지 동결 규칙이 활성화되어 있습니다."
;;

let c12_old_host =
  held ~first_seen:110.0 ~category:Types.Fact
    "스테이징 API 호스트는 https://api-eu1.staging.internal 입니다."
;;

let c12_style =
  held ~first_seen:70.0 ~category:Types.Preference
    "보고는 한국어 핵심 요약 위주로 작성합니다."
;;

let case_explicit_retraction_and_lang_keep : Scoring.case =
  { name = "explicit operator retraction drops target and revises in unit language"
  ; question = asked
  ; shown = shown_of [ c12_freeze_rule; c12_old_host; c12_style ]
  ; facts = [ c12_freeze_rule; c12_old_host; c12_style ]
  ; planted = [ "api-eu2.staging.internal" ]
  ; must_keep = []
  }
;;

let ans_explicit_retraction_and_lang_keep =
  answer_json
    [ op_drop "m1" "Operator explicitly lifted the Tuesday CI hotfix freeze rule."
    ; op_revise ~category:"fact" ~from:[ "u1" ] "m2"
        "스테이징 API 호스트는 https://api-eu2.staging.internal 입니다."
    ]
;;

let corpus : (Scoring.case * string) list =
  [ case_upcoming_usable_until, ans_upcoming_usable_until
  ; case_upcoming_usable_until_noop, ans_upcoming_usable_until_noop
  ; case_completed_usable_until, ans_completed_usable_until
  ; case_cross_category_merge, ans_cross_category_merge
  ; case_standing_vs_transient, ans_standing_vs_transient
  ; case_revise_working_state, ans_revise_working_state
  ; case_read_item_alone, ans_read_item_alone
  ; case_keeper_echo_noop, ans_keeper_echo_noop
  ; case_targeted_contradiction_relative_date, ans_targeted_contradiction_relative_date
  ; case_progressive_merge_and_bridge, ans_progressive_merge_and_bridge
  ; case_unknowing_reply_non_erasure, ans_unknowing_reply_non_erasure
  ; case_explicit_retraction_and_lang_keep, ans_explicit_retraction_and_lang_keep
  ]
;;

(* --- Test cases --- *)

let test_upcoming_usable_until_preserved () =
  let reading =
    read_scored "upcoming" case_upcoming_usable_until ans_upcoming_usable_until
  in
  check int "no ops left out" 0 (List.length reading.not_applied);
  check bool "memory changed by add only" true reading.changed;
  check int "planted token recovered" 1 reading.recovered;
  let plan = settle_plan "upcoming" case_upcoming_usable_until ans_upcoming_usable_until in
  check bool "dated usable-until fact MUST NOT be dropped" true
    (has_claim c1_dated_hold.claim plan.facts);
  check (list string) "nothing dropped" [] (dropped_claims plan);
  let noop_reading =
    read_scored "upcoming noop" case_upcoming_usable_until_noop ans_upcoming_usable_until_noop
  in
  check bool "noop changes nothing" false noop_reading.changed;
  check int "noop drops nothing" 0 (List.length noop_reading.not_applied);
  let noop_plan =
    settle_plan "upcoming noop" case_upcoming_usable_until_noop ans_upcoming_usable_until_noop
  in
  check bool "dated usable-until fact kept on noop" true
    (has_claim c1_dated_hold.claim noop_plan.facts);
  (* Contrast: the pre-2026-11-16 premature-drop mistake removes the upcoming record. *)
  let legacy_mistake =
    answer_json [ op_drop "m1" "one-off maintenance checkpoint" ]
  in
  let mistake_plan =
    settle_plan "legacy mistake" case_upcoming_usable_until legacy_mistake
  in
  check (list string) "naive drop erases upcoming usable-until fact"
    [ c1_dated_hold.claim ] (dropped_claims mistake_plan)
;;

let test_completed_usable_until_dropped () =
  let reading =
    read_scored "completed" case_completed_usable_until ans_completed_usable_until
  in
  check int "no ops left out" 0 (List.length reading.not_applied);
  check bool "memory changed" true reading.changed;
  check int "new constraint recovered" 1 reading.recovered;
  let plan = settle_plan "completed" case_completed_usable_until ans_completed_usable_until in
  check (list string) "completed dated record dropped causally"
    [ c3_completed_canary.claim ] (dropped_claims plan);
  check bool "standing lesson remains" true (has_claim c3_lesson.claim plan.facts);
  check bool "new constraint added" true
    (has_claim "Pin schema version 14 in release-v4 manifests." plan.facts)
;;

let test_cross_category_merge () =
  let reading =
    read_scored "cross-category merge" case_cross_category_merge ans_cross_category_merge
  in
  check int "no ops left out" 0 (List.length reading.not_applied);
  check bool "memory changed" true reading.changed;
  check int "planted token recovered" 1 reading.recovered;
  check (pair int int) "cross-category merge keeps all expected tokens"
    (4, 4) (reading.merge_expected, reading.merge_kept);
  let plan =
    settle_plan "cross-category merge" case_cross_category_merge ans_cross_category_merge
  in
  check (list string) "both Constraint and Preference sources merged"
    [ c4_constraint.claim; c4_preference.claim ] (merged_claims plan);
  check bool "unrelated fact stays" true (has_claim c4_fact.claim plan.facts);
  (match plan.effects.added with
   | [ merged_fact ] ->
     (* #53538 merged on main: merged fact inherits earliest first_seen (100.0 < 250.0). *)
     check (float 0.0) "merged fact inherits earliest first_seen" 100.0 merged_fact.first_seen;
     check (float 0.0) "merged fact updates last_seen to commit time" 1795090000.0
       merged_fact.last_seen
   | added -> failf "expected one merged fact in effects.added, got %d" (List.length added))
;;

let test_standing_vs_transient () =
  let reading =
    read_scored "standing vs transient" case_standing_vs_transient ans_standing_vs_transient
  in
  check int "no ops left out" 0 (List.length reading.not_applied);
  check bool "memory changed" true reading.changed;
  check int "board rule recovered" 1 reading.recovered;
  let plan =
    settle_plan "standing vs transient" case_standing_vs_transient ans_standing_vs_transient
  in
  check bool "standing identity constraint kept" true (has_claim c5_identity.claim plan.facts);
  check bool "validated approach kept" true (has_claim c5_approach.claim plan.facts);
  check (list string) "transient queue status dropped"
    [ c5_transient_queue.claim ] (dropped_claims plan);
  let board_added =
    List.exists
      (fun (fact : Types.fact) ->
         String.equal fact.claim "One writer fiber per keeper commits memory lines atomically."
         && fact.basis = Types.Observed (Types.Board board_ref_post))
      plan.effects.added
  in
  check bool "Board provenance preserved on added fact" true board_added
;;

let test_revise_and_alone_guardrails () =
  let rev_reading =
    read_scored "revise" case_revise_working_state ans_revise_working_state
  in
  check int "revise applies cleanly" 0 (List.length rev_reading.not_applied);
  check int "revised port recovered" 1 rev_reading.recovered;
  check (pair int int) "revise not scored as merge"
    (0, 0) (rev_reading.merge_expected, rev_reading.merge_kept);
  let rev_plan =
    settle_plan "revise" case_revise_working_state ans_revise_working_state
  in
  check bool "working state replaced" true
    (rev_plan.working_state = Plan.Replaced "verify TLS handshakes on port 9443");
  (match rev_plan.effects.added with
   | [ revised_fact ] ->
     check (float 0.0) "revised fact keeps original first_seen" 150.0 revised_fact.first_seen;
     check (float 0.0) "revised fact updates last_seen to commit time" 1795090000.0
       revised_fact.last_seen
   | added -> failf "expected one revised fact in effects.added, got %d" (List.length added));
  (* Guardrail: pairing revise + drop on the same ref causes Ref_used_twice. *)
  let double_ref_answer =
    answer_json
      [ op_revise ~category:"fact" ~from:[ "u1" ] "m1"
          "Staging endpoint listens on port 9443."
      ; op_drop "m1" "redundant drop"
      ]
  in
  let double_reading =
    read_scored "double ref" case_revise_working_state double_ref_answer
  in
  check bool "second op on same ref flagged Ref_used_twice" true
    (double_reading.not_applied = [ Effects.Ref_used_twice ]);
  (* Read_item_alone valid answer vs illegal drop + working_state rewrite. *)
  let alone_reading = read_scored "alone" case_read_item_alone ans_read_item_alone in
  check int "alone add applies" 0 (List.length alone_reading.not_applied);
  check int "alone recovers token" 1 alone_reading.recovered;
  let alone_bad =
    answer_json ~working_state:{|"guessed state"|}
      [ op_drop "m1" "guessed"; op_add ~from:[ "u1" ] "Metrics endpoint binds port 8443." ]
  in
  let alone_bad_reading = read_scored "alone bad" case_read_item_alone alone_bad in
  check bool "drop in Read_item_alone flagged Not_valid_alone" true
    (alone_bad_reading.not_applied = [ Effects.Not_valid_alone ]);
  let alone_bad_plan = settle_plan "alone bad" case_read_item_alone alone_bad in
  check bool "working_state in Read_item_alone flagged Not_valid_alone" true
    (alone_bad_plan.working_state = Plan.Not_valid_alone)
;;

let contains_substring ~needle haystack =
  Astring.String.is_infix ~affix:needle haystack
;;

let test_keeper_echo_noop () =
  let reading = read_scored "keeper echo noop" case_keeper_echo_noop ans_keeper_echo_noop in
  check int "empty ops yields 0 ops" 0 reading.ops;
  check int "no ops left out" 0 (List.length reading.not_applied);
  check bool "memory unchanged on keeper self-echo" false reading.changed;
  let plan = settle_plan "keeper echo noop" case_keeper_echo_noop ans_keeper_echo_noop in
  check bool "working_state remains Kept" true (plan.working_state = Plan.Kept);
  check bool "existing constraint preserved" true (has_claim c8_constraint.claim plan.facts);
  check bool "existing endpoint preserved" true (has_claim c8_endpoint.claim plan.facts);
  check (list string) "nothing dropped" [] (dropped_claims plan)
;;

let test_targeted_contradiction_relative_date () =
  let reading =
    read_scored "targeted contradiction" case_targeted_contradiction_relative_date
      ans_targeted_contradiction_relative_date
  in
  check int "single targeted revise op" 1 reading.ops;
  check int "no ops left out" 0 (List.length reading.not_applied);
  check bool "memory changed" true reading.changed;
  check int "recovered region and absolute date" 2 reading.recovered;
  let plan =
    settle_plan "targeted contradiction" case_targeted_contradiction_relative_date
      ans_targeted_contradiction_relative_date
  in
  check bool "target fact revised with resolved absolute date" true
    (has_claim "Staging deploy region moved to eu-west-1 on 2026-11-18." plan.facts);
  check bool "collateral release freeze constraint untouched" true
    (has_claim c9_freeze.claim plan.facts);
  check bool "collateral worktree fact untouched" true
    (has_claim c9_worktree.claim plan.facts);
  check (list string) "no collateral drops" [] (dropped_claims plan);
  (match plan.effects.added with
   | [ revised ] ->
     check (float 0.0) "targeted revise preserves original first_seen" 120.0 revised.first_seen
   | added -> failf "expected one revised fact in effects.added, got %d" (List.length added))
;;

let test_progressive_merge_and_bridge () =
  let reading =
    read_scored "progressive merge & bridge" case_progressive_merge_and_bridge
      ans_progressive_merge_and_bridge
  in
  check int "merge + dual-constraint add apply cleanly" 0 (List.length reading.not_applied);
  check bool "memory changed" true reading.changed;
  check int "planted rollback gate recovered" 1 reading.recovered;
  check (pair int int) "progressive aspect, numbers, date, and limit kept"
    (4, 4) (reading.merge_expected, reading.merge_kept);
  let plan =
    settle_plan "progressive merge & bridge" case_progressive_merge_and_bridge
      ans_progressive_merge_and_bridge
  in
  (match plan.working_state with
   | Plan.Replaced bridged ->
     check bool "working_state carries literal constraint claim prose" true
       (contains_substring ~needle:"at most 2 shards" bridged);
     check bool "working_state does not rely on bare m1 ref" false
       (contains_substring ~needle:"m1" bridged)
   | Plan.Kept | Plan.Not_valid_alone -> fail "expected replaced working_state bridge");
  check bool "user constraint dual-kept in Memory" true
    (has_claim "Require automated rollback gate before promoting Shard 4." plan.facts);
  check (list string) "both merged inputs recorded cleanly"
    [ c10_progressive.claim; c10_limit.claim ] (merged_claims plan);
  let merged_earliest_kept =
    List.exists
      (fun (fact : Types.fact) ->
         fact.first_seen = 80.0
         && contains_substring ~needle:"Migrating worker pool to Eio domains" fact.claim)
      plan.effects.added
  in
  check bool "progressive merged fact inherits earliest first_seen (80.0)" true merged_earliest_kept
;;

let test_unknowing_reply_non_erasure_and_retraction () =
  let unknowing_reading =
    read_scored "unknowing reply" case_unknowing_reply_non_erasure
      ans_unknowing_reply_non_erasure
  in
  check int "unknowing reply emits 0 ops" 0 unknowing_reading.ops;
  check int "no ops left out on unknowing reply" 0
    (List.length unknowing_reading.not_applied);
  check bool "unknowing reply leaves memory unchanged" false unknowing_reading.changed;
  let unknowing_plan =
    settle_plan "unknowing reply" case_unknowing_reply_non_erasure
      ans_unknowing_reply_non_erasure
  in
  check bool "CI constraint kept on unknowing reply" true
    (has_claim c11_ci_owner.claim unknowing_plan.facts);
  check bool "endpoint fact kept on unknowing reply" true
    (has_claim c11_endpoint.claim unknowing_plan.facts);
  check (list string) "unknowing reply drops nothing" [] (dropped_claims unknowing_plan);
  (* Contrast: overwriting m1 with English failure boilerplate destroys c11_ci_owner. *)
  let bad_overwrite =
    answer_json
      [ op_revise ~category:"constraint" ~from:[ "u1" ] "m1"
          "Provided context lacks CI failure details."
      ]
  in
  let bad_plan =
    settle_plan "unknowing boilerplate overwrite" case_unknowing_reply_non_erasure
      bad_overwrite
  in
  check bool "boilerplate revise erases original constraint" false
    (has_claim c11_ci_owner.claim bad_plan.facts);
  let retract_reading =
    read_scored "explicit retraction" case_explicit_retraction_and_lang_keep
      ans_explicit_retraction_and_lang_keep
  in
  check int "explicit retraction + host revise emits 2 ops" 2 retract_reading.ops;
  check int "no ops left out on retraction" 0 (List.length retract_reading.not_applied);
  check bool "explicit retraction changes memory" true retract_reading.changed;
  check int "updated staging host recovered" 1 retract_reading.recovered;
  let retract_plan =
    settle_plan "explicit retraction" case_explicit_retraction_and_lang_keep
      ans_explicit_retraction_and_lang_keep
  in
  check (list string) "lifted freeze rule dropped"
    [ c12_freeze_rule.claim ] (dropped_claims retract_plan);
  check bool "revised host preserves Korean unit phrasing" true
    (has_claim "스테이징 API 호스트는 https://api-eu2.staging.internal 입니다."
       retract_plan.facts);
  check bool "unrelated Korean style preference kept untouched" true
    (has_claim c12_style.claim retract_plan.facts);
  (match retract_plan.effects.added with
   | [ revised ] ->
     check (float 0.0) "revised host preserves original first_seen" 110.0
       revised.first_seen
   | added -> failf "expected one revised host fact, got %d" (List.length added))
;;

let expected_corpus_tally =
  {|answers 12
thrown away 0
ops 13
ops left out 0
answers that changed Memory 9
planted 10, in Memory afterwards 10
merged away 8, kept by the merge 8
|}
;;

let test_corpus_tally_pinned () =
  let scored = List.map (fun (case, ans) -> case, Scoring.score case ans) corpus in
  let tally = Scoring.tally scored in
  let rendered = Scoring.tally_to_text tally in
  Printf.printf "\n[L6g synthetic corpus tally]\n%s%!" rendered;
  check string "L6g synthetic corpus tally" expected_corpus_tally rendered;
  check int "zero thrown away" 0 (List.length tally.thrown_away);
  check int "zero ops left out" 0 (List.length tally.not_applied);
  check int "all planted tokens recovered" tally.planted tally.recovered;
  check int "all cross-category & progressive merge tokens kept"
    tally.merge_expected tally.merge_kept
;;

let test_legacy_prompt_untouched () =
  let old_l6_path = Masc_test_deps.source_path "config/prompts/librarian-l6.md" in
  let legacy_path = Masc_test_deps.source_path "config/prompts/librarian.md" in
  check bool "old config/prompts/librarian-l6.md removed" false (Sys.file_exists old_l6_path);
  check bool "config/prompts/librarian.md exists" true (Sys.file_exists legacy_path);
  let legacy_text = Masc_test_deps.read_file legacy_path in
  (* Verify legacy prompt remains untouched with legacy wire schema tokens. *)
  List.iter
    (fun legacy_token ->
       check bool ("legacy librarian.md retains " ^ legacy_token) true
         (contains_substring ~needle:legacy_token legacy_text))
    [ "new_claims"; "supersedes"; "absorbs"; "working_contexts"; "admission_policy" ];
  (* Verify Prompt_registry loads the legacy prompt cleanly and keeps librarian-l6 absent. *)
  Prompt_registry.clear ();
  Prompt_registry.set_markdown_dir (Masc_test_deps.source_path "config/prompts");
  Masc.Prompt_defaults.init ();
  Fun.protect
    ~finally:Prompt_registry.clear
    (fun () ->
       check bool "old librarian-l6 key is Missing" true
         (match Prompt_registry.prompt_source "librarian-l6" with
          | Prompt_registry.Missing -> true
          | Prompt_registry.File | Prompt_registry.Override -> false);
       check bool "legacy librarian key resolves from File source" true
         (match Prompt_registry.prompt_source "librarian" with
          | Prompt_registry.File -> true
          | Prompt_registry.Override | Prompt_registry.Missing -> false);
       let legacy_issues =
         Prompt_registry.validate_prompt_templates ()
         |> List.filter (fun (key, (_ : string)) -> String.equal key "librarian")
       in
       check int "legacy librarian prompt has zero undeclared template variables" 0
         (List.length legacy_issues))
;;

let () =
  run "librarian_l6g_scoring"
    [ ( "corpus"
      , [ test_case "upcoming usable-until preserved before closed unit timestamp" `Quick
            test_upcoming_usable_until_preserved
        ; test_case "completed usable-until dropped causally" `Quick
            test_completed_usable_until_dropped
        ; test_case "cross-category merge preserves multi-faceted essence" `Quick
            test_cross_category_merge
        ; test_case "standing identity constraints kept vs transient queue status dropped"
            `Quick test_standing_vs_transient
        ; test_case "revise and Read_item_alone guardrails" `Quick
            test_revise_and_alone_guardrails
        ; test_case "keeper self-echo without external confirmation yields empty ops"
            `Quick test_keeper_echo_noop
        ; test_case "targeted contradiction revise and relative date resolution"
            `Quick test_targeted_contradiction_relative_date
        ; test_case "progressive merge preservation and working_state bridge"
            `Quick test_progressive_merge_and_bridge
        ; test_case "paired unknowing-reply non-erasure vs explicit operator retraction"
            `Quick test_unknowing_reply_non_erasure_and_retraction
        ; test_case "synthetic corpus tally pinned via Librarian_scoring" `Quick
            test_corpus_tally_pinned
        ] )
    ; ( "legacy_prompt_guard"
      , [ test_case "legacy librarian.md untouched and librarian-l6 removed"
            `Quick test_legacy_prompt_untouched
        ] )
    ]
;;
