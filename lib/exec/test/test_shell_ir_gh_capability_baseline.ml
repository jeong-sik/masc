(** G-0 baseline harness — RFC-0309 typed gh capability gating.

    Characterization corpus: pins the CURRENT classification of the gh
    capability surface, including known defects, so that each RFC-0309
    slice produces a measurable, reviewable delta in this file.

    This file asserts what the classifier DOES, not what it SHOULD do.
    Defect-tagged cases pin behavior RFC-0309 will change:

    - [Defect_policy_as_risk] — factually reversible operations labeled
      [R2_Irreversible] by PR #23362 to express a capability-policy
      decision on the risk axis. Target (G-4/G-9): R1 + external effect
      + [Requires_approval] disposition.
    - [Defect_unknown_permissive] — gh verbs/actions absent from the
      word-list tables that still compose to [R0_Read] and auto-run under
      the autonomous overlay.
    - [Fail_closed_opinion] — W1 landed: the typed gh family
      ([Shell_ir_risk.risk_of_gh_verb]) now gives a wholly-unrecognized gh
      area ([Gh_verb.Other]) an [R2_Irreversible] typed opinion, which
      [classify] lifts into the composed risk. This is OBSERVABILITY only:
      the keeper approval floor reads the word-list classifier, not this
      composed opinion (see [test_word_list_surface], which still pins the
      floor at [R0_Read] for the same inputs). Enforcement of these lands
      in W3 (unknown gh -> non-blocking approval).

    Update protocol: when a slice lands, move its cases to the constructor
    matching the new state and update the ledger counts in [test_ledger].
    The ledger diff IS the slice's measured delta; do not silence a
    mismatch by deleting a case. *)

module Parsed = Masc_exec.Parsed
module Shell_ir = Masc_exec.Shell_ir
module Shell_ir_risk = Masc_exec.Shell_ir_risk
module Shell_ir_typed = Masc_exec.Shell_ir_typed
module Bash = Masc_exec_bash_parser.Bash

let parse_ir cmd =
  match Bash.parse_string cmd with
  | Parsed.Parsed ir -> ir
  | Parsed.Parse_error _ | Parsed.Parse_aborted _ | Parsed.Too_complex _ ->
    Alcotest.failf "failed to parse: %s" cmd
;;

(* Full production pipeline: parser -> classify (typed opinion max-merged
   with the word-list floor and redirect floor). *)
let classify_cmd cmd =
  Shell_ir_risk.risk_class
    (Shell_ir_risk.classify (Shell_ir_risk.undecided (parse_ir cmd)))
;;

(* Typed-path opinion alone, before the word-list floor merges in. *)
let typed_opinion cmd =
  match parse_ir cmd with
  | Shell_ir.Simple s ->
    Shell_ir_risk.risk_of_typed (Shell_ir_typed.of_simple s)
  | Shell_ir.Pipeline _ ->
    Alcotest.failf "expected a simple command: %s" cmd
;;

let rc = Shell_ir_risk.string_of_risk_class

type expectation =
  | Stable of Shell_ir_risk.risk_class
      (** Current class = RFC-0309 target class. No change expected. *)
  | Defect_policy_as_risk of Shell_ir_risk.risk_class
      (** Pinned current class for a factually reversible operation that
          PR #23362 placed in [repo_hosting_cli_irreversible_ops] (or the
          graphql R2 fragment list) to express policy. *)
  | Defect_unknown_permissive of Shell_ir_risk.risk_class
      (** Pinned current class for a verb/action absent from the word-list
          tables that still composes to R0 and auto-runs. *)
  | Fail_closed_opinion of Shell_ir_risk.risk_class
      (** W1 landed: composed risk lifted by the typed [Gh_verb.Other]
          fail-closed opinion. Observability only — the approval floor
          (word-list) is unchanged; enforcement is W3. *)

let pinned_class = function
  | Stable c | Defect_policy_as_risk c | Defect_unknown_permissive c
  | Fail_closed_opinion c ->
    c
;;

let corpus : (string * string * expectation) list =
  [
    (* --- reads: stable R0 ------------------------------------------- *)
    ("pr-view", "gh pr view 123", Stable Shell_ir_risk.R0_Read);
    ("pr-list", "gh pr list --state open", Stable Shell_ir_risk.R0_Read);
    ("issue-view", "gh issue view 7", Stable Shell_ir_risk.R0_Read);
    ("repo-view", "gh repo view owner/repo", Stable Shell_ir_risk.R0_Read);
    ("api-get", "gh api repos/owner/repo", Stable Shell_ir_risk.R0_Read);
    (* Post-W1 this is a DECIDED read: the typed [Gh_verb.Discussion] family
       with a table-absent action ("view") opines R0, matching the floor. *)
    ("discussion-view", "gh discussion view 42", Stable Shell_ir_risk.R0_Read);
    (* --- reversible mutations: stable R1 ----------------------------- *)
    ("pr-create", "gh pr create --title T --body B",
     Stable Shell_ir_risk.R1_Reversible_mutation);
    ("pr-comment", "gh pr comment 123 --body B",
     Stable Shell_ir_risk.R1_Reversible_mutation);
    ("issue-create", "gh issue create --title T",
     Stable Shell_ir_risk.R1_Reversible_mutation);
    ("issue-edit", "gh issue edit 123",
     Stable Shell_ir_risk.R1_Reversible_mutation);
    ("release-create", "gh release create v1.0.0",
     Stable Shell_ir_risk.R1_Reversible_mutation);
    (* --- genuinely irreversible: stable R2 (floor stands, RFC-0309
       does not soften Deny) ------------------------------------------- *)
    ("pr-merge", "gh pr merge 123 --squash", Stable Shell_ir_risk.R2_Irreversible);
    (* pre-existing floor: `pr ready --undo` exists, but ready triggers
       external side-effects (CI, notifications). Revisit under the G-4
       externality axis; out of W0 scope. *)
    ("pr-ready", "gh pr ready 123", Stable Shell_ir_risk.R2_Irreversible);
    ("repo-delete", "gh repo delete owner/repo --yes",
     Stable Shell_ir_risk.R2_Irreversible);
    ("repo-archive", "gh repo archive owner/repo",
     Stable Shell_ir_risk.R2_Irreversible);
    ("repo-transfer", "gh repo transfer owner/repo",
     Stable Shell_ir_risk.R2_Irreversible);
    ("api-delete", "gh api repos/owner/repo -X DELETE",
     Stable Shell_ir_risk.R2_Irreversible);
    ("graphql-deleteDiscussion",
     "gh api graphql -f 'query=mutation{deleteDiscussion}'",
     Stable Shell_ir_risk.R2_Irreversible);
    ("discussion-delete", "gh discussion delete 42",
     Stable Shell_ir_risk.R2_Irreversible);
    (* --- W4/G-9 FIXED: #23362's policy-as-risk closed. These reversible ops
       now classify R1; the "keeper may not do this unsupervised" decision moved
       to the capability axis ([Gh_capability_policy] -> Requires_approval).
       Was [Defect_policy_as_risk R2]; now [Stable R1]. --------------------- *)
    ("repo-create", "gh repo create owner/new-repo",
     Stable Shell_ir_risk.R1_Reversible_mutation);
    ("repo-fork", "gh repo fork owner/repo",
     Stable Shell_ir_risk.R1_Reversible_mutation);
    ("discussion-create", "gh discussion create --title T --body B",
     Stable Shell_ir_risk.R1_Reversible_mutation);
    ("discussion-comment", "gh discussion comment 42 --body B",
     Stable Shell_ir_risk.R1_Reversible_mutation);
    ("discussion-edit", "gh discussion edit 42 --body B",
     Stable Shell_ir_risk.R1_Reversible_mutation);
    ("discussion-close", "gh discussion close 42",
     Stable Shell_ir_risk.R1_Reversible_mutation);
    ("graphql-createRepository",
     "gh api graphql -f 'query=mutation{createRepository}'",
     Stable Shell_ir_risk.R1_Reversible_mutation);
    ("graphql-createDiscussion",
     "gh api graphql -f 'query=mutation{createDiscussion}'",
     Stable Shell_ir_risk.R1_Reversible_mutation);
    ("graphql-addDiscussionComment",
     "gh api graphql -f 'query=mutation{addDiscussionComment}'",
     Stable Shell_ir_risk.R1_Reversible_mutation);
    (* --- W1: wholly-unrecognized gh area -> fail-closed typed opinion.
       Composed risk is now R2 (was R0). Observability only: the approval
       floor still reads these as R0 (see test_word_list_surface). --------- *)
    ("unknown-verb", "gh frobnicate now",
     Fail_closed_opinion Shell_ir_risk.R2_Irreversible);
    ("unknown-verb-forced", "gh quantum entangle --force",
     Fail_closed_opinion Shell_ir_risk.R2_Irreversible);
    ("unknown-verb-preview", "gh preview enable-feature x",
     Fail_closed_opinion Shell_ir_risk.R2_Irreversible);
    (* --- Residual defect (NOT fixed by W1): a known family with an
       unknown action. We cannot distinguish "gh repo upsert-magic" from a
       read ("gh repo view") without a reads table, so fail-closing here
       would over-block reads. Stays R0; deferred to W3, where an unknown
       action routes to non-blocking approval instead of auto-run. -------- *)
    (* Known-family unknown-action: the RISK axis keeps this R0 (its
       reversibility is genuinely unknown — not fabricated). The
       auto-run GAP is now CLOSED on the CAPABILITY axis
       (Gh_capability_policy.disposition_of -> Requires_approval), proven in
       test_gh_capability_policy and test_approval_policy. So this is no longer
       a permissive DEFECT on the risk axis; it is the intended honest R0. *)
    ("unknown-repo-action", "gh repo upsert-magic owner/repo",
     Stable Shell_ir_risk.R0_Read);
  ]
;;

(* Every corpus case classifies to its pinned class. A mismatch means the
   classifier changed: update the case per the header protocol so the
   diff records the delta. *)
let test_corpus_pinned () =
  let mismatches =
    List.filter_map
      (fun (label, cmd, exp) ->
         let actual = classify_cmd cmd in
         let expected = pinned_class exp in
         if actual = expected then None
         else
           Some
             (Printf.sprintf "%s: %S pinned %s, got %s" label cmd
                (rc expected) (rc actual)))
      corpus
  in
  if mismatches <> [] then
    Alcotest.fail
      ("classifier drifted from G-0 baseline:\n"
       ^ String.concat "\n" mismatches)
;;

(* W1: the typed path no longer abstains on gh. [risk_of_typed] reads the
   [Gh_verb] family and returns a verb-based opinion that equals the word-list
   floor for known families and fail-closes ([Gh_verb.Other] -> R2) for an
   unrecognized area. [Api] stays R0 (its -X/graphql risk is string-borne and
   floor-owned). Every gh command still lowers to a typed Gh hit. *)
let test_typed_path_verb_opinion () =
  let check cmd expected =
    let opinion = typed_opinion cmd in
    if opinion <> expected then
      Alcotest.failf "typed opinion for %S: pinned %s, got %s" cmd
        (rc expected) (rc opinion);
    if not (Shell_ir_risk.typed_hit_of_ir (parse_ir cmd)) then
      Alcotest.failf "expected %S to lower to a typed Gh hit" cmd
  in
  check "gh pr view 123" Shell_ir_risk.R0_Read;
  check "gh pr create --title T" Shell_ir_risk.R1_Reversible_mutation;
  check "gh pr merge 123" Shell_ir_risk.R2_Irreversible;
  (* W4/G-9: repo create is reversible (R1); the capability axis carries the
     "requires approval" decision. Was R2 under #23362. *)
  check "gh repo create owner/new-repo" Shell_ir_risk.R1_Reversible_mutation;
  check "gh repo delete owner/repo" Shell_ir_risk.R2_Irreversible;
  check "gh discussion comment 42 --body B" Shell_ir_risk.R1_Reversible_mutation;
  (* api: typed opinion stays R0; the word-list floor owns -X/graphql risk. *)
  check "gh api repos/owner/repo -X DELETE" Shell_ir_risk.R0_Read;
  (* wholly-unrecognized area: fail-closed typed opinion. *)
  check "gh frobnicate now" Shell_ir_risk.R2_Irreversible
;;

(* Word-list surface directly (no parser): the fall-through and the
   policy conflation are properties of this table, not of the parser. *)
let test_word_list_surface () =
  let check words expected =
    let actual = Shell_ir_risk.classify_repo_hosting_cli words in
    if actual <> expected then
      Alcotest.failf "classify_repo_hosting_cli [%s]: pinned %s, got %s"
        (String.concat "; " words) (rc expected) (rc actual)
  in
  check [ "gh"; "frobnicate"; "now" ] Shell_ir_risk.R0_Read;
  check [ "gh"; "repo"; "upsert-magic"; "owner/repo" ] Shell_ir_risk.R0_Read;
  (* W4/G-9: discussion close is reversible (R1); discussion delete stays R2. *)
  check [ "gh"; "discussion"; "close"; "42" ] Shell_ir_risk.R1_Reversible_mutation;
  check [ "gh"; "discussion"; "delete"; "42" ] Shell_ir_risk.R2_Irreversible
;;

(* Ledger ratchet: exact distribution over the corpus. A slice that fixes
   a defect must update these counts — the diff is the measured delta. *)
let test_ledger () =
  let count pred = List.length (List.filter pred corpus) in
  let by_class c = count (fun (_, _, e) -> pinned_class e = c) in
  let r0 = by_class Shell_ir_risk.R0_Read in
  let r1 = by_class Shell_ir_risk.R1_Reversible_mutation in
  let r2 = by_class Shell_ir_risk.R2_Irreversible in
  let dp = by_class Shell_ir_risk.Destructive_protected in
  let policy_as_risk =
    count (fun (_, _, e) ->
      match e with Defect_policy_as_risk _ -> true | _ -> false)
  in
  let unknown_permissive =
    count (fun (_, _, e) ->
      match e with Defect_unknown_permissive _ -> true | _ -> false)
  in
  let fail_closed_opinion =
    count (fun (_, _, e) ->
      match e with Fail_closed_opinion _ -> true | _ -> false)
  in
  Printf.printf
    "[G-0->W1] corpus=%d R0=%d R1=%d R2=%d DP=%d | defects: policy_as_risk=%d \
     unknown_permissive=%d | fail_closed_opinion=%d\n"
    (List.length corpus) r0 r1 r2 dp policy_as_risk unknown_permissive
    fail_closed_opinion;
  Alcotest.(check int) "corpus size" 32 (List.length corpus);
  (* W4/G-9 delta vs W1: the 9 policy-as-risk cases moved R2->R1 (repo
     create/fork, discussion create/comment/edit/close, graphql create x3), so
     R1 5->14, R2 20->11, and policy_as_risk 9->0 — the #23362 defect is closed. *)
  Alcotest.(check int) "R0 count" 7 r0;
  Alcotest.(check int) "R1 count" 14 r1;
  Alcotest.(check int) "R2 count" 11 r2;
  Alcotest.(check int) "Destructive count" 0 dp;
  Alcotest.(check int) "defect: policy-as-risk (CLOSED by W4)" 0 policy_as_risk;
  (* Was 1 (unknown-repo-action). CLOSED: the auto-run gap moved to the
     capability axis (Requires_approval); the risk R0 is now intended, so the
     corpus carries zero permissive defects. *)
  Alcotest.(check int) "defect: unknown-permissive (CLOSED, capability-gated)" 0
    unknown_permissive;
  Alcotest.(check int) "W1: fail-closed opinion" 3 fail_closed_opinion
;;

let () =
  Alcotest.run "shell_ir_gh_capability_baseline"
    [
      ( "g0-baseline",
        [
          Alcotest.test_case "corpus pinned" `Quick test_corpus_pinned;
          Alcotest.test_case "typed path verb opinion" `Quick
            test_typed_path_verb_opinion;
          Alcotest.test_case "word-list surface" `Quick test_word_list_surface;
          Alcotest.test_case "ledger ratchet" `Quick test_ledger;
        ] );
    ]
;;
