(** CI/dashboard hardening source guards. *)

open Alcotest

let source_root () =
  match Sys.getenv_opt "DUNE_SOURCEROOT" with
  | Some root -> root
  | None -> Sys.getcwd ()

let source_path file_rel = Filename.concat (source_root ()) file_rel

let file_contains_pattern file_rel pattern =
  let path = source_path file_rel in
  if not (Sys.file_exists path) then false
  else
    let ic = open_in path in
    Fun.protect
      ~finally:(fun () -> close_in_noerr ic)
      (fun () ->
        let content = In_channel.input_all ic in
        if String.length pattern = 0 then true
        else
          let re = Str.regexp_string pattern in
          (try ignore (Str.search_forward re content 0); true
           with Not_found -> false))

let file_not_contains_pattern file_rel pattern =
  not (file_contains_pattern file_rel pattern)

let guarded_file_not_contains_pattern file_rel pattern =
  Sys.file_exists (source_path file_rel)
  && file_not_contains_pattern file_rel pattern

let file_contains_line_with_patterns file_rel patterns =
  let path = source_path file_rel in
  if not (Sys.file_exists path) then false
  else
    let ic = open_in path in
    Fun.protect
      ~finally:(fun () -> close_in_noerr ic)
      (fun () ->
        let line_matches line =
          List.for_all
            (fun pattern ->
               let re = Str.regexp_string pattern in
               try ignore (Str.search_forward re line 0); true
               with Not_found -> false)
            patterns
        in
        let rec loop () =
          match input_line ic with
          | line -> line_matches line || loop ()
          | exception End_of_file -> false
        in
        loop ())

let file_contains_nearby_line_with_patterns file_rel ~anchor ~patterns ~max_lines =
  let path = source_path file_rel in
  if not (Sys.file_exists path) then false
  else
    let ic = open_in path in
    Fun.protect
      ~finally:(fun () -> close_in_noerr ic)
      (fun () ->
        let line_contains pattern line =
          let re = Str.regexp_string pattern in
          try ignore (Str.search_forward re line 0); true with Not_found -> false
        in
        let line_matches line =
          List.for_all (fun pattern -> line_contains pattern line) patterns
        in
        let rec scan_remaining remaining =
          if remaining < 0 then false
          else
            match input_line ic with
            | line -> line_matches line || scan_remaining (remaining - 1)
            | exception End_of_file -> false
        in
        let rec loop () =
          match input_line ic with
          | line ->
              if line_contains anchor line then scan_remaining max_lines
              else loop ()
          | exception End_of_file -> false
        in
        loop ())

let file_pattern_position file_rel pattern =
  let path = source_path file_rel in
  if not (Sys.file_exists path) then None
  else
    let ic = open_in path in
    Fun.protect
      ~finally:(fun () -> close_in_noerr ic)
      (fun () ->
        let content = In_channel.input_all ic in
        let re = Str.regexp_string pattern in
        try Some (Str.search_forward re content 0) with Not_found -> None)

let file_pattern_position_after file_rel ~anchor pattern =
  let path = source_path file_rel in
  if not (Sys.file_exists path) then None
  else
    let ic = open_in path in
    Fun.protect
      ~finally:(fun () -> close_in_noerr ic)
      (fun () ->
        let content = In_channel.input_all ic in
        let anchor_re = Str.regexp_string anchor in
        let pattern_re = Str.regexp_string pattern in
        try
          let anchor_pos = Str.search_forward anchor_re content 0 in
          Some (Str.search_forward pattern_re content anchor_pos)
        with Not_found -> None)

let quote = Filename.quote

let run_agent_draft_policy env =
  let env_prefix =
    env
    |> List.map (fun (k, v) -> Printf.sprintf "%s=%s" k (quote v))
    |> String.concat " "
  in
  let script =
    Filename.concat (source_root ()) "scripts/ci/check-agent-draft-policy.sh"
  in
  let cmd =
    Printf.sprintf "cd %s && %s bash %s >/dev/null 2>&1"
      (quote (source_root ())) env_prefix (quote script)
  in
  Sys.command cmd

let test_ci_sync_and_asset_contracts () =
  check bool "pr sync script added" true
    (file_contains_pattern "scripts/check-pr-sync.sh" "workflow payload head");
  check bool "pr sync script falls back to pull ref" true
    (file_contains_pattern "scripts/check-pr-sync.sh" "refs/pull/${pr_number}/head");
  check bool "ci workflow verifies pr sync" true
    (file_contains_pattern ".github/workflows/ci.yml" "Verify PR sync");
  check bool "ci workflow passes pr number to sync check" true
    (file_contains_pattern ".github/workflows/ci.yml" "--pr-number \"$PR_NUMBER\"");
  check bool "ci workflow still listens for PR readiness state events" true
    (file_contains_pattern ".github/workflows/ci.yml" "ready_for_review");
  check bool "ci workflow does not cancel builds on readiness state events" true
    (file_contains_pattern ".github/workflows/ci.yml"
       {|contains(fromJSON('["opened","synchronize","reopened"]'), github.event.action)|});
  check bool "pr automation owns PR readiness policy" true
    (file_contains_pattern ".github/workflows/pr-automation.yml"
       "ready_for_review");
  check bool "ci gate enforces agent draft policy" true
    (file_contains_pattern ".github/workflows/ci.yml"
       "Enforce agent draft policy on merge gate");
  check bool "ci gate uses agent draft policy script" true
    (file_contains_pattern ".github/workflows/ci.yml"
       "scripts/ci/check-agent-draft-policy.sh");
  check bool "ci gate refreshes live draft state" true
    (file_contains_pattern ".github/workflows/ci.yml" "PR_LIVE_IS_DRAFT");
  check bool "ci gate refreshes live labels" true
    (file_contains_pattern ".github/workflows/ci.yml" "PR_LIVE_LABELS");
  (* #10192: ci gate must also pass live PR state to the
     policy script so already-merged PRs do not flip red. *)
  check bool "ci gate refreshes live PR state" true
    (file_contains_pattern ".github/workflows/ci.yml" "PR_LIVE_STATE");
  check bool "ci workflow has live PR gate before heavy matrix" true
    (file_contains_pattern ".github/workflows/ci.yml" "pr-live-gate:");
  check bool "live PR gate has explicit pull request read permission" true
    (file_contains_pattern ".github/workflows/ci.yml"
       "pull-requests: read");
  check bool "live PR gate can run after skipped non-PR sync check" true
    (file_contains_pattern ".github/workflows/ci.yml"
       "always() && !cancelled() && (needs.pr-sync-check.result == 'success' || needs.pr-sync-check.result == 'skipped')");
  check bool "live PR gate defaults non-PR triggers to heavy CI" true
    (file_contains_pattern ".github/workflows/ci.yml"
       {|[ "${GITHUB_EVENT_NAME}" != "pull_request" ]|});
  check bool "live PR gate waits for draft automation to settle" true
    (file_contains_pattern ".github/workflows/ci.yml"
       "LIVE_PR_GATE_SETTLE_SEC");
  check bool "live PR gate annotates gh lookup failures" true
    (file_contains_pattern ".github/workflows/ci.yml"
       {|if ! live_fields="$(gh pr view "$PR_NUMBER"|});
  check bool "heavy CI uses live PR gate output" true
    (file_contains_pattern ".github/workflows/ci.yml"
       "needs.pr-live-gate.outputs.run_heavy == 'true'");
  check bool "heavy CI waits for changed-surface detection" true
    (file_contains_pattern ".github/workflows/ci.yml"
       "needs.changes.result == 'success'");
  check bool "ci gate allows skipped live PR gate on non-PR triggers" true
    (file_contains_pattern ".github/workflows/ci.yml"
       {|"$result" == "success" || "$result" == "skipped"|});
  check bool "ci gate aggregates live PR gate" true
    (file_contains_pattern ".github/workflows/ci.yml"
       "PR_LIVE_GATE_RESULT");
  check bool "meta guards verify main branch protection drift" true
    (file_contains_pattern ".github/workflows/ci.yml"
       "bash scripts/ci/check-main-branch-protection.sh");
  check bool "branch protection drift check exists" true
    (file_contains_pattern "scripts/ci/check-main-branch-protection.sh"
       "enforce_admins.enabled");
  check bool "branch protection drift check requires draft guard context" true
    (file_contains_pattern "scripts/ci/check-main-branch-protection.sh"
       "Draft Auto-Merge Guard");
  check bool "branch protection drift check requires CI gate context" true
    (file_contains_pattern "scripts/ci/check-main-branch-protection.sh"
       "CI Gate");
  check bool "heavy CI no longer trusts stale draft payload" true
    (file_not_contains_pattern ".github/workflows/ci.yml"
       "github.event.pull_request.draft == false");
  check bool "pr hygiene no longer checks dashboard assets (gitignored)" true
    (not (file_contains_pattern "scripts/check-pr-hygiene.sh" "dashboard source or Vite config changed but assets/dashboard was not updated"))

let test_agent_draft_policy_script () =
  let base =
    [
      ("GITHUB_EVENT_NAME", "pull_request");
      ("PR_TITLE", "fix: keep long turns visibly alive");
      ("PR_HEAD_REF", "codex/keeper-process-evidence");
      ("PR_LABELS", "");
    ]
  in
  check int "non pull_request events are ignored" 0
    (run_agent_draft_policy [ ("GITHUB_EVENT_NAME", "push") ]);
  check bool "draft agent PR without bypass fails closed" true
    (run_agent_draft_policy (("PR_IS_DRAFT", "true") :: base) <> 0);
  check bool "live draft state does not bypass approval gate" true
    (run_agent_draft_policy
       (("PR_LIVE_IS_DRAFT", "true") :: ("PR_IS_DRAFT", "false") :: base)
    <> 0);
  check bool "live ready state overrides stale draft event" true
    (run_agent_draft_policy
       (("PR_LIVE_IS_DRAFT", "false") :: ("PR_IS_DRAFT", "true") :: base)
    <> 0);
  check int "live bypass label overrides stale event labels" 0
    (run_agent_draft_policy
       (("PR_LIVE_IS_DRAFT", "false")
       :: ("PR_LIVE_LABELS", "enhancement,human-approved-ready")
       :: ("PR_IS_DRAFT", "true")
       :: base));
  check bool "ready agent PR without bypass fails" true
    (run_agent_draft_policy (("PR_IS_DRAFT", "false") :: base) <> 0);
  check bool "ready feature PR with agent-pr label fails" true
    (run_agent_draft_policy
       [
         ("GITHUB_EVENT_NAME", "pull_request");
         ("PR_IS_DRAFT", "false");
         ("PR_TITLE", "feat: ordinary feature title");
         ("PR_HEAD_REF", "feature/dashboard-fsm-audit-exposure");
         ("PR_LABELS", "enhancement,agent-pr");
       ]
    <> 0);
  check int "ready agent PR with bypass label passes" 0
    (run_agent_draft_policy
       (("PR_IS_DRAFT", "false")
       :: ("PR_LABELS", "enhancement,human-approved-ready")
       :: List.remove_assoc "PR_LABELS" base));
  check bool "hard-stop label overrides bypass label" true
    (run_agent_draft_policy
       (("PR_IS_DRAFT", "false")
       :: ("PR_LABELS", "enhancement,human-approved-ready,do-not-merge")
       :: List.remove_assoc "PR_LABELS" base)
    <> 0);
  check int "draft agent PR with bypass label passes" 0
    (run_agent_draft_policy
       (("PR_IS_DRAFT", "true")
       :: ("PR_LABELS", "enhancement,human-approved-ready")
       :: List.remove_assoc "PR_LABELS" base));
  check int "ready non-agent PR passes" 0
    (run_agent_draft_policy
       [
         ("GITHUB_EVENT_NAME", "pull_request");
         ("PR_IS_DRAFT", "false");
         ("PR_TITLE", "fix: human authored branch");
         ("PR_HEAD_REF", "feature/human-branch");
         ("PR_LABELS", "enhancement");
       ]);
  check bool "hard-stop label fails non-agent PR too" true
    (run_agent_draft_policy
       [
         ("GITHUB_EVENT_NAME", "pull_request");
         ("PR_IS_DRAFT", "false");
         ("PR_TITLE", "fix: human authored branch");
         ("PR_HEAD_REF", "feature/human-branch");
         ("PR_LABELS", "enhancement,do-not-merge");
       ]
    <> 0);
  (* #10192: post-merge gate race.  When the live PR state is
     MERGED or CLOSED, the policy is moot (the merge already
     happened) and a missing bypass label must NOT resurrect a
     red check on a shipped PR. *)
  check int "ready agent PR with live state MERGED is skipped" 0
    (run_agent_draft_policy
       (("PR_IS_DRAFT", "false") :: ("PR_LIVE_STATE", "MERGED") :: base));
  check int "ready agent PR with live state CLOSED is skipped" 0
    (run_agent_draft_policy
       (("PR_IS_DRAFT", "false") :: ("PR_LIVE_STATE", "CLOSED") :: base));
  check int "live state lower-case merged is also skipped" 0
    (run_agent_draft_policy
       (("PR_IS_DRAFT", "false") :: ("PR_LIVE_STATE", "merged") :: base));
  check bool "live state OPEN does NOT bypass policy" true
    (run_agent_draft_policy
       (("PR_IS_DRAFT", "false") :: ("PR_LIVE_STATE", "OPEN") :: base)
     <> 0)

let test_pr_automation_draft_guard_contracts () =
  check bool "pr automation live query includes PR state" true
    (file_contains_pattern ".github/workflows/pr-automation.yml"
       "state\n                    merged");
  check bool "pr automation skips live merged PRs" true
    (file_contains_pattern ".github/workflows/pr-automation.yml"
       {|current.state === "MERGED"|});
  check bool "pr automation skips live closed PRs" true
    (file_contains_pattern ".github/workflows/pr-automation.yml"
       {|current.state === "CLOSED"|});
  check bool "pr automation skips when live merged flag is true" true
    (file_contains_pattern ".github/workflows/pr-automation.yml"
       "current.merged === true");
  let live_state_skip =
    file_pattern_position ".github/workflows/pr-automation.yml"
      {|current.state === "MERGED"|}
  in
  let draft_restore =
    file_pattern_position ".github/workflows/pr-automation.yml"
      "convertPullRequestToDraft"
  in
  check bool "post-merge skip runs before draft restore mutation" true
    (match live_state_skip, draft_restore with
     | Some skip_pos, Some restore_pos -> skip_pos < restore_pos
     | _ -> false);
  check bool "pr automation reads live labels for policy" true
    (file_contains_pattern ".github/workflows/pr-automation.yml"
       "const labels = (currentPr.labels || []).map(normalizeLabelName).filter(Boolean)");
  check bool "pr automation does not use stale payload labels for policy" true
    (file_not_contains_pattern ".github/workflows/pr-automation.yml"
       "const labels = (pr.labels || [])");
  check bool "draft-only state does not suppress missing approval" true
    (file_not_contains_pattern ".github/workflows/pr-automation.yml"
       "(!safeDraftOnlyState &&");
  check bool "agent-like PRs always require verified approval" true
    (file_contains_pattern ".github/workflows/pr-automation.yml"
       "const approvalRequired =\n              looksAgentAuthored ||\n              unsafeDraftBoundaryAction ||\n              hasAutoMergeRequest ||");
  check bool "pr automation has hard-stop label policy" true
    (file_contains_pattern ".github/workflows/pr-automation.yml"
       "hard-stop label present");
  check bool "pr automation hard-stop participates in guarded decision" true
    (file_contains_pattern ".github/workflows/pr-automation.yml"
       "presentHardStopLabels.length > 0")

let test_health_and_ci_runner_diagnostics () =
  check bool "health snapshot records baseline source" true
    (file_contains_pattern "scripts/health_snapshot.sh" "\"baseline\": {");
  check bool "health snapshot records regressions array" true
    (file_contains_pattern "scripts/health_snapshot.sh" "\"regressions\": ${regressions_json}");
  check bool "tests scrub inherited MASC_BASE_PATH overrides" true
    (file_contains_pattern "test/dune" "(MASC_BASE_PATH \"\")");
  check bool "test_oas_worker pins direct-run MASC env" true
    (file_contains_pattern "test/test_oas_worker.ml"
       "let pin_direct_run_masc_env");
  check bool "test_oas_worker clears captured Eio env before tests" true
    (file_contains_pattern "test/test_oas_worker.ml"
       "Masc_eio_env.reset_for_test ()");
  check bool "test_oas_worker isolates legacy timeout test from liveness observer" true
    (file_contains_pattern "test/test_oas_worker.ml"
       "with_cascade_attempt_liveness \"off\"");
  check bool "keeper turn concurrency ignores operator env in tests" true
    (file_contains_pattern "lib/keeper/keeper_turn_slot.ml"
       "Env_config_core.running_under_test_executable ()");
  check bool "config resolver sanitizes inherited test base path" true
    (file_contains_pattern "lib/config_dir_resolver.ml"
       "env_base_path = current_env_base_path_opt ()");
  check bool "ci runner captures log file" true
    (file_contains_pattern "scripts/ci-run-tests.sh" "TEST_LOG_FILE=");
  check bool "ci runner prints failure markers" true
    (file_contains_pattern "scripts/ci-run-tests.sh" "failure markers (latest 20)");
  check bool "ci runner records active command pid/pgid" true
    (file_contains_pattern "scripts/ci-run-tests.sh" "active_cmd_pgid=");
  check bool "ci runner prints active command process tree snapshot" true
    (file_contains_pattern "scripts/ci-run-tests.sh"
       "active command process tree snapshot:");
  check bool "ci runner tails dune log on failure" true
    (file_contains_pattern "scripts/ci-run-tests.sh" "tail -n 120 ${dune_log}");
  check bool "ci runner retries dune rpc lock failures in isolated build dir" true
    (file_contains_pattern "scripts/ci-run-tests.sh"
       "detected dune RPC/lock failure; retrying once with isolated build dir");
  check bool "ci runner detects native archive loss" true
    (file_contains_pattern "scripts/ci-run-tests.sh" "Unbound module Llm_provider");
  check bool "ci runner detects disk full failures" true
    (file_contains_pattern "scripts/ci-run-tests.sh" "No space left on device");
  check bool "ci runner prints disk hygiene repair guidance" true
    (file_contains_pattern "scripts/ci-run-tests.sh"
       "bash scripts/disk-hygiene.sh --fix");
  check bool "ci runner avoids recursive tmpdir du in diagnostics" true
    (file_not_contains_pattern "scripts/ci-run-tests.sh"
       "du -sh \"${TMPDIR:-/tmp}\"");
  check bool "ci runner avoids process substitution in clean retry" true
    (file_not_contains_pattern "scripts/ci-run-tests.sh" "> >(tee");
  check bool "ci runner tracks active build dir for diagnostics" true
    (file_contains_pattern "scripts/ci-run-tests.sh" "ACTIVE_TEST_BUILD_DIR");
  let lint_job =
    file_pattern_position ".github/workflows/ci.yml" "\n  lint:\n    name: Lint"
  in
  let lint_timeout =
    file_pattern_position ".github/workflows/ci.yml"
      "    timeout-minutes: 40"
  in
  let dashboard_job =
    file_pattern_position ".github/workflows/ci.yml" "\n  dashboard:\n    name: Dashboard"
  in
  check bool "lint job has cold dependency install headroom" true
    (match lint_job, lint_timeout, dashboard_job with
     | Some lint_pos, Some timeout_pos, Some dashboard_pos ->
       lint_pos < timeout_pos && timeout_pos < dashboard_pos
     | _ -> false);
  check bool "quick suite excludes operator control from monolithic dune test" true
    (file_contains_pattern ".github/workflows/ci.yml"
       "MASC_INCLUDE_OPERATOR_CONTROL: \"false\"");
  check bool "ci workflow runs operator control in dedicated step" true
    (file_contains_pattern ".github/workflows/ci.yml"
       "dune exec ./test/test_operator_control.exe");
  check bool "operator control test is env-gated in dune" true
    (file_contains_pattern "test/stanzas/test_operator_control.inc"
       "(enabled_if (= %{env:MASC_INCLUDE_OPERATOR_CONTROL=true} \"true\"))")

let test_release_truth_contracts () =
  (* TODO: uncomment when Doc Truth CI job is wired (#9419 follow-up) *)
  (* check bool "ci workflow defines doc truth job" true
    (file_contains_pattern ".github/workflows/ci.yml" "name: Doc Truth");
  check bool "ci workflow exports doc truth scope output" true
    (file_contains_pattern ".github/workflows/ci.yml"
       "doc_truth: ${{ steps.scope.outputs.doc_truth }}");
  check bool "ci gate aggregates doc truth" true
    (file_contains_pattern ".github/workflows/ci.yml"
       "check \"doc-truth\"       \"$DOC_TRUTH_RESULT\"");
  check bool "ci gate aggregates oas pin check" true
    (file_contains_pattern ".github/workflows/ci.yml"
       "check \"oas-pin-check\"   \"$OAS_PIN_RESULT\"");
  check bool "ci gate aggregates spec line refs" true
    (file_contains_pattern ".github/workflows/ci.yml"
       "check \"spec-line-refs\"  \"$SPEC_REFS_RESULT\""); *)
  check bool "ci workflow removed odoc documentation lane" true
    (file_not_contains_pattern ".github/workflows/ci.yml" "name: Documentation");
  check bool "ci workflow no longer installs odoc" true
    (file_not_contains_pattern ".github/workflows/ci.yml" "Install odoc");
  check bool "odoc pages deploy is opt-in" true
    (file_contains_nearby_line_with_patterns ".github/workflows/odoc.yml"
       ~anchor:"name: Deploy to Pages"
       ~patterns:[
         "if:";
         "github.ref == 'refs/heads/main'";
         "vars.ODOC_PAGES_DEPLOY == 'true'";
       ]
       ~max_lines:2);
  check bool "odoc workflow defines pages artifact upload step" true
    (file_contains_pattern ".github/workflows/odoc.yml"
       "Upload Pages artifact");
  check bool "odoc pages artifact follows deploy opt-in" true
    (file_contains_nearby_line_with_patterns ".github/workflows/odoc.yml"
       ~anchor:"Upload Pages artifact"
       ~patterns:[
         "if:";
         "github.ref == 'refs/heads/main'";
         "vars.ODOC_PAGES_DEPLOY == 'true'";
       ]
       ~max_lines:2);
  check bool "release/doc truth changes trigger build scope" true
    (file_contains_pattern ".github/workflows/ci.yml"
       "docs/|README\\.md$|ROADMAP\\.md$|CHANGELOG\\.md$");
  check bool "release evidence changes stay in build scope" true
    (file_contains_pattern ".github/workflows/ci.yml"
       "scripts/release-evidence\\.sh$");
  check bool "health job reruns doc truth and OAS pin checks" true
    (file_contains_pattern ".github/workflows/ci.yml"
       "scripts/check-doc-truth.sh\n          scripts/sync-oas-pin-docs.sh --check");
  check bool "doc truth script delegates version truth" true
    (file_contains_pattern "scripts/check-doc-truth.sh"
       "scripts/check-version-truth.sh");
  check bool "release workflow checks version truth" true
    (file_contains_pattern ".github/workflows/release.yml"
       "scripts/check-version-truth.sh");
  check bool "main nightly checks version truth in doc truth step" true
    (file_contains_nearby_line_with_patterns
       ".github/workflows/main-nightly-health.yml"
       ~anchor:"- name: Check doc truth"
       ~patterns:["scripts/check-version-truth.sh"]
       ~max_lines:4);
  let nightly_pin =
    file_pattern_position ".github/workflows/main-nightly-health.yml"
      "uses: ./.github/actions/pin-ocaml-deps"
  in
  let nightly_install =
    file_pattern_position ".github/workflows/main-nightly-health.yml"
      "uses: ./.github/actions/install-ocaml-deps"
  in
  check bool "main nightly pins external deps before install" true
    (match nightly_pin, nightly_install with
     | Some pin, Some install -> pin < install
     | _ -> false);
  check bool "main nightly pins bisect test dependency override" true
    (file_contains_nearby_line_with_patterns
       ".github/workflows/main-nightly-health.yml"
       ~anchor:"uses: ./.github/actions/pin-ocaml-deps"
       ~patterns:["pin-flags:"; "--with-bisect"]
       ~max_lines:4);
  check bool "main nightly uses retrying dependency installer" true
    (file_contains_pattern ".github/workflows/main-nightly-health.yml"
       "uses: ./.github/actions/install-ocaml-deps");
  (* TODO: uncomment when ci_core fanout comment is added (#9419 follow-up) *)
  (* check bool "ci core fanout intentionally excludes tla" true
    (file_contains_pattern ".github/workflows/ci.yml"
       "Note: tla is intentionally NOT forced on by ci_core."); *)
  check bool "main build uploads release evidence" true
    (file_contains_pattern ".github/workflows/ci.yml"
       "name: Upload main release evidence");
  check bool "release workflow generates evidence bundle" true
    (file_contains_pattern ".github/workflows/release.yml"
       "Generate release evidence bundle");
  check bool "release workflow ships evidence with artifacts" true
    (file_contains_pattern ".github/workflows/release.yml"
       "path: dist/*");
  check bool "make install deps skips with-doc" true
    (file_contains_pattern "mk/build.mk"
       "opam install . --deps-only --with-test -y");
  check bool "make release evidence target exists" true
    (file_contains_pattern "mk/release.mk" "release-evidence:")

let test_oas_pin_source_contracts () =
  check bool "external opam pins retry transient git fetch failures" true
    (file_contains_pattern "scripts/opam-pin-external-deps.sh"
       "OPAM_PIN_RETRIES");
  check bool "external opam pins use retry wrapper" true
    (file_contains_pattern "scripts/opam-pin-external-deps.sh"
       "opam_pin_add mcp_protocol");
  check bool "oas pin check parses local file pins from opam output" true
    (file_contains_pattern "scripts/check-oas-pin.sh"
       "extract_opam_pin_source()");
  check bool "oas pin check accepts rsync-style file pins" true
    (file_contains_pattern "scripts/check-oas-pin.sh" "git+*|file://*)");
  check bool "oas pin check normalizes local pin path helper" true
    (file_contains_pattern "scripts/check-oas-pin.sh"
       "local_pin_path_from_source()");
  check bool "oas pin check accepts both git file pins and plain file pins" true
    (file_contains_pattern "scripts/check-oas-pin.sh"
       "git+file://*|file://*)");
  check bool "oas pin check validates findlib artifact directories" true
    (file_contains_pattern "scripts/check-oas-pin.sh" "ocamlfind query");
  check bool "oas pin check validates agent sdk native archive" true
    (file_contains_pattern "scripts/check-oas-pin.sh" "agent_sdk.cmxa");
  check bool "oas pin check validates llm provider native archive" true
    (file_contains_pattern "scripts/check-oas-pin.sh" "llm_provider.cmxa");
  (* #13095: Metric_contract is consumed by autoresearch_metric.ml; if
     check-oas-pin.sh stops verifying its cmi, a stale opam switch can
     pass the artifact gate and produce an incomprehensible build
     failure later in lib/. *)
  check bool "oas pin check validates Metric_contract artifact" true
    (file_contains_pattern "scripts/check-oas-pin.sh"
       "agent_sdk__metric_contract.cmi");
  check bool "oas pin check gives rebuild guidance" true
    (file_contains_pattern "scripts/check-oas-pin.sh"
       "scripts/opam-pin-external-deps.sh --install");
  (* #13095: dune-local.sh must run --local-only check-oas-pin.sh
     before delegating to dune.  Two anchors keep the contract
     self-documenting: the call line itself, and the env-var bypass
     that lets operators opt out for clean/fmt/subst when the switch
     is intentionally drifting (e.g. mid-bump). *)
  check bool "dune-local.sh asserts oas pin before invoking dune" true
    (file_contains_pattern "scripts/dune-local.sh"
       "_pin_check}\" --local-only");
  check bool "dune-local.sh exposes MASC_SKIP_PIN_CHECK bypass" true
    (file_contains_pattern "scripts/dune-local.sh"
       "MASC_SKIP_PIN_CHECK");
  check bool "dune-local.sh skips pin check inside GitHub Actions" true
    (file_contains_pattern "scripts/dune-local.sh"
       "GITHUB_ACTIONS");
  check bool "dune-local.sh exposes shared opam switch lock path" true
    (file_contains_pattern "scripts/dune-local.sh"
       "MASC_OPAM_LOCK_PATH:-/tmp/me-opam-switch.lock");
  check bool "dune-local.sh takes build lock before opam switch lock" true
    (match
       file_pattern_position "scripts/dune-local.sh" "waiting for lock %s",
       file_pattern_position "scripts/dune-local.sh"
         "waiting for opam switch lock"
     with
     | Some dune_pos, Some opam_pos -> dune_pos < opam_pos
     | _ -> false);
  check bool "dune-local.sh locks opam switch before pin guard" true
    (match
       file_pattern_position "scripts/dune-local.sh"
         "waiting for opam switch lock",
       file_pattern_position "scripts/dune-local.sh"
         "checking agent_sdk pin"
     with
     | Some lock_pos, Some pin_pos -> lock_pos < pin_pos
     | _ -> false);
  check bool "external opam pin script uses the shared opam lock" true
    (file_contains_pattern "scripts/opam-pin-external-deps.sh"
       "MASC_OPAM_LOCK_HELD=1");
  check bool "external opam pin script shares the opam lock path" true
    (file_contains_pattern "scripts/opam-pin-external-deps.sh"
       "MASC_OPAM_LOCK_PATH:-/tmp/me-opam-switch.lock");
  check bool "external opam pin script blocks stale worktree downgrades" true
    (file_contains_pattern "scripts/opam-pin-external-deps.sh"
       "refusing to downgrade shared agent_sdk pin");
  check bool "external opam pin script exposes downgrade override" true
    (file_contains_pattern "scripts/opam-pin-external-deps.sh"
       "MASC_ALLOW_AGENT_SDK_PIN_DOWNGRADE");
  check bool "external opam pin script reports lock holder evidence" true
    (file_contains_pattern "scripts/opam-pin-external-deps.sh"
       "print_opam_lock_holder")

let test_doc_truth_guard_contracts () =
  check bool "doc truth script protects spec index front door wording" true
    (file_contains_pattern "scripts/check-doc-truth.sh"
       "Historical compatibility lane과 internal orchestration reference는 migration context로만 남긴다.");
  check bool "doc truth script protects command plane downgrade" true
    (file_contains_pattern "scripts/check-doc-truth.sh"
       "| Status | Historical Reference |");
  check bool "doc truth script protects system overview front door wording" true
    (file_contains_pattern "scripts/check-doc-truth.sh"
       "### 7.3 Dashboard and Operator Read Visibility");
  check bool "doc truth script forbids dead server_command_plane_http row" true
    (file_contains_pattern "scripts/check-doc-truth.sh"
       "require_not_contains docs/spec/09-server-transport.md '| `server_command_plane_http.ml` |'");
  check bool "doc truth script forbids old dashboard command-plane type wording" true
    (file_contains_pattern "scripts/check-doc-truth.sh"
       "command-plane.ts         -- Command plane types")

let test_storage_truth_guard_contracts () =
  check bool "bootstrap enforces filesystem-only storage" true
    (file_contains_pattern "lib/server/server_runtime_bootstrap.ml"
       "filesystem-only bootstrap");
  check bool "storage inventory names filesystem as only active backend" true
    (file_contains_pattern "docs/BOOT-ENV-STATE-INVENTORY.md"
       "Only `filesystem` is active");
  check bool "storage inventory marks PG envs retired" true
    (file_contains_pattern "docs/BOOT-ENV-STATE-INVENTORY.md"
       "Retired PostgreSQL backend envs");
  check bool "env contract keeps PG envs ignored" true
    (file_contains_pattern "docs/ENV-CONTRACT.md"
       "retired/ignored: `MASC_POSTGRES_URL`, `MASC_PG_POOL_SIZE`");
  check bool "v2 design forbids distributed storage targets" true
    (file_contains_pattern "docs/MASC-V2-DESIGN.md"
       "Redis/PostgreSQL storage modes are not operator targets");
  check bool "v2 design no longer recommends postgres mode" true
    (file_not_contains_pattern "docs/MASC-V2-DESIGN.md"
       "PostgreSQL Mode");
  check bool "v2 design no longer exposes redis mode as storage option" true
    (file_not_contains_pattern "docs/MASC-V2-DESIGN.md"
       "Redis Mode");
  check bool "board spec no longer advertises dual backend operation" true
    (file_not_contains_pattern "docs/spec/11-board.md"
       "JSONL 파일 또는 PostgreSQL 두 가지 백엔드");
  check bool "board spec no longer documents env-based PG selection" true
    (file_not_contains_pattern "docs/spec/11-board.md"
       "MASC_POSTGRES_URL 존재");
  check bool "board spec no longer depends on Board_pg" true
    (file_not_contains_pattern "docs/spec/11-board.md" "Board_pg");
  check bool "board spec forbids JSONL to PostgreSQL migration" true
    (file_contains_pattern "docs/spec/11-board.md"
       "JSONL -> PostgreSQL migration path는 지원하지 않는다");
  check bool "memory spec no longer maps OAS bridge to Memory_pg" true
    (file_not_contains_pattern "docs/spec/12-memory-systems.md"
       "Memory_pg");
  check bool "memory spec no longer says PostgreSQL is primary" true
    (file_not_contains_pattern "docs/spec/12-memory-systems.md"
       "PostgreSQL은 primary");
  check bool "system overview no longer lists postgres for board state" true
    (file_not_contains_pattern "docs/spec/01-system-overview.md"
       "Board 게시판, session 상태");
  check bool "system overview keeps pgvector external-only" true
    (file_contains_pattern "docs/spec/01-system-overview.md"
       "Current Board/session runtime state is not stored in PostgreSQL");
  check bool "performance SLO no longer tells operators to switch to PG" true
    (file_not_contains_pattern "docs/PERFORMANCE-SLO.md"
       "PostgreSQL 백엔드로 전환");
  check bool "spec index lists filesystem board backend" true
    (file_contains_pattern "docs/spec/SPEC-INDEX.md"
       "filesystem/JSONL backend");
  check bool "glossary no longer describes board PG primary" true
    (file_not_contains_pattern "docs/spec/00-glossary.md"
       "PostgreSQL(primary)");
  check bool "room spec no longer documents PG dual-write" true
    (file_not_contains_pattern "docs/spec/03-room-coordination.md"
       "dual-write");
  check bool "server transport no longer bootstraps shared PG pool" true
    (file_not_contains_pattern "docs/spec/09-server-transport.md"
       "inject_shared_pg_pool");
  check bool "dashboard spec no longer documents PostgresNative runtime" true
    (file_not_contains_pattern "docs/spec/10-dashboard.md"
       "PostgresNative");
  check bool "migration targets no longer say board PostgreSQL primary" true
    (file_not_contains_pattern "docs/spec/B-migration-targets.md"
       "PostgreSQL (primary)");
  check bool "implementation status no longer claims JSONL+PG backend" true
    (file_not_contains_pattern "docs/spec/C-implementation-status.md"
       "JSONL+PG dual backend")

let test_proof_store_reader_truth_contracts () =
  check bool "proof artifact reader delegates ref resolution to OAS" true
    (file_contains_pattern "lib/proof_artifact_reader.ml"
       "Agent_sdk.Proof_store.resolve_ref");
  check bool "proof artifact reader delegates JSON reads to OAS" true
    (file_contains_pattern "lib/proof_artifact_reader.ml"
       "Agent_sdk.Proof_store.read_json");
  check bool "proof artifact reader delegates JSONL reads to OAS" true
    (file_contains_pattern "lib/proof_artifact_reader.ml"
       "Agent_sdk.Proof_store.read_jsonl");
  check bool "proof artifact reader interface names OAS ownership" true
    (file_contains_pattern "lib/proof_artifact_reader.mli"
       "Agent_sdk.Proof_store");
  check bool "proof artifact reader interface no longer documents local layout ownership" true
    (file_not_contains_pattern "lib/proof_artifact_reader.mli"
       "paths under [{config.root}/proofs/]");
  check bool "cross-run design marks OAS read side implemented" true
    (file_contains_pattern "docs/design/cross-run-loader-and-window-spec.md"
       "Proof_store Read-Side API (OAS, Implemented)");
  check bool "cross-run design no longer calls list_runs unordered current truth" true
    (file_not_contains_pattern "docs/design/cross-run-loader-and-window-spec.md"
       "The current `Proof_store.list_runs` returns `string list`");
  check bool "cdal design no longer calls proof-store write-side only" true
    (file_not_contains_pattern "docs/design/cdal-contract-kernel-and-advisory-split.md"
       "write-side naming convention");
  check bool "cdal design no longer defers OAS reader ownership" true
    (file_not_contains_pattern "docs/design/cdal-contract-kernel-and-advisory-split.md"
       "Long-term, OAS should own the read side");
  check bool "cdal design no longer claims unsupported schemas lack fail-closed handling" true
    (file_not_contains_pattern "docs/design/cdal-contract-kernel-and-advisory-split.md"
       "no strict fail-closed handling for unsupported schema versions");
  check bool "cdal design preserves OAS reader authority" true
    (file_contains_pattern "docs/design/cdal-contract-kernel-and-advisory-split.md"
       "OAS owns the read side for the `proof-store://` scheme")

let test_keeper_agent_upgrade_source_contracts () =
  check bool "shared types substrate exists" true
    (Sys.file_exists (source_path "lib/shared_types/resilience_outcome.mli"));
  check bool "shared audit substrate exists" true
    (Sys.file_exists (source_path "lib/shared_audit/store.mli"));
  check bool "multimodal hydrator is separate from keeper artifact plumbing" true
    (Sys.file_exists (source_path "lib/multimodal/multimodal_hydrator.mli"));
  check bool "resilience recovery strategy GADT exists" true
    (file_contains_pattern "lib/resilience/recovery.ml" "type _ strategy =");
  let autonomous =
    file_pattern_position "lib/keeper/keeper_post_turn.ml"
      "let body = apply_autonomous_wirein ~now:now_ts body"
  in
  let resilience =
    file_pattern_position "lib/keeper/keeper_post_turn.ml"
      "let body =\n    apply_resilience_wirein"
  in
  let tool_emission =
    file_pattern_position "lib/keeper/keeper_post_turn.ml"
      "let body = apply_tool_emission_wirein ~now:now_ts body"
  in
  let multimodal =
    file_pattern_position "lib/keeper/keeper_post_turn.ml"
      "apply_multimodal_wirein ~now:now_ts body"
  in
  check bool "keeper post-turn tail order is autonomous before resilience" true
    (match autonomous, resilience with
     | Some a, Some r -> a < r
     | _ -> false);
  check bool "keeper post-turn tail order is resilience before tool emission" true
    (match resilience, tool_emission with
     | Some r, Some t -> r < t
     | _ -> false);
  check bool "keeper post-turn tail order is tool emission before multimodal" true
    (match tool_emission, multimodal with
     | Some t, Some m -> t < m
     | _ -> false);
  let guarded_wirein_catch message =
    file_contains_pattern "lib/keeper/keeper_post_turn.ml"
      ("with\n        | Eio.Cancel.Cancelled _ as e -> raise e\n        | exn ->\n\
        \          Log.Keeper.warn\n            \"keeper:%s "
       ^ message ^ " failed: %s\"")
  in
  check bool "autonomous post-turn wire-in re-raises cancellation" true
    (guarded_wirein_catch "autonomous wire-in");
  check bool "resilience post-turn wire-in re-raises cancellation" true
    (guarded_wirein_catch "resilience wire-in");
  check bool "tool emission post-turn wire-in re-raises cancellation" true
    (guarded_wirein_catch "tool emission drain");
  check bool "multimodal post-turn wire-in re-raises cancellation" true
    (guarded_wirein_catch "multimodal wire-in")

let test_contract_harness_contracts () =
  check bool "contract harness exposes extract_text helper" true
    (file_contains_pattern "scripts/harness/lib/test_framework.sh"
       "extract_text()");
  check bool "golden path harness uses extract_text helper" true
    (file_contains_pattern "scripts/harness/contract/golden_path_1_contract.sh"
       "| extract_text)")

let test_route_auth_contracts () =
  (* CP purge (phases 1-5): command-plane HTTP/H2 route modules deleted.
     Assertions on server_routes_http_routes_command_plane_*.ml and
     server_h2_gateway_routes_cp.ml removed with the source files. *)
  check bool "http keeper chat stream uses keeper tool auth" true
    (file_contains_pattern "lib/server/server_routes_http_routes_dashboard.ml"
       {|with_tool_auth ~tool_name:"masc_keeper_msg"|});
  check bool "dashboard runtime probe force refresh uses tool auth" true
    (file_contains_pattern "lib/server/server_routes_http_routes_dashboard.ml"
       {|with_tool_auth ~tool_name:"masc_runtime_ollama_probe"|});
  check bool "http keeper chat stream forces direct reply mode" true
    (file_contains_pattern "lib/server/server_routes_http_keeper_stream.ml"
       {|("direct_reply", `Bool true)|});
  check bool "channel gate message route uses tool auth" true
    (file_contains_pattern
       "lib/server/server_routes_http_routes_channel_gate.ml"
       {|with_tool_auth ~tool_name:"channel_gate"|});
  check bool "channel gate message route is registered" true
    (file_contains_pattern
       "lib/server/server_routes_http_routes_channel_gate.ml"
       {|Http.Router.post "/api/v1/gate/message"|});
  check bool "channel gate health route stays public read" true
    (file_contains_pattern
        "lib/server/server_routes_http_routes_channel_gate.ml"
        "with_public_read");
  check bool "channel gate events route stays public read" true
    (file_contains_pattern
       "lib/server/server_auth.ml"
       {|String.equal path "/api/v1/gate/events"|});
  check bool "channel gate connectors route stays public read" true
    (file_contains_pattern
       "lib/server/server_auth.ml"
       {|String.equal path "/api/v1/gate/connectors"|});
  check bool "generic connector status route stays public read" true
    (file_contains_pattern
       "lib/server/server_auth.ml"
       {|String.equal path "/api/v1/gate/connector/status"|});
  check bool "channel gate health route is registered" true
    (file_contains_pattern
        "lib/server/server_routes_http_routes_channel_gate.ml"
        {|Http.Router.get "/api/v1/gate/health"|});
  check bool "generic connector status route is registered" true
    (file_contains_pattern
       "lib/server/server_routes_http_routes_channel_gate.ml"
       {|Http.Router.get "/api/v1/gate/connector/status"|});
  check bool "channel gate connectors route is registered" true
    (file_contains_pattern
       "lib/server/server_routes_http_routes_channel_gate.ml"
       {|Http.Router.get "/api/v1/gate/connectors"|});
  check bool "generic connector bind route is registered" true
    (file_contains_pattern
       "lib/server/server_routes_http_routes_channel_gate.ml"
       {|Http.Router.post "/api/v1/gate/connector/bind"|});
  check bool "generic connector unbind route is registered" true
    (file_contains_pattern
       "lib/server/server_routes_http_routes_channel_gate.ml"
       {|Http.Router.post "/api/v1/gate/connector/unbind"|})

let test_http_write_auth_contracts () =
  check bool "server auth scopes query token fallback to observer SSE helper" true
    (file_contains_pattern "lib/server/server_auth.ml"
       "let observer_sse_query_token_from_request");
  check bool "observer SSE helper still gates query token on sse_kind" true
    (file_contains_pattern "lib/server/server_auth.ml"
       {|match query_param request "sse_kind" with|});
  check bool "observer SSE helper still reads token query param" true
    (file_contains_pattern "lib/server/server_auth.ml"
       {|trim_opt (query_param request "token")|});
  check bool "observer SSE auth error documents scoped query token contract" true
    (file_contains_pattern "lib/server/server_auth.ml"
       {|or 'token' query param for the observer/presence SSE stream.|});
  check bool "server auth keeps general MCP auth header-only" true
    (file_contains_pattern "lib/server/server_auth.ml"
       {|match auth_token_from_request request with|});
  check bool "observer SSE query token fallback stays scoped" true
    (file_contains_pattern "lib/server/server_auth.ml"
       {|let observer_sse_query_token_from_request request =|});
  check bool "observer SSE fallback reads token query param explicitly" true
    (file_contains_pattern "lib/server/server_auth.ml"
       {|query_param request "token"|});
  check bool "observer SSE auth has dedicated verifier" true
    (file_contains_pattern "lib/server/server_auth.ml"
       {|let verify_mcp_observer_stream_auth ~base_path request =|});
  check bool "server auth defines token-bound permission helper" true
    (file_contains_pattern "lib/server/server_auth.ml"
       "let authorize_token_bound_permission_request");
  check bool "server auth exposes token-bound route helper" true
    (file_contains_pattern "lib/server/server_auth.ml"
       "and with_token_permission_auth");
  check bool "server auth defines same-origin browser guard" true
    (file_contains_pattern "lib/server/server_auth.ml"
       "let ensure_same_origin_browser_request");
  check bool "tool auth enforces same-origin when no bearer token" true
    (file_contains_pattern "lib/server/server_auth.ml"
       "else ensure_same_origin_browser_request request");
  check bool "broadcast route requires token-bound broadcast permission" true
    (file_contains_pattern "lib/server/server_routes_http_routes_dashboard.ml"
       {|with_token_permission_auth ~permission:Masc_domain.CanBroadcast|});
  check bool "keeper config update requires admin permission" true
    (file_contains_pattern "lib/server/server_routes_http_routes_dashboard.ml"
       {|with_token_permission_auth ~permission:Masc_domain.CanAdmin|});
  check bool "board vote route requires board vote tool auth" true
    (file_contains_pattern "lib/server/server_routes_http_routes_activity.ml"
       {|with_tool_auth ~tool_name:"masc_board_vote"|});
  check bool "board vote route overwrites voter from auth identity" true
    (file_contains_pattern "lib/server/server_routes_http_routes_activity.ml"
       {|let voter = board_actor_author_for_write agent_name|});
  check bool "board vote route writes normalized voter" true
    (file_contains_pattern "lib/server/server_routes_http_routes_activity.ml"
       {|json_upsert_string_field "voter" voter|});
  check bool "board comment route overwrites author from auth identity" true
    (file_contains_pattern "lib/server/server_routes_http_routes_activity.ml"
       {|let author = board_actor_author_for_write agent_name|});
  check bool "board comment route writes normalized author" true
    (file_contains_pattern "lib/server/server_routes_http_routes_activity.ml"
       {|json_upsert_string_field "author" author|});
  check bool "tool-host-failures route requires tool auth" true
    (file_contains_pattern "lib/server/server_routes_http_routes_dashboard.ml"
       {|with_tool_auth ~tool_name:"masc_broadcast"|});
  check bool "provider runs post requires admin permission" true
    (file_contains_pattern "lib/server/server_routes_http_routes_provider_runs.ml"
       {|with_token_permission_auth ~permission:Masc_domain.CanAdmin|});
  check bool "dashboard delete actions require token-bound admin permission" true
    (file_contains_pattern "lib/server/server_dashboard_http_delete_actions.ml"
       {|with_token_permission_auth ~permission:Masc_domain.CanAdmin|});
  check bool "server auth defines public-read cors origin helper" true
    (file_contains_pattern "lib/server/server_auth.ml"
       "let public_read_cors_origin_opt");
  check bool "server auth exposes public-read json responder" true
    (file_contains_pattern "lib/server/server_auth.ml"
       "let respond_public_read_json");
  check bool "channel gate public reads use constrained cors responder" true
    (file_contains_pattern "lib/server/server_routes_http_routes_channel_gate.ml"
       "respond_public_read_json");
  check bool "artifacts endpoint uses constrained cors responder" true
    (file_contains_pattern "lib/server/server_routes_http_routes_artifacts.ml"
       "respond_public_read_json");
  check bool "provider runs route threads state net into dashboard single-run" true
    (file_contains_pattern "lib/server/server_routes_http_routes_provider_runs.ml"
       "~net:state.Mcp_server.net");
  check bool "loopback cross-port auth uses explicit dev origin allowlist" true
    (file_contains_pattern "lib/server/server_auth.ml"
       "configured_loopback_dev_mutation_origins");
  check bool "loopback cross-port auth no longer trusts any loopback origin" true
    (not
       (file_contains_pattern "lib/server/server_auth.ml"
          "if is_loopback_host (normalize_loopback_host origin_host) then"))

let test_tool_admin_snapshot_auth_contracts () =
  check bool "tool admin snapshot metadata requires admin permission" true
    (file_contains_pattern "lib/tool_misc.ml"
       {|"masc_tool_admin_snapshot" | "masc_tool_admin_update" ->
      Some Masc_domain.CanAdmin|});
  check bool "tool admin snapshot legacy permission map requires admin" true
    (file_contains_pattern "lib/tool_permission_map.ml"
       {|("masc_tool_admin_snapshot", CanAdmin)|})

let test_keeper_direct_reply_contracts () =
  check bool "dashboard keeper direct messages request direct reply" true
    (file_contains_pattern "dashboard/src/api/keeper.ts"
       "direct_reply: true");
  check bool "operator keeper_message forwards direct reply flag" true
    (file_contains_pattern "lib/operator/operator_control.ml"
       {|("direct_reply", `Bool true)|});
  check bool "channel gate keeper bridge uses streaming reply path" true
    (file_contains_pattern "lib/gate_keeper_backend.ml"
       "Tool_keeper.dispatch_stream");
  check bool "keeper turn parses direct reply flag" true
    (file_contains_pattern "lib/keeper/keeper_turn.ml"
       "get_bool args \"direct_reply\"");
  (* Historical: direct_reply once forked cascade name into
     "keeper_reply"/"keeper_turn", but neither was ever defined in
     cascade.json — the drift collapsed to the default cascade via
     Keeper_cascade_profile.canonicalize. The fork is gone; the
     direct_reply flag now only affects persona prompt + skill-route
     suppression (checked below). *)
  check bool "keeper manual turns resolve declared cascade through runtime catalog" true
    (file_contains_pattern "lib/keeper/keeper_turn.ml"
       "Cascade_catalog_runtime.resolve_declared_name ~raw_name");
  check bool "keeper turn suppresses skill route headers for direct reply" true
    (file_contains_pattern "lib/keeper/keeper_turn.ml"
       "let effective_no_skill_route = no_skill_route || direct_reply");
  check bool "keeper turn applies direct reply persona prompt" true
    (file_contains_pattern "lib/keeper/keeper_turn.ml"
       "Keeper_prompt.append_direct_reply_mode_prompt")

let test_keeper_list_cache_atomic_contracts () =
  check bool "keeper list cache uses versioned atomic snapshot storage" true
    (file_contains_pattern "lib/tool_keeper.ml"
       "generation : int");
  check bool "keeper list cache invalidation bumps generation" true
    (file_contains_pattern "lib/tool_keeper.ml"
       "generation:(current.generation + 1)");
  check bool "keeper list cache publish uses CAS" true
    (file_contains_pattern "lib/tool_keeper.ml"
       "Atomic.compare_and_set cache_ref cache next");
  check bool "keeper list cache no longer mutates key field in place" true
    (file_not_contains_pattern "lib/tool_keeper.ml" "_keeper_list_cache.key <-");
  check bool "keeper list cache no longer mutates value field in place" true
    (file_not_contains_pattern "lib/tool_keeper.ml" "_keeper_list_cache.value <-");
  check bool "keeper list cache no longer mutates expiry field in place" true
    (file_not_contains_pattern "lib/tool_keeper.ml" "_keeper_list_cache.expires_at <-")

let test_keeper_zombie_field_contracts () =
  let files =
    [
      "lib/keeper/keeper_meta_contract.ml";
      "lib/keeper/keeper_meta_contract.mli";
      "lib/keeper/keeper_types.ml";
      "lib/keeper/keeper_types.mli";
      "lib/keeper/keeper_meta_json.ml";
      "lib/keeper/keeper_meta_json_parse.ml";
      "dashboard/src/types/core.ts";
      "dashboard/src/types/dashboard-execution.ts";
      "dashboard/src/keeper-store-normalize.ts";
    ]
  in
  List.iter
    (fun file ->
       check bool
         ("last_tools_used stays removed from keeper meta surface: " ^ file)
         true
         (guarded_file_not_contains_pattern file "last_tools_used"))
    files;
  check bool "per-turn tools_used remains on execution receipts" true
    (file_contains_pattern "lib/keeper/keeper_execution_receipt.mli"
       "tools_used : string list");
  let module R = Masc_mcp.Keeper_execution_receipt in
  let receipt : R.t =
    {
      keeper_name = "test-keeper";
      agent_name = "test-agent";
      trace_id = "trace-test";
      generation = 1;
      turn_count = Some 1;
      current_task_id = Some "task-123";
      goal_ids = [ "goal-123" ];
      outcome = "ok";
      terminal_reason_code = "turn_complete";
      response_text_present = true;
      model_used = Some "test-model";
      requested_tools = [ "Read" ];
      reported_tools = [ "Read" ];
      observed_tools = [ "Read" ];
      canonical_tools = [ "Read" ];
      unexpected_tools = [];
      tools_used = [ "Read" ];
      tool_contract_result = "satisfied";
      tool_surface =
        {
          turn_lane = "unified";
          (* WORKAROUND: previously "post_dispatch" — invalid string never
             emitted by producer.  Typed enum forces a real value.
             Root: closed sum type disallows ad-hoc fixture strings. *)
          tool_surface_class = Masc_mcp.Keeper_agent_tool_surface.Surface_mixed;
          tool_requirement = Masc_mcp.Keeper_agent_tool_surface.Required;
          visible_tool_count = 1;
          tool_gate_enabled = true;
          tool_surface_fallback_used = false;
          required_tools = [ "Read" ];
          missing_required_tools = [];
        };
      sandbox_kind = "local";
      sandbox_root = None;
      network_mode = "offline";
      approval_profile = None;
      approval_profile_derived = false;
      cascade_name = R.cascade_name_of_string "default";
      cascade_selected_model = Some "test-model";
      cascade_attempt_count = 1;
      cascade_fallback_applied = false;
      cascade_outcome = "completed";
      degraded_retry_applied = false;
      degraded_retry_cascade = None;
      fallback_reason = None;
      cascade_rotation_attempts = [];
      stop_reason = None;
      error_kind = None;
      error_message = None;
      started_at = "2026-05-06T00:00:00Z";
      ended_at = "2026-05-06T00:00:01Z";
    }
  in
  let json = R.to_json receipt in
  check bool "execution receipt wire serializes tools_used" true
    (match Yojson.Safe.Util.member "tools_used" json with
     | `List [ `String "Read" ] -> true
     | _ -> false);
  check bool "execution receipt wire does not reintroduce last_tools_used" true
    (match Yojson.Safe.Util.member "last_tools_used" json with
     | `Null -> true
     | _ -> false)

let test_keeper_sandbox_credential_volume_contracts () =
  check bool "keeper sandbox documents credential projection path" true
    (file_contains_pattern "Dockerfile.keeper-sandbox"
       "credential bundles are projected at /tmp/keeper-creds");
  check bool "keeper sandbox declares credential projection volume" true
    (file_contains_pattern "Dockerfile.keeper-sandbox"
       {|VOLUME ["/tmp/keeper-creds"]|});
  check bool "host config provider exposes the same in-container root" true
    (file_contains_pattern "lib/keeper/host_config_provider.mli"
       {|[/tmp/keeper-creds]|});
  check bool "host config provider implementation uses the volume root" true
    (file_contains_pattern "lib/keeper/host_config_provider.ml"
       {|let cred_root = "/tmp/keeper-creds"|})

let test_keeper_docker_multikeeper_isolation_contracts () =
  check bool "multi-keeper docker smoke script exists" true
    (Sys.file_exists
       (source_path "scripts/keeper-docker-multikeeper-isolation-smoke.sh"));
  check bool "smoke mounts credential projection read-only" true
    (file_contains_pattern
       "scripts/keeper-docker-multikeeper-isolation-smoke.sh"
       {|:/tmp/keeper-creds/.config/gh:ro|});
  check bool "smoke probes credential projection write failure" true
    (file_contains_pattern
       "scripts/keeper-docker-multikeeper-isolation-smoke.sh"
       "credential projection is writable");
  check bool "smoke creates keeper credential sentinels" true
    (file_contains_pattern
       "scripts/keeper-docker-multikeeper-isolation-smoke.sh"
       "keeper-a-gh-only"
     && file_contains_pattern
          "scripts/keeper-docker-multikeeper-isolation-smoke.sh"
          "keeper-b-gh-only");
  check bool "smoke rejects sibling credential sentinel" true
    (file_contains_pattern
       "scripts/keeper-docker-multikeeper-isolation-smoke.sh"
       {|test ! -e "/tmp/keeper-creds/.config/gh/${OTHER_KEEPER}.txt"|});
  check bool "smoke covers two keepers" true
    (file_contains_pattern
       "scripts/keeper-docker-multikeeper-isolation-smoke.sh"
       "run_keeper keeper-a keeper-b"
     && file_contains_pattern
          "scripts/keeper-docker-multikeeper-isolation-smoke.sh"
          "run_keeper keeper-b keeper-a");
  check bool "unit test asserts selected keeper identity only" true
    (file_contains_pattern "test/test_keeper_shell_docker_route.ml"
       "test_git_creds_mounts_only_selected_keeper_identity");
  check bool "unit test rejects sibling keeper credential mount" true
    (file_contains_pattern "test/test_keeper_shell_docker_route.ml"
       "sibling keeper bundle not mounted");
  check bool "unit test rejects sibling keeper playground mount" true
    (file_contains_pattern "test/test_keeper_shell_docker_route.ml"
       "does not mount keeper B playground");
  check bool "rootless and userns checks remain explicit" true
    (file_contains_pattern "lib/keeper/keeper_sandbox_runtime.ml"
       "sandbox runtime requires Docker rootless mode"
     && file_contains_pattern "lib/keeper/keeper_sandbox_runtime.ml"
          "sandbox runtime requires Docker userns support")

let test_keeper_required_tool_contracts () =
  let tool_choice_anchor = "let tool_choice =" in
  let required_first =
    file_pattern_position_after "lib/keeper/keeper_run_tools.ml"
      ~anchor:tool_choice_anchor
      "if computed_surface.required_tool_names <> []"
  in
  let preferred_required_after =
    file_pattern_position_after "lib/keeper/keeper_run_tools.ml"
      ~anchor:tool_choice_anchor
      "preferred_tool_choice_for_required_tool_names"
  in
  let last_turn_after =
    file_pattern_position_after "lib/keeper/keeper_run_tools.ml"
      ~anchor:tool_choice_anchor
      "else if computed_surface.is_last_turn"
  in
  check bool "required_tools force tool_choice before last-turn relaxation" true
    (match required_first, preferred_required_after, last_turn_after with
     | Some required_pos, Some preferred_pos, Some last_turn_pos ->
         required_pos < preferred_pos && preferred_pos < last_turn_pos
     | _ -> false);
  check bool "last-turn relaxation no longer bypasses required_tools" true
    (file_not_contains_pattern "lib/keeper/keeper_run_tools.ml"
       "let tool_choice =\n                 if computed_surface.is_last_turn\n                 then current_params.tool_choice\n                 else if computed_surface.required_tool_names <> []");
  check bool "final-turn required tool prompt matches all-tools enforcement" true
    (file_contains_pattern "lib/keeper/keeper_run_tools.ml"
       "You MUST either use every");
  check bool "final-turn required tool prompt does not allow one-tool partial success" true
    (file_not_contains_pattern "lib/keeper/keeper_run_tools.ml"
       "call at least one");
  check bool "docker PR lifecycle harness default splits create/review tools" true
    (file_contains_pattern
       "scripts/harness/workload/keeper_docker_pr_lifecycle_reprobe.sh"
       {|REQUIRED_TOOLS_LEGACY="${REQUIRED_TOOLS:-}"|}
     && file_contains_pattern
          "scripts/harness/workload/keeper_docker_pr_lifecycle_reprobe.sh"
          {|CREATE_REQUIRED_TOOLS="${CREATE_REQUIRED_TOOLS:-${REQUIRED_TOOLS_LEGACY:-masc_web_search,keeper_bash,keeper_pr_create}}"|}
     && file_contains_pattern
          "scripts/harness/workload/keeper_docker_pr_lifecycle_reprobe.sh"
          {|REVIEW_REQUIRED_TOOLS="${REVIEW_REQUIRED_TOOLS:-${REQUIRED_TOOLS_LEGACY:-keeper_shell,keeper_pr_review_comment}}"|});
  check bool "runbook documents docker PR lifecycle split phases" true
    (file_contains_pattern "docs/KEEPER-DOCKER-PR-LIFECYCLE-REPROBE.md"
       "The create phase"
     && file_contains_pattern "docs/KEEPER-DOCKER-PR-LIFECYCLE-REPROBE.md"
          "requires `masc_web_search`, `keeper_bash`, and `keeper_pr_create`"
     && file_contains_pattern "docs/KEEPER-DOCKER-PR-LIFECYCLE-REPROBE.md"
          "the review phase requires `keeper_shell` and"
     && file_contains_pattern "docs/KEEPER-DOCKER-PR-LIFECYCLE-REPROBE.md"
          "second required tool keeps approval mandatory");
  check bool "docker PR lifecycle prompt accepts brokered route proof" true
    (file_contains_pattern
       "scripts/harness/workload/keeper_docker_pr_lifecycle_reprobe.sh"
       "via=docker, route_via=docker, via=brokered, or route_via=brokered")
  ;
  check bool "docker PR lifecycle branch matches worktree tool contract" true
    (file_contains_pattern
       "scripts/harness/workload/keeper_docker_pr_lifecycle_reprobe.sh"
       {|printf 'keeper-%s-agent/%s' "$keeper" "$RUN_ID"|}
     && file_contains_pattern
          "docs/KEEPER-DOCKER-PR-LIFECYCLE-REPROBE.md"
          "`keeper-<keeper>-agent/<run_id>`");
  check bool "docker PR lifecycle rejects stale proof branches before mutate" true
    (file_contains_pattern
       "scripts/harness/workload/keeper_docker_pr_lifecycle_reprobe.sh"
       "assert_no_proof_branch_collisions_for_mutate"
     && file_contains_pattern
          "scripts/harness/workload/keeper_docker_pr_lifecycle_reprobe.sh"
          "branch_collision_preflight"
     && file_contains_pattern "docs/KEEPER-DOCKER-PR-LIFECYCLE-REPROBE.md"
          "`branch_collision_preflight`");
  check bool "docker PR lifecycle gates review on create success evidence" true
    (file_contains_pattern
       "scripts/harness/workload/keeper_docker_pr_lifecycle_reprobe.sh"
       "all_create_results_ready_for_review"
     && file_contains_pattern
          "scripts/harness/workload/keeper_docker_pr_lifecycle_reprobe.sh"
          "create_success_markers_missing"
     && file_contains_pattern
          "scripts/harness/workload/keeper_docker_pr_lifecycle_reprobe.sh"
          "skipping review phase because create phase did not produce complete success evidence"
     && file_contains_pattern "docs/KEEPER-DOCKER-PR-LIFECYCLE-REPROBE.md"
          "`create-readiness-failures.jsonl`");
  check bool "docker PR lifecycle supports review-only resume" true
    (file_contains_pattern
       "scripts/harness/workload/keeper_docker_pr_lifecycle_reprobe.sh"
       {|PHASE_MODE="${PHASE_MODE:-both}"|}
     && file_contains_pattern
          "scripts/harness/workload/keeper_docker_pr_lifecycle_reprobe.sh"
          {|--phase create|review|both|}
     && file_contains_pattern
          "scripts/harness/workload/keeper_docker_pr_lifecycle_reprobe.sh"
          {|--review-resume|}
     && file_contains_pattern
          "scripts/harness/workload/keeper_docker_pr_lifecycle_reprobe.sh"
          {|if [[ "$REVIEW_RESUME" == "1" ]] || all_create_results_ready_for_review; then|}
     && file_contains_pattern "docs/KEEPER-DOCKER-PR-LIFECYCLE-REPROBE.md"
          "`--phase review --review-resume`");
  check bool "docker PR lifecycle review resolves fork head refs" true
    (file_contains_pattern
       "scripts/harness/workload/keeper_docker_pr_lifecycle_reprobe.sh"
       "proof_head_ref_for_keeper"
     && file_contains_pattern
          "scripts/harness/workload/keeper_docker_pr_lifecycle_reprobe.sh"
          {|gh pr view $review_head_ref -R $REPO_SLUG --json number,url,isDraft,headRefName|}
     && file_contains_pattern
          "scripts/harness/workload/keeper_docker_pr_lifecycle_reprobe.sh"
          "review_target_head"
     && file_contains_pattern "docs/KEEPER-DOCKER-PR-LIFECYCLE-REPROBE.md"
          "owner-qualified `OWNER:BRANCH` head ref");
  check bool "keeper msg schema documents required_tool_names alias" true
    (file_contains_pattern "lib/keeper/keeper_schema.ml"
       "required_tool_names")

let test_keeper_msg_timeout_contracts () =
  check bool "keeper msg schema exposes timeout_sec" true
    (file_contains_pattern "lib/keeper/keeper_schema.ml"
       "Optional: overall cascade timeout (sec) for this keeper message call");
  check bool "keeper msg parses timeout_sec override" true
    (file_contains_pattern "lib/keeper/keeper_turn.ml"
       "get_float_opt args \"timeout_sec\"");
  check bool "keeper msg rejects non-positive timeout override" true
    (file_contains_pattern "lib/keeper/keeper_turn.ml"
       "timeout_sec must be a positive finite number");
  check bool "keeper msg forwards timeout_sec into Agent.run" true
    (file_contains_pattern "lib/keeper/keeper_turn.ml"
       "?oas_timeout_s:keeper_msg_oas_timeout_s");
  check bool "docker PR lifecycle harness decouples HTTP and keeper turn timeout" true
    (file_contains_pattern
       "scripts/harness/workload/keeper_docker_pr_lifecycle_reprobe.sh"
       {|KEEPER_TURN_TIMEOUT_SEC="${KEEPER_TURN_TIMEOUT_SEC:-900}"|});
  check bool "docker PR lifecycle harness sends keeper turn timeout" true
    (file_contains_pattern
       "scripts/harness/workload/keeper_docker_pr_lifecycle_reprobe.sh"
       {|--argjson timeout "$KEEPER_TURN_TIMEOUT_SEC"|});
  check bool "docker PR lifecycle harness pins server incarnation" true
    (file_contains_pattern
       "scripts/harness/workload/keeper_docker_pr_lifecycle_reprobe.sh"
       "SERVER_INCARNATION_ACTUAL");
  check bool "docker PR lifecycle harness checks incarnation during polling" true
    (file_contains_pattern
       "scripts/harness/workload/keeper_docker_pr_lifecycle_reprobe.sh"
       "assert_server_incarnation_unchanged");
  check bool "docker PR lifecycle harness captures incarnation failures under set -e" true
    (file_contains_pattern
       "scripts/harness/workload/keeper_docker_pr_lifecycle_reprobe.sh"
       {|if fields="$(capture_server_incarnation "$health_file")"; then|});
  check bool "docker PR lifecycle harness reports missing commit separately" true
    (file_contains_pattern
       "scripts/harness/workload/keeper_docker_pr_lifecycle_reprobe.sh"
       "server health missing build.commit for incarnation check");
  check bool "docker PR lifecycle harness records restart-lost requests" true
    (file_contains_pattern
       "scripts/harness/workload/keeper_docker_pr_lifecycle_reprobe.sh"
       "server_incarnation_changed");
  check bool "docker PR lifecycle prompt routes mutating git through docker bash" true
    (file_contains_pattern
       "scripts/harness/workload/keeper_docker_pr_lifecycle_reprobe.sh"
       "Use keeper_bash inside your Docker playground for proof-file creation and git add/commit/push");
  check bool "docker PR lifecycle prompt names keeper_bash for push" true
    (file_contains_pattern
       "scripts/harness/workload/keeper_docker_pr_lifecycle_reprobe.sh"
       "Commit and git push exactly branch");
  check bool "docker PR lifecycle prompt uses docker bash for proof edit" true
    (file_contains_pattern
       "scripts/harness/workload/keeper_docker_pr_lifecycle_reprobe.sh"
       "with keeper_bash from inside the Docker playground");
  check bool "docker PR lifecycle prompt forbids gh pr shell mutation" true
    (file_contains_pattern
       "scripts/harness/workload/keeper_docker_pr_lifecycle_reprobe.sh"
       "Do not run gh pr create, gh pr review, or other mutating GitHub commands through keeper_shell or keeper_bash");
  check bool "runbook documents server incarnation restart classification" true
    (file_contains_pattern "docs/KEEPER-DOCKER-PR-LIFECYCLE-REPROBE.md"
       "`server_incarnation_changed`");
  check bool "runbook documents keeper turn timeout" true
    (file_contains_pattern "docs/KEEPER-DOCKER-PR-LIFECYCLE-REPROBE.md"
       "`masc_keeper_msg.timeout_sec` through `KEEPER_TURN_TIMEOUT_SEC`")

let test_board_flusher_start_retry_contracts () =
  check bool "board flusher start has bounded CAS retry count" true
    (file_contains_pattern "lib/board_dispatch.ml"
       "let flusher_start_cas_retries = 3");
  check bool "board flusher CAS contention yields before retry" true
    (file_contains_pattern "lib/board_dispatch.ml"
       "Eio.Fiber.yield ()");
  check bool "board flusher CAS contention uses exponential backoff" true
    (file_contains_pattern "lib/board_dispatch.ml"
       "flusher_start_backoff_delay_s");
  check bool "board flusher CAS backoff is bounded" true
    (file_contains_pattern "lib/board_dispatch.ml"
       "flusher_start_backoff_cap_s");
  check bool "board flusher retry decrements attempts" true
    (file_contains_pattern "lib/board_dispatch.ml"
       "loop (attempts_left - 1)");
  check bool "board flusher retry has injected contention coverage" true
    (file_contains_pattern "test/test_board_dispatch.ml"
       "force_flusher_start_cas_conflicts_for_test 2");
  check bool "board flusher exhausted retry is operator visible" true
    (file_contains_pattern "lib/board_dispatch.ml"
       "Board flusher actor startup CAS contention exhausted")

let test_docker_config_storage_contracts () =
  check bool "production image base path remains app root" true
    (file_contains_pattern "Dockerfile" {|ENV MASC_BASE_PATH=/app|});
  check bool "production image config dir remains image-baked config root" true
    (file_contains_pattern "Dockerfile" {|ENV MASC_CONFIG_DIR=/app/config|});
  check bool "production image documents config root is not runtime storage" true
    (file_contains_pattern "Dockerfile"
       "this is the image-baked config root, not");
  check bool "production image declares runtime storage volume" true
    (file_contains_pattern "Dockerfile" {|VOLUME ["/app/.masc"]|});
  check bool "production image keeps runtime storage owned by appuser" true
    (file_contains_pattern "Dockerfile"
       {|chown -R appuser:appgroup /app/.masc|})

let test_tool_failure_classification_contracts () =
  check bool "tool failure classification uses typed class" true
    (file_contains_pattern "lib/mcp_server_eio_call_tool.ml"
       "type tool_failure_class =");
  check bool "workflow rejection class exists" true
    (file_contains_pattern "lib/mcp_server_eio_call_tool.ml"
       "| Workflow_rejection");
  check bool "policy rejection class exists" true
    (file_contains_pattern "lib/mcp_server_eio_call_tool.ml"
       "| Policy_rejection");
  check bool "runtime failure class exists" true
    (file_contains_pattern "lib/mcp_server_eio_call_tool.ml"
       "| Runtime_failure");
  check bool "log details expose failure class" true
    (file_contains_pattern "lib/mcp_server_eio_call_tool.ml"
       {|"failure_class"|});
  check bool "call path classifies once before log emit" true
    (file_contains_pattern "lib/mcp_server_eio_call_tool.ml"
       "let failure_class = classify_tool_failure_class error_detail")

let test_keeper_github_pr_tool_contracts () =
  check bool "dedicated keeper PR list tool exists" true
    (file_contains_pattern "lib/tool_shard.ml" {|name = "keeper_pr_list"|});
  check bool "dedicated keeper PR status tool exists" true
    (file_contains_pattern "lib/tool_shard.ml" {|name = "keeper_pr_status"|});
  check bool "dedicated keeper PR create tool exists" true
    (file_contains_pattern "lib/tool_shard.ml" {|name = "keeper_pr_create"|});
  check bool "PR create is draft-only" true
    (file_contains_pattern "lib/keeper/keeper_tool_github_pr.ml"
       {|[ "gh"; "pr"; "create" ]|}
     && file_contains_pattern "lib/keeper/keeper_tool_github_pr.ml"
          {|@ [ "--draft"; "--title"; title; "--body"; body ]|});
  check bool "keeper PR tools use scoped GH env" true
    (file_contains_pattern "lib/keeper/keeper_tool_github_pr.ml"
       "Keeper_gh_env.compose_base_with_gh_config");
  check bool "keeper PR tools verify credential materialization" true
    (file_contains_pattern "lib/keeper/keeper_tool_github_pr.ml"
       "Credential_materializer.verify_state");
  check bool "keeper PR create is exposed by github group" true
    (file_contains_pattern "config/tool_policy.toml"
       {|keeper_pr_create|});
  check bool "keeper core prompt routes PR review through native tool" true
    (file_contains_pattern "config/prompts/keeper.core_behavior.md"
       "PR REVIEW MUTATIONS"
     && file_contains_pattern "config/prompts/keeper.core_behavior.md"
          "keeper_pr_review_comment"
     && file_contains_pattern "config/prompts/keeper.core_behavior.md"
          {|event="REQUEST_CHANGES"|}
     && file_contains_pattern "config/prompts/keeper.core_behavior.md"
          {|event="APPROVE"|});
  check bool "keeper core prompt no longer teaches raw gh review mutation" true
    (file_not_contains_pattern "config/prompts/keeper.core_behavior.md"
       {|gh pr review <n>|});
  check bool "keeper review schema names non-comment review policy" true
    (file_contains_pattern "lib/tool_shard.ml"
       "Use REQUEST_CHANGES for actionable blockers"
     && file_contains_pattern "lib/tool_shard.ml"
          "use APPROVE only when the draft proof preflight permits it")

let test_keeper_pr_audit_contracts () =
  check bool "keeper fleet audit has explicit PR-create flag" true
    (file_contains_pattern "scripts/audit-keeper-fleet-readiness.py"
       "--require-pr-create-evidence");
  check bool "keeper fleet audit treats keeper_pr_create as creation evidence" true
    (file_contains_pattern "scripts/audit-keeper-fleet-readiness.py"
       "PR_CREATE_TOOLS");
  check bool "keeper fleet audit requires structured create markers" true
    (file_contains_pattern "scripts/audit-keeper-fleet-readiness.py"
       "has_gh_pr_create_marker");
  check bool "keeper fleet audit scans filesystem JSONL evidence" true
    (file_contains_pattern "scripts/audit-keeper-fleet-readiness.py"
       "pr_action_metric_paths"
     && file_contains_pattern "scripts/audit-keeper-fleet-readiness.py"
          "pr_creation_scan_paths"
     && file_contains_pattern "scripts/audit-keeper-fleet-readiness.py"
          {|root / "tool_calls"|});
  check bool "keeper fleet audit recognizes route_evidence docker markers" true
    (file_contains_pattern "scripts/audit-keeper-fleet-readiness.py"
       "route_evidence"
     && file_contains_pattern "scripts/audit-keeper-fleet-readiness.py"
          "route_evidence.via=docker");
  check bool "keeper fleet audit can scope lifecycle evidence by run id" true
    (file_contains_pattern "scripts/audit-keeper-fleet-readiness.py"
       "--evidence-run-id"
     && file_contains_pattern "scripts/audit-keeper-fleet-readiness.py"
          "load_harness_evidence_windows"
     && file_contains_pattern "scripts/harness/workload/keeper_docker_pr_lifecycle_reprobe.sh"
          "--evidence-run-id \"$RUN_ID\""
     && file_contains_pattern "scripts/harness/workload/keeper_docker_pr_lifecycle_reprobe.sh"
          "--harness-run-dir \"$RUN_DIR\"");
  check bool "keeper fleet audit survives live invalid utf8 rows" true
    (file_contains_pattern "scripts/audit-keeper-fleet-readiness.py"
       {|errors="replace"|})

let test_dashboard_warm_hydration_contracts () =
  check bool "execution default route hydrates cache on first success" true
    (file_contains_pattern "lib/server/server_dashboard_http_execution_surfaces.ml"
       "cached_surface_or_first_success_json _execution_cache");
  check bool "mission default route serves cached surface immediately" true
    (file_contains_pattern "lib/server/server_dashboard_http_core.ml"
       "cached_surface_or_first_success_json _mission_cache");
  check bool "namespace truth advertises initializing while execution warms" true
    (file_contains_pattern "lib/server/server_dashboard_http_namespace_truth.ml"
       {|("status", `String "initializing")|});
  check bool "execution render timeout is a named constant" true
    (file_contains_pattern "lib/dashboard/dashboard_execution.ml"
       "let render_timeout_s");
  check bool "execution proactive refresh timeout is extended" true
    (file_contains_pattern "lib/server/server_dashboard_http_execution_surfaces.ml"
       "MASC_DASHBOARD_EXECUTION_REFRESH_TIMEOUT_S");
  check bool "mission proactive refresh timeout is extended" true
    (file_contains_pattern "lib/server/server_dashboard_http_core.ml"
       "let mission_refresh_timeout_s")

let test_http_read_surface_contracts () =
  check bool "room status route now requires read auth" true
    (file_contains_pattern "lib/server/server_routes_http_routes_room.ml"
       {|"/api/v1/status" (fun request reqd ->
       with_read_auth|});
  check bool "room tasks route now requires read auth" true
    (file_contains_pattern "lib/server/server_routes_http_routes_room.ml"
       {|"/api/v1/tasks" (fun request reqd ->
       with_read_auth|});
  check bool "room agents route now requires read auth" true
    (file_contains_pattern "lib/server/server_routes_http_routes_room.ml"
       {|"/api/v1/agents" (fun request reqd ->
       with_read_auth|});
  check bool "room messages route now requires read auth" true
    (file_contains_pattern "lib/server/server_routes_http_routes_room.ml"
       {|"/api/v1/messages" (fun request reqd ->
       with_read_auth|});
  check bool "room route delegates status reads to protocol boundary" true
    (file_contains_pattern "lib/server/server_routes_http_routes_room.ml"
       "Room_protocol.status config");
  check bool "room route delegates task reads to protocol boundary" true
    (file_contains_pattern "lib/server/server_routes_http_routes_room.ml"
       "Room_protocol.tasks ?status_filter");
  check bool "room route delegates agent reads to protocol boundary" true
    (file_contains_pattern "lib/server/server_routes_http_routes_room.ml"
       "Room_protocol.agents ?status_filter config");
  check bool "room route delegates message reads to protocol boundary" true
    (file_contains_pattern "lib/server/server_routes_http_routes_room.ml"
       "Room_protocol.messages ?agent_filter");
  check bool "room route does not read Coord directly" true
    (file_not_contains_pattern "lib/server/server_routes_http_routes_room.ml"
       "Coord.");
  check bool "room route does not read Tempo directly" true
    (file_not_contains_pattern "lib/server/server_routes_http_routes_room.ml"
       "Tempo.");
  check bool "room protocol owns the Coord read boundary" true
    (file_contains_pattern "lib/room_protocol.ml"
       "Coord.get_tasks_raw config");
  check bool "provider run status route now requires read auth" true
    (file_contains_pattern "lib/server/server_routes_http_routes_provider_runs.ml"
       {|"/api/v1/agent-runs/" (fun request reqd ->
       with_read_auth|})

let test_operator_surface_route_contracts () =
  (* CP purge (phases 1-5): operator/command-plane HTTP+H2 surfaces deleted.
     All assertions in this test referenced source files that no longer exist. *)
  ()

let test_input_validation_contracts () =
  (* Bug #1602: broadcast must reject empty messages *)
  check bool "broadcast validates empty message" true
    (file_contains_pattern "lib/tool_inline_dispatch_comm.ml"
       {|"Broadcast message cannot be empty"|});
  check bool "broadcast trims whitespace before check" true
    (file_contains_pattern "lib/tool_inline_dispatch_comm.ml"
       {|String.trim message|});
  (* Bug #1609: cache must have automatic eviction *)
  check bool "cache has maybe_evict_expired function" true
    (file_contains_pattern "lib/cache_eio.ml"
       "let maybe_evict_expired config");
  check bool "cache get triggers batch eviction" true
    (file_contains_pattern "lib/cache_eio.ml"
       "maybe_evict_expired config")

let test_room_current_validation_contracts () =
  (* H2 gateway serves canonical namespace routes and keeps temporary room
     aliases so mixed dashboard/backend deployments do not break during rollout. *)
  check bool "h2 gateway serves project-snapshot endpoint" true
    (file_contains_pattern "lib/server/server_h2_gateway.ml"
       {|"/api/v1/dashboard/project-snapshot"|});
  check bool "h2 gateway serves namespace-truth endpoint alias" true
    (file_contains_pattern "lib/server/server_h2_gateway.ml"
       {|"/api/v1/dashboard/namespace-truth"|});
  check bool "h2 gateway keeps room-truth alias endpoint during rollout" true
    (file_contains_pattern "lib/server/server_h2_gateway.ml"
       {|"/api/v1/dashboard/room-truth"|});
  check bool "h2 gateway serves namespace current endpoint" true
    (file_contains_pattern "lib/server/server_h2_gateway.ml"
       {|"/api/v1/namespace/current"|});
  check bool "h2 gateway maps invalid namespace writes to 400" true
    (file_contains_pattern "lib/server/server_h2_gateway.ml"
       {|Invalid_argument msg|});
  check bool "h2 gateway keeps room current alias endpoint during rollout" true
    (file_contains_pattern "lib/server/server_h2_gateway.ml"
       {|"/api/v1/room/current"|})

let test_root_redirect_contracts () =
  check bool "http root redirects to dashboard" true
    (file_contains_pattern "lib/server/server_routes_http_routes_frontend.ml"
       {|Http.Router.get "/"|});
  check bool "http root keeps dashboard fallback redirect" true
    (file_contains_pattern "lib/server/server_routes_http_routes_frontend.ml"
       {|redirect_to_dashboard reqd|});
  check bool "http redirect sets dashboard location" true
    (file_contains_pattern "lib/server/server_routes_http_routes_frontend.ml"
       {|respond_redirect ~location:"/dashboard"|});
  check bool "h2 root responds with server identity" true
    (file_contains_pattern "lib/server/server_h2_gateway.ml"
       {|h2_respond_text h2_reqd "MASC MCP Server (HTTP/2)"|})


let test_dashboard_component_split_contracts () =
  check bool "harness health sections export verdict tone" true
    (file_contains_pattern "dashboard/src/components/harness-health-sections.ts"
       "export function verdictTone");
  check bool "harness health tests cover verdict tone" true
    (file_contains_pattern "dashboard/src/components/harness-health-sections.test.ts"
       "describe('verdictTone'");
  check bool "retired proof helpers module stays deleted" true
    (file_not_contains_pattern "dashboard/src/components/proof-helpers.ts"
       "export function");
  check bool "coord backend setup no longer references transaction companion after PG removal" true
    (file_not_contains_pattern "lib/coord/coord_utils_backend_setup.ml"
       "Transaction Pooler companion")

let test_mission_briefing_memory_guard_contracts () =
  check bool "mission briefing snapshot disables keeper payload" true
    (file_contains_pattern "lib/dashboard/dashboard_mission_briefing.ml"
       "~include_keepers:false");
  check bool "mission briefing snapshot no longer references command plane" true
    (file_not_contains_pattern "lib/dashboard/dashboard_mission_briefing.ml"
       "include_command_plane");
  check bool "mission briefing snapshot stays off command plane" true
    (file_contains_pattern "lib/dashboard/dashboard_mission_briefing.ml"
       "~include_summary_fields:false");
  check bool "mission briefing snapshot stays lightweight" true
    (file_contains_pattern "lib/dashboard/dashboard_mission_briefing.ml"
       "~lightweight_summary:true");
  check bool "mission briefing reuses mission keeper briefs" true
    (file_contains_pattern "lib/dashboard/dashboard_mission_briefing.ml"
       {|mission_json |> member_assoc "keeper_briefs"|});
  check bool "mission briefing card no longer forces eager operator snapshot" true
    (file_not_contains_pattern "dashboard/src/components/mission-briefing-card.ts"
       "refreshOperatorSnapshot({ force: true })")

let test_activity_surface_contracts () =
  check bool "observatory absorbs activity-derived panels" true
    (file_contains_pattern "dashboard/src/components/observatory/observatory.ts"
       "ObservatoryActivityPanels");
  check bool "dashboard fetches canonical activity graph route" true
    (file_contains_pattern "dashboard/src/api/actions.ts"
       "/api/v1/activity/graph");
  check bool "server exposes canonical activity events route" true
    (file_contains_pattern "lib/server/server_routes_http_routes_activity.ml"
       {|"/api/v1/activity/events"|});
  check bool "server exposes canonical activity graph route" true
    (file_contains_pattern "lib/server/server_routes_http_routes_activity.ml"
       {|"/api/v1/activity/graph"|});
  check bool "activity routes thread sw/clock instead of reading Eio_context directly" true
    (not
       (file_contains_pattern "lib/server/server_routes_http_routes_activity.ml"
          "Eio_context.get_switch"));
  check bool "server drops legacy social graph alias" true
    (not
       (file_contains_pattern "lib/server/server_routes_http_routes_activity.ml"
          {|"/api/v1/social-graph"|}));
  check bool "coord top-level module emits activity events" true
    (file_contains_pattern "lib/coord.ml"
       "Activity_graph.emit config");
  check bool "coord task lifecycle emits activity events via hook" true
    (file_contains_pattern "lib/coord/coord_task.ml"
       "emit_task_activity");
  check bool "coord broadcast emits activity events via hook" true
    (file_contains_pattern "lib/coord/coord_broadcast.ml"
       "(Atomic.get Coord_hooks.activity_emit_fn) config");
  check bool "board success paths emit activity events" true
    (file_contains_pattern "lib/tool_inline_dispatch_extra.ml"
       "Activity_graph.emit config")

let test_local_review_script_contracts () =
  check bool "local review script exists" true
    (file_contains_pattern "scripts/review/local-review.sh"
       "#!/usr/bin/env bash");
  check bool "local review script caches under .masc review-cache" true
    (file_contains_pattern "scripts/review/local-review.sh"
       ".masc/review-cache/local-review");
  check bool "local review script resolves shared git common dir cache root" true
    (file_contains_pattern "scripts/review/local-review.sh"
       "--git-common-dir");
  check bool "local review script keeps pending registry" true
    (file_contains_pattern "scripts/review/local-review.sh"
       ".pending.json");
  check bool "local review script chunks large diffs" true
    (file_contains_pattern "scripts/review/local-review.sh"
       "MASC_LOCAL_REVIEW_CHUNK_BYTES");
  check bool "local review script bounds reviewer request time" true
    (file_contains_pattern "scripts/review/local-review.sh"
       "--max-time");
  check bool "local review script exposes cache key print" true
    (file_contains_pattern "scripts/review/local-review.sh"
       "--print-cache-key")

let test_keeper_oas_cleanup_contracts () =
  check bool "keeper config no longer exposes stale unified turn flag" true
    (not
       (file_contains_pattern "lib/keeper/keeper_config.ml"
          "MASC_KEEPER_UNIFIED_TURN"));
  check bool "keeper turn comment no longer mentions context manager" true
    (not
       (file_contains_pattern "lib/keeper/keeper_turn.ml"
          "Context_manager"));
  check bool "tool compact comment now references OAS-backed pipeline" true
    (file_contains_pattern "lib/tool_compact.ml"
       "OAS-backed compaction pipeline")

let test_dashboard_executor_pool_contracts () =
  check bool "dashboard runtime support defines executor pool helper" true
    (file_contains_pattern "lib/server/server_dashboard_http_runtime_support.ml"
       "let run_dashboard_compute");
  check bool "dashboard runtime support submits compute to executor pool" true
    (file_contains_pattern "lib/server/server_dashboard_http_runtime_support.ml"
       "Eio.Executor_pool.submit_exn");
  check bool "mission refresh loop uses dashboard compute helper" true
    (file_contains_pattern "lib/server/server_dashboard_http_core.ml"
       "run_dashboard_compute ~mode:Offloaded_readonly ?net ?mono_clock ~sw");
  check bool "mission actor path uses dashboard compute helper" true
    (file_contains_pattern "lib/server/server_dashboard_http_core.ml"
       "run_dashboard_compute ~mode ?net ?mono_clock ~sw ~clock");
  check bool "execution refresh loop uses dashboard compute helper" true
    (file_contains_pattern "lib/server/server_dashboard_http_execution_surfaces.ml"
       "run_dashboard_compute ~mode:Offloaded_readonly ~sw ~clock ~net");
  check bool "server state captures mono_clock for threaded readonly compute" true
    (file_contains_pattern "lib/mcp_server.ml"
       "mono_clock: Eio.Time.Mono.ty Eio.Resource.t option");
  check bool "dashboard core threads state runtime caps into readonly compute" true
    (file_contains_pattern "lib/server/server_dashboard_http_core.ml"
       "let net, mono_clock = state_dashboard_runtime_caps state");
  check bool "dashboard core no longer reads global eio net directly" true
    (file_not_contains_pattern "lib/server/server_dashboard_http_core.ml"
       "Eio_context.get_net ()");
  check bool "dashboard core no longer reads global mono_clock directly" true
    (file_not_contains_pattern "lib/server/server_dashboard_http_core.ml"
       "Eio_context.get_mono_clock ()");
  check bool "execution parameterized path uses dashboard compute helper" true
    (file_contains_pattern "lib/server/server_dashboard_http_execution_surfaces.ml"
       "run_dashboard_compute ~mode:Offloaded_readonly ?net ?mono_clock ~sw");
  check bool "server bootstrap wires executor pool into dashboard" true
    (file_contains_pattern "lib/server/server_runtime_bootstrap.ml"
       "Server_dashboard_http.set_executor_pool exec_pool")

(* pg schema init contracts removed: init_pg_schemas_sequential was deleted in #3218 *)

let test_transport_route_contracts () =
  let transport_delete_path_verifies_full_mcp_auth =
    file_contains_pattern "lib/server/server_mcp_transport_http.ml"
      {|let handle_delete_mcp ~deps ?(profile = Full) request reqd =|}
    && file_contains_pattern "lib/server/server_mcp_transport_http.ml"
         {|deps.verify_mcp_auth ~base_path request|}
  in
  let h2_delete_path_verifies_full_mcp_auth =
    file_contains_pattern "lib/server/server_h2_gateway.ml"
      {|`DELETE, "/mcp" | `DELETE, "/mcp/managed" ->|}
    && file_contains_pattern "lib/server/server_h2_gateway.ml"
         {|verify_mcp_auth ~base_path httpun_request|}
  in
  check bool "frontend exposes ws discovery route" true
    (file_contains_pattern "lib/server/server_routes_http_routes_frontend.ml"
       {|Http.Router.get "/ws" websocket_discovery_handler|});
  check bool "mcp http agent injection preserves explicit legacy agent_name" true
    (file_contains_pattern "lib/server/server_mcp_transport_http.ml"
       {|Option.is_none existing_agent
                    && Option.is_none existing_legacy_agent|});
  check bool "h2 mcp post injects canonical http actor" true
    (file_contains_pattern "lib/server/server_h2_gateway.ml"
       "body_with_canonical_http_actor");
  check bool "h2 mcp post forwards internal keeper runtime" true
    (file_contains_pattern "lib/server/server_h2_gateway.ml"
       "is_verified_internal_keeper_request"
    && file_contains_pattern "lib/server/server_h2_gateway.ml"
         "~internal_keeper_runtime state");
  check bool "common http deps prefer runtime captured in server_state" true
    (file_contains_pattern "lib/server/server_routes_http_common.ml"
       "state.Mcp_server.sw");
  check bool "frontend exposes webrtc offer route" true
    (file_contains_pattern "lib/server/server_routes_http_routes_frontend.ml"
       {|Http.Router.post "/webrtc/offer"|});
  check bool "frontend exposes webrtc answer route" true
    (file_contains_pattern "lib/server/server_routes_http_routes_frontend.ml"
       {|Http.Router.post "/webrtc/answer"|});
  check bool "frontend webrtc routes require tool auth" true
    (file_contains_pattern "lib/server/server_routes_http_routes_frontend.ml"
       "let webrtc_signaling_handler ~tool_name signaling_fn request reqd =\n  with_tool_auth ~tool_name");
  check bool "h2 gateway exposes webrtc offer route" true
    (file_contains_pattern "lib/server/server_h2_gateway.ml"
       {|`POST, "/webrtc/offer"|});
  check bool "h2 gateway exposes webrtc answer route" true
    (file_contains_pattern "lib/server/server_h2_gateway.ml"
       {|`POST, "/webrtc/answer"|});
  check bool "transport delete path verifies full mcp auth" true
    transport_delete_path_verifies_full_mcp_auth;
  check bool "h2 delete path verifies full mcp auth" true
    h2_delete_path_verifies_full_mcp_auth;
  check bool "h2 gateway webrtc routes enforce tool auth" true
    (file_contains_pattern "lib/server/server_h2_gateway.ml"
       {|authorize_tool_request|}
    && file_contains_pattern "lib/server/server_h2_gateway.ml"
         {|~base_path:state.Mcp_server.room_config.base_path|}
    && file_contains_pattern "lib/server/server_h2_gateway.ml"
         {|~tool_name:"masc_webrtc_offer"|}
    && file_contains_pattern "lib/server/server_h2_gateway.ml"
         {|~tool_name:"masc_webrtc_answer"|});
  check bool "h2 gateway respects webrtc disabled state" true
    (file_contains_pattern "lib/server/server_h2_gateway.ml"
       {|Server_webrtc_transport.is_enabled ()|})

let test_transport_health_contracts () =
  check bool "standalone ws updates transport metrics on connect" true
    (file_contains_pattern "lib/server/server_ws_standalone.ml"
       {|Transport_metrics.set_ws_sessions|});
  check bool "transport metrics ws env parse matches runtime server" true
    (file_contains_pattern "lib/config/env_config_core.ml"
       {| | "false" | "0" | "no" -> false|});
  check bool "standalone ws reuses transport metrics env parser" true
    (file_contains_pattern "lib/server/server_ws_standalone.ml"
       {|Transport_metrics.ws_enabled ()|});
  check bool "transport health avoids room message scans" true
    (not
       (file_contains_pattern "lib/transport_metrics.ml"
          {|Coord.get_messages_raw_in_room|}))
  (* command plane topology reads guard removed (CP purge: Command_plane_v2 deleted) *)

let test_http_cancel_response_contracts () =
  check bool "main_eio preserves cancellation propagation before 500 fallback" true
    (file_contains_nearby_line_with_patterns "bin/main_eio.ml"
       ~anchor:{|else dispatch_route ~routes ~request ~path reqd|}
       ~patterns:[ {|Eio.Cancel.Cancelled _ as exn|}; {|raise exn|} ]
       ~max_lines:8);
  check bool "main_eio suppresses stale httpun response writes" true
    (file_contains_pattern "bin/main_eio.ml" {|let safe_reqd_respond|}
    && file_contains_pattern "bin/main_eio.ml"
         {|invalid state, currently handling error|}
    && file_contains_pattern "bin/main_eio.ml" {|reqd respond skipped|});
  check bool "main_eio 500 fallback is best-effort" true
    (file_contains_pattern "bin/main_eio.ml"
       {|try_internal_error_response|});
  check bool "standalone ws closed writer is not warning noise" true
    (file_contains_pattern "lib/server/server_ws_standalone.ml"
       {|Http_server_eio.Late_response.classify_write_failure|}
    && file_contains_pattern "lib/server/server_ws_standalone.ml"
         {|send_pong skipped|}
    && file_contains_pattern "lib/server/server_ws_standalone.ml"
         {|WS standalone handler closed before write completed|});
  check bool "standalone ws close diagnostics classify cleanup causes" true
    (file_contains_pattern "lib/server/server_ws_standalone.ml"
       {|log_ws_client_close_payload|}
    && file_contains_pattern "lib/server/server_ws_standalone.ml"
         {|client close|}
    && file_contains_pattern "lib/server/server_ws_standalone.ml"
         {|sse-forward send failed; cleaning up|}
    && file_contains_pattern "lib/server/server_ws_standalone.ml"
         {|standalone_ws_eof_summary|}
    && file_contains_pattern "lib/server/server_ws_standalone.ml"
         {|declared_len|}
    && file_contains_pattern "lib/server/server_ws_standalone.ml"
         {|chunk_len <= 0|})

let test_worktree_list_contracts () =
  check bool "worktree list stays read-only" true
    (file_contains_pattern "lib/tool_worktree.ml"
       {|let _tool_spec_read_only = [ "masc_worktree_list" ]|});
  check bool "dashboard worktree-status SSE writes are observed" true
    (file_contains_pattern "lib/server/server_routes_http_routes_dashboard.ml"
       "dashboard_worktree_status_sse_write"
    && file_contains_pattern "lib/server/server_routes_http_routes_dashboard.ml"
         "Telemetry_observe.observe_or_fail");
  check bool "dashboard worktree-status SSE close is observed" true
    (file_contains_pattern "lib/server/server_routes_http_routes_dashboard.ml"
       "dashboard_worktree_status_sse_close");
  check bool "dashboard worktree-status SSE route uses observed write/close helpers" true
    (file_contains_nearby_line_with_patterns
       "lib/server/server_routes_http_routes_dashboard.ml"
       ~anchor:{|/api/dashboard/worktree-status|}
       ~patterns:[ "observe_worktree_status_sse_write_all" ]
       ~max_lines:24
     && file_contains_nearby_line_with_patterns
          "lib/server/server_routes_http_routes_dashboard.ml"
          ~anchor:{|/api/dashboard/worktree-status|}
          ~patterns:[ "observe_worktree_status_sse_close" ]
          ~max_lines:24);
  check bool "dashboard worktree-status SSE writes fail fast" true
    (file_not_contains_pattern "lib/server/server_routes_http_routes_dashboard.ml"
       "List.iter (observe_worktree_status_sse_write writer) events");
  check bool "dashboard worktree-status SSE has no raw writer swallow" true
    (file_not_contains_pattern "lib/server/server_routes_http_routes_dashboard.ml"
       "try Httpun.Body.Writer.write_string writer event"
    && file_not_contains_pattern "lib/server/server_routes_http_routes_dashboard.ml"
         "try Httpun.Body.Writer.close writer with _ -> ()");
  check bool "worker oas no longer reads global net directly" true
    (file_not_contains_pattern "lib/worker_oas.ml"
       "Eio_context.get_net_opt ()");
  (* research dispatch assertions removed — lib/research/ subsystem deleted (#4715) *)
  check bool "worktree create/remove still require join" true
    (file_contains_pattern "lib/tool_worktree.ml"
       {|let _tool_spec_requires_join = [ "masc_worktree_create"; "masc_worktree_remove" ]|});
  check bool "worktree list excluded from join-required list" true
    (file_not_contains_pattern "lib/tool_worktree.ml"
       {|_tool_spec_requires_join = [|} ||
     file_not_contains_pattern "lib/tool_worktree.ml"
       {|"masc_worktree_remove"; "masc_worktree_list"|})


let test_oas_worker_capability_threading_contracts () =
  check bool "oas worker model-by-label accepts threaded sw capability" true
    (file_contains_pattern "lib/oas_worker.mli"
       "?sw:Eio.Switch.t ->");
  check bool "oas worker model-by-label accepts threaded net capability" true
    (file_contains_pattern "lib/oas_worker.mli"
       "?net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t ->")

let test_oas_capacity_restore_contracts () =
  check bool "operator judge backoff uses OAS local capacity" true
    (file_contains_pattern "lib/dashboard/dashboard_operator_judge.ml"
       "local_capacity_for_selections ~sw ~net");
  check bool "operator judge selection is routed through cascade config" true
    (file_contains_pattern "lib/dashboard/dashboard_operator_judge.ml"
       "Keeper_cascade_profile.Operator_judge");
  check bool "governance judge backoff uses OAS local capacity" true
    (file_contains_pattern "lib/dashboard/dashboard_governance_judge.ml"
       "local_capacity_for_selections ~sw ~net");
  check bool "governance judge selection is routed through cascade config" true
    (file_contains_pattern "lib/dashboard/dashboard_governance_judge.ml"
       "Keeper_cascade_profile.Governance_judge");
  check bool "autoresearch background gating restores OAS capacity query" true
    (file_contains_pattern "lib/autoresearch_codegen.ml"
       "local_capacity_for_selections ~sw ~net");
  check bool "autoresearch uses Eio context fallback for capacity probing" true
    (file_contains_pattern "lib/autoresearch_codegen.ml"
       "Eio_context.get_switch_opt (), Eio_context.get_net_opt ()")

let test_dashboard_timeout_guard_contracts () =
  check bool "http transport health route uses cached dashboard helper" true
    (file_contains_pattern "lib/server/server_routes_http_routes_dashboard.ml"
       {|let json = dashboard_transport_health_http_json ~state in|});
  check bool "dashboard shell helper accepts threaded clock capability" true
    (file_contains_pattern "lib/server/server_dashboard_http_core.ml"
       "let dashboard_shell_http_json ?clock");
  check bool "http dashboard shell route threads state clock" true
    (file_contains_pattern "lib/server/server_routes_http_routes_dashboard.ml"
       "dashboard_shell_http_json ?clock:state.Mcp_server.clock");
  check bool "h2 dashboard shell route threads state clock" true
    (file_contains_pattern "lib/server/server_h2_gateway.ml"
       "dashboard_shell_http_json ?clock:state.Mcp_server.clock");
  check bool "h2 transport health route uses cached dashboard helper" true
    (file_contains_pattern "lib/server/server_h2_gateway.ml"
       "dashboard_transport_health_http_json ~state");
  check bool "server dashboard transport health helper uses cached surface" true
    (file_contains_pattern "lib/server/server_dashboard_http_execution_surfaces.ml"
       {|cached_surface_json _transport_health_cache|});
  check bool "shell timeout detector recognizes computation_timeout" true
    (file_contains_pattern "lib/server/server_dashboard_http_core.ml"
       {|Some (`String ("Compute timeout" | "computation_timeout"))|});
  check bool "shell meta cognition seeds stale fallback before refresh" true
    (file_contains_pattern "lib/server/server_dashboard_http_core.ml"
       "Dashboard_cache.seed_stale_if_missing key");
  check bool "namespace-truth pending confirm seeds stale fallback" true
    (file_contains_pattern "lib/server/server_dashboard_http_namespace_truth_support.ml"
       "Dashboard_cache.seed_stale_if_missing key");
  check bool "mission refresh dedupes inflight fetches" true
    (file_contains_pattern "dashboard/src/mission-actions.ts"
       "let inflightMissionSnapshotRefresh: Promise<void> | null = null");
  check bool "transport health panel dedupes inflight fetches" true
    (file_contains_pattern "dashboard/src/components/transport-health.ts"
       "let inflightTransportHealthRefresh: Promise<void> | null = null")

let test_namespace_truth_adaptive_timeout_contracts () =
  check bool "shell fiber uses adaptive timeout" true
    (file_contains_pattern "lib/server/server_dashboard_http_namespace_truth.ml"
       "shell_timeout_s");
  check bool "namespace-truth warm timeout is a named constant" true
    (file_contains_pattern "lib/server/server_dashboard_http_namespace_truth.ml"
       "let warm_timeout_s");
  check bool "namespace-truth cold timeout is a named constant" true
    (file_contains_pattern "lib/server/server_dashboard_http_namespace_truth.ml"
       "let cold_timeout_s");
  check bool "shell_warmed tracking exists" true
    (file_contains_pattern "lib/server/server_dashboard_http_execution_surfaces.ml"
       "_shell_warmed")

let test_http_client_fd_safety_contracts () =
  check bool "masc http client forbids direct Cohttp client construction in docs" true
    (file_contains_pattern "lib/masc_http_client/masc_http_client.ml"
       "instead of [Cohttp_eio.Client.make] directly");
  check bool "voice bridge builds clients through masc http client" true
    (file_contains_pattern "lib/voice/voice_bridge_core.ml"
       "Masc_http_client.make_closing_client");
  check bool "otel exporter builds clients through masc http client" true
    (file_contains_pattern "lib/opentelemetry_client_cohttp_eio.ml"
       "Masc_http_client.make_closing_client");
  ()

let test_runtime_precondition_contracts () =
  check bool "graphql routes expose result-based server state lookup" true
    (file_contains_pattern "lib/server/server_routes_http_pages.ml"
       "let get_server_state_result () =");
  (* with_server_state removed: h2 governance case routes retired,
     remaining routes do not need server state guard. *)
  ()

let file_uses_masc_dir_helper file =
  List.exists
    (fun pattern -> file_contains_pattern file pattern)
    [
      "Common.masc_dir_from_base_path";
      "Common.masc_dirname";
      "Masc_paths.masc_dir_from_base_path";
      "Masc_paths.masc_dirname";
    ]

(* #9571: MASC dirname SSOT — every runtime path that lives under
   [base_path/.masc/...] must go through [Common.masc_dir_from_base_path]
   instead of inlining the literal [".masc/<sub>"].  These contracts
   cover the first migration batch (issue triage 2026-04-25); a future
   PR can extend them as remaining call sites are migrated.

   Each entry asserts: the migrated file uses the helper AND no
   longer contains the inlined literal.  Either side regressing breaks
   the SSOT and this test catches it before merge. *)
let test_masc_dirname_ssot_contracts () =
  let migrated_files = [
    (* batch 1 (#10237) *)
    "lib/auth.ml";
    "lib/board_votes.ml";
    "lib/discovery_history.ml";
    "lib/handover_eio.ml";
    "lib/institution_eio.ml";
    "lib/repo_synthesis_benchmark.ml";
    "lib/tool_blob_store/tool_blob_store.ml";
    (* batch 2 (#10249) *)
    "lib/config_dir_resolver.ml";
    "lib/mcp_server_eio_resource.ml";
    "lib/oas_worker_cascade.ml";
    "lib/procedural_memory.ml";
    (* batch 3 (#10257) *)
    "lib/exec_core.ml";
    "lib/keeper/keeper_accountability.ml";
    (* batch 4 (#10262) *)
    "lib/server/server_routes_http_routes_dashboard.ml";
    "lib/keeper/keeper_approval_queue.ml";
    (* batch 5 (#10266) *)
    "lib/server/server_routes_http_routes_sidecar.ml";
    "lib/keeper/keeper_status_detail.ml";
    (* batch 6 (this PR — gate channel state legacy paths, relative-only) *)
    "lib/gate/channel_gate_discord_state.ml";
    "lib/gate/channel_gate_imessage_state.ml";
    "lib/gate/channel_gate_discord_names.ml";
  ] in
  (* Accepted SSOT helper references.  Listed explicitly rather than using
     a substring matcher so each form is auditable.  Add new references
     here when a future batch introduces a new alias or helper. *)
  let masc_dir_helper_patterns = [
    "Common.masc_dir_from_base_path";       (* base-rooted helper *)
    "Masc_paths.masc_dir_from_base_path";   (* alias re-export *)
    "Common.masc_dirname";                  (* relative-only constant *)
    "Common.auth_dir_from_base_path";       (* derived auth root helper *)
    "Common.agents_dir_from_base_path";     (* derived auth agents helper *)
  ] in
  let file_uses_masc_dir_helper file =
    List.exists (fun p -> file_contains_pattern file p)
      masc_dir_helper_patterns
  in
  List.iter
    (fun file ->
       check bool
         (Printf.sprintf "%s references an approved masc_dir SSOT helper" file)
         true
         (file_uses_masc_dir_helper file);
       check bool
         (Printf.sprintf "%s no longer inlines \".masc/\"" file)
         true
         (file_not_contains_pattern file "\".masc/");
       check bool
         (Printf.sprintf "%s no longer inlines standalone \".masc\"" file)
         true
         (file_not_contains_pattern file "\".masc\""))
    migrated_files

(* #9516: SSOT fingerprint CI gate — verify that the `make check-ssot`
   target and `scripts/check-spec-truth.sh` are properly wired into the
   build system and CI workflow.  These contracts ensure:
   1. `mk/quality.mk` defines a `check-ssot` phony target.
   2. The target delegates to all three SSOT sub-gates.
   3. `scripts/check-spec-truth.sh` exists with the expected contract
      structure (orphan spec validation via `Mirrors:` annotation scanning).
   4. The CI meta-gates step invokes `check-spec-truth.sh`. *)
let test_ssot_fingerprint_gate_contracts () =
  check bool "quality.mk declares check-ssot rule header" true
    (file_contains_pattern "mk/quality.mk" "check-ssot:");
  check bool "quality.mk declares check-ssot as phony" true
    (file_contains_line_with_patterns "mk/quality.mk" [ ".PHONY:"; "check-ssot" ]);
  check bool "check-ssot target runs ratchet bypass script" true
    (file_contains_pattern "mk/quality.mk" "bash scripts/check-ssot.sh");
  check bool "check-ssot target runs spawn drift script" true
    (file_contains_pattern "mk/quality.mk" "bash scripts/ci/check-ssot-spawn-drift.sh");
  check bool "check-ssot target runs spec truth script" true
    (file_contains_pattern "mk/quality.mk" "bash scripts/check-spec-truth.sh");
  check bool "check-spec-truth script exists" true
    (file_contains_pattern "scripts/check-spec-truth.sh" "orphan spec");
  check bool "check-spec-truth scans Mirrors annotations" true
    (file_contains_pattern "scripts/check-spec-truth.sh" "Mirrors:");
  check bool "check-spec-truth resolves file-path references" true
    (file_contains_pattern "scripts/check-spec-truth.sh" "resolve_mirrors_ref");
  check bool "check-spec-truth exits non-zero on orphan" true
    (file_contains_pattern "scripts/check-spec-truth.sh" "orphan_count");
  check bool "check-spec-truth guards resolver failures under set -e" true
    (file_contains_pattern "scripts/check-spec-truth.sh"
       "if resolve_mirrors_ref \"$token\"; then");
  check bool "check-spec-truth surfaces parser failures" true
    (file_not_contains_pattern "scripts/check-spec-truth.sh"
       "2>/dev/null || true");
  check bool "check-spec-truth references meta-issue #9516" true
    (file_contains_pattern "scripts/check-spec-truth.sh" "#9516");
  check bool "ci meta gates step runs check-spec-truth" true
    (file_contains_pattern ".github/workflows/ci.yml"
       "bash scripts/check-spec-truth.sh")

let test_human_approval_credential_boundary_contracts () =
  (* Issue #9733: the bypass-label actor check cannot distinguish a real
     human from an agent using the same owner credentials.  The
     approve-agent-pr workflow introduces a hard credential boundary by
     requiring approval through a GitHub Environment with required reviewers.
     Even an agent holding the owner token cannot self-approve an environment
     deployment — that requires an interactive click in the GitHub UI. *)
  check bool "approve-agent-pr workflow exists" true
    (file_contains_pattern ".github/workflows/approve-agent-pr.yml"
       "name: Approve Agent PR");
  check bool "approve-agent-pr workflow uses workflow_dispatch trigger" true
    (file_contains_pattern ".github/workflows/approve-agent-pr.yml"
       "workflow_dispatch");
  check bool "approve-agent-pr workflow accepts pr_number input" true
    (file_contains_pattern ".github/workflows/approve-agent-pr.yml"
       "pr_number");
  check bool "approve-agent-pr workflow gates on human-approval environment" true
    (file_contains_pattern ".github/workflows/approve-agent-pr.yml"
       "environment: human-approval");
  check bool "approve-agent-pr workflow applies bypass label after gate" true
    (file_contains_pattern ".github/workflows/approve-agent-pr.yml"
       "addLabels");
  check bool "approve-agent-pr workflow posts credential-boundary comment" true
    (file_contains_pattern ".github/workflows/approve-agent-pr.yml"
       "masc-human-approval-gate");
  check bool "approve-agent-pr workflow documents credential boundary purpose" true
    (file_contains_pattern ".github/workflows/approve-agent-pr.yml"
       "credential boundary");
  check bool "agent draft policy script documents credential-boundary workflow" true
    (file_contains_pattern "scripts/ci/check-agent-draft-policy.sh"
       "approve-agent-pr.yml");
  check bool "agent draft policy script documents human-approval environment" true
    (file_contains_pattern "scripts/ci/check-agent-draft-policy.sh"
       "human-approval")

let test_human_approval_environment_check_contracts () =
  check bool "human approval environment check script exists" true
    (Sys.file_exists
       (source_path "scripts/check-human-approval-env.sh"));
  check bool "human approval environment check reads GitHub Environment" true
    ((file_contains_pattern "scripts/check-human-approval-env.sh"
        "environments/$ENVIRONMENT_ENCODED")
     && file_contains_pattern "scripts/check-human-approval-env.sh" "@uri");
  check bool "human approval environment check documents environment override" true
    (file_contains_pattern "scripts/check-human-approval-env.sh"
       "--environment staging");
  check bool "human approval environment check requires reviewer rule" true
    (file_contains_pattern "scripts/check-human-approval-env.sh"
       "required_reviewers");
  check bool "human approval environment check fails empty reviewer rule" true
    (file_contains_pattern "scripts/check-human-approval-env.sh"
       "required reviewer protection rule missing or empty");
  check bool "human approval environment check can require named reviewer" true
    (file_contains_pattern "scripts/check-human-approval-env.sh"
       "--require-reviewer");
  check bool "human approval environment check can require prevent self-review" true
    (file_contains_pattern "scripts/check-human-approval-env.sh"
       "--require-prevent-self-review");
  check bool "human approval environment check warns when self-review remains allowed" true
    (file_contains_pattern "scripts/check-human-approval-env.sh"
       "prevent_self_review is false");
  check bool "human approval environment check reports normalized reviewers" true
    (file_contains_pattern "scripts/check-human-approval-env.sh"
       ".login // .slug // .name // .id // empty")

let test_copilot_zero_diff_cleanup_contracts () =
  check bool "copilot zero-diff cleanup script exists" true
    (Sys.file_exists
       (source_path "scripts/cleanup-copilot-zero-diff-prs.sh"));
  check bool "copilot zero-diff cleanup is dry-run by default" true
    (file_contains_pattern "scripts/cleanup-copilot-zero-diff-prs.sh"
       "Dry run only");
  check bool "copilot zero-diff cleanup requires explicit close flag" true
    (file_contains_pattern "scripts/cleanup-copilot-zero-diff-prs.sh"
       "--close");
  check bool "copilot zero-diff cleanup targets copilot author by default" true
    (file_contains_pattern "scripts/cleanup-copilot-zero-diff-prs.sh"
       "copilot-swe-agent");
  check bool "copilot zero-diff cleanup filters WIP titles" true
    (file_contains_pattern "scripts/cleanup-copilot-zero-diff-prs.sh"
       "startswith($prefix)");
  check bool "copilot zero-diff cleanup uses GraphQL file totals" true
    (file_contains_pattern "scripts/cleanup-copilot-zero-diff-prs.sh"
       "files(first: 1) { totalCount }");
  check bool "copilot zero-diff cleanup preserves review threads" true
    (file_contains_pattern "scripts/cleanup-copilot-zero-diff-prs.sh"
       "reviewThreads(first: 1)");
  check bool "copilot zero-diff cleanup skips active discussion" true
    (file_contains_pattern "scripts/cleanup-copilot-zero-diff-prs.sh"
       "SKIP_ACTIVE");
  check bool "copilot zero-diff cleanup does not delete branches" true
    (file_not_contains_pattern "scripts/cleanup-copilot-zero-diff-prs.sh"
       "--delete-branch")

(* Dashboard bootstrap (loop priority #7) — guard against:
   1. SSOT [dashboard_bootstrap_http_json] removed/renamed
   2. HTTP/1.1 route forgotten in [server_routes_http_routes_dashboard]
   3. HTTP/2 dispatch forgotten in [server_h2_gateway]
   4. Slice list drift (the SSOT must list all six slices)
   5. Public-read error payload regressing to [Printexc.to_string]
   The cross-transport SSOT exists precisely to prevent (4) — these
   tests catch the surrounding wiring that the SSOT cannot enforce
   on its own. *)
let test_dashboard_bootstrap_contracts () =
  check bool "bootstrap SSOT exported in dashboard http mli" true
    (file_contains_pattern "lib/server/server_dashboard_http.mli"
       "dashboard_bootstrap_http_json");
  check bool "bootstrap SSOT defined in dashboard http ml" true
    (file_contains_pattern "lib/server/server_dashboard_http.ml"
       "dashboard_bootstrap_http_json");
  check bool "HTTP/1.1 router registers /api/v1/dashboard/bootstrap" true
    (file_contains_pattern "lib/server/server_routes_http_routes_dashboard.ml"
       "\"/api/v1/dashboard/bootstrap\"");
  check bool "HTTP/1.1 route delegates to SSOT" true
    (file_contains_pattern "lib/server/server_routes_http_routes_dashboard.ml"
       "dashboard_bootstrap_http_json ~state ~sw ~clock");
  check bool "HTTP/2 gateway dispatches /api/v1/dashboard/bootstrap" true
    (file_contains_pattern "lib/server/server_h2_gateway.ml"
       "\"/api/v1/dashboard/bootstrap\"");
  check bool "HTTP/2 gateway delegates to SSOT" true
    (file_contains_pattern "lib/server/server_h2_gateway.ml"
       "dashboard_bootstrap_http_json ~state ~sw ~clock");
  check bool "HTTP/2 dashboard reads use shared public-read wrapper" true
    (file_contains_pattern "lib/server/server_h2_gateway.ml"
       "| `GET, \"/api/v1/dashboard/shell\" ->\n          with_h2_public_read");
  check bool "HTTP/2 public-read wrapper enforces read auth" true
    (file_contains_pattern "lib/server/server_h2_gateway.ml"
       "authorize_read_request");
  check bool "HTTP/2 public-read wrapper applies agent rate limit" true
    (file_contains_pattern "lib/server/server_h2_gateway.ml"
       "Rate_limit.check_agent_global");
  check bool "HTTP/2 public-read wrapper returns cold-start payload" true
    (file_contains_pattern "lib/server/server_h2_gateway.ml"
       "not_initialized_response path");
  (* Slice list — the SSOT must list all six slices it bundles. *)
  let slice_listed name =
    file_contains_pattern "lib/server/server_dashboard_http.ml"
      (Printf.sprintf "slice \"%s\"" name)
  in
  check bool "bootstrap bundles shell" true (slice_listed "shell");
  check bool "bootstrap bundles execution" true (slice_listed "execution");
  check bool "bootstrap bundles planning" true (slice_listed "planning");
  check bool "bootstrap bundles namespace_truth" true
    (slice_listed "namespace_truth");
  check bool "bootstrap bundles goals" true (slice_listed "goals");
  check bool "bootstrap bundles goal_loop_status" true
    (slice_listed "goal_loop_status");
  (* Public-read error sanitization — bootstrap must not surface raw
     [Printexc.to_string exn] to the client.  The stable
     {error: "slice_unavailable", slice: <name>} shape should be the
     only error payload reaching the wire. *)
  check bool "bootstrap returns sanitized error string" true
    (file_contains_pattern "lib/server/server_dashboard_http.ml"
       "\"slice_unavailable\"");
  check bool "bootstrap does not leak Printexc to client payload"
    true
    (* The server-side warn log still uses Printexc; what we forbid is
       returning that text under the slice [error] key.  Detect by
       absence of the leak pattern in the per-slice value construction. *)
    (file_not_contains_pattern "lib/server/server_dashboard_http.ml"
       "(\"error\", `String (Printexc.to_string exn))")

(* RFC-0037 PR-1 — Board_attachment_meta carrier on post.meta_json.

   These guards capture the contract that ties the carrier module to the
   post type:
   - the carrier module + .mli exist with the agreed surface
   - Board_types.post still carries meta_json (the carrier's storage slot)
   - the JSON key SSOT is "attachments"
   - of_yojson returns a result type (total, no silent raises)
   - id generator uses the "a-" prefix (RFC §6 Q2 default)

   If any of these breaks, the carrier mechanism's load-bearing assumption
   is gone and the next reader will silently get [] instead of a parse
   error.  See loop iter 5 / 6 for the rationale. *)
let test_board_attachment_meta_contracts () =
  check bool "carrier mli exists with attach helper" true
    (file_contains_pattern "lib/board_attachment_meta.mli"
       "val attach_to_post_meta");
  check bool "carrier mli exposes parse total" true
    (file_contains_pattern "lib/board_attachment_meta.mli"
       "val of_yojson : Yojson.Safe.t -> (t, error) result");
  check bool "carrier mli exposes meta_json_key SSOT" true
    (file_contains_pattern "lib/board_attachment_meta.mli"
       "val meta_json_key : string");
  check bool "carrier ml binds meta_json_key to \"attachments\"" true
    (file_contains_pattern "lib/board_attachment_meta.ml"
       "let meta_json_key = \"attachments\"");
  check bool "carrier ml uses 'a-' id prefix (RFC-0037 Q2 default)" true
    (file_contains_pattern "lib/board_attachment_meta.ml"
       "Random_id.prefixed ~prefix:\"a-\"");
  check bool "carrier kind union has all 4 variants" true
    (file_contains_pattern "lib/board_attachment_meta.mli"
       "| Image\n  | Video\n  | Youtube\n  | External_link");
  check bool "Board_types.post still has meta_json carrier slot" true
    (file_contains_pattern "lib/board_types/board_types.mli"
       "meta_json : Yojson.Safe.t option");
  check bool "carrier test registered in test/dune" true
    (file_contains_pattern "test/dune"
       "test_board_attachment_meta")

let () =
  run "ci_hardening_source"
    [
      ("source_guard", [
           test_case "sync and asset contracts" `Quick test_ci_sync_and_asset_contracts;
           test_case "agent draft policy script" `Quick
             test_agent_draft_policy_script;
           test_case "pr automation draft guard contracts" `Quick
             test_pr_automation_draft_guard_contracts;
           test_case "contract harness contracts" `Quick
             test_contract_harness_contracts;
           test_case "health and ci diagnostics" `Quick test_health_and_ci_runner_diagnostics;
           test_case "release truth contracts" `Quick test_release_truth_contracts;
           test_case "oas pin source contracts" `Quick test_oas_pin_source_contracts;
           test_case "doc truth guard contracts" `Quick test_doc_truth_guard_contracts;
           test_case "storage truth guard contracts" `Quick
             test_storage_truth_guard_contracts;
           test_case "proof store reader truth contracts" `Quick
             test_proof_store_reader_truth_contracts;
           test_case "keeper agent upgrade source contracts" `Quick
             test_keeper_agent_upgrade_source_contracts;
           test_case "route auth contracts" `Quick test_route_auth_contracts;
           test_case "http write auth contracts" `Quick test_http_write_auth_contracts;
           test_case "tool admin snapshot auth contracts" `Quick
             test_tool_admin_snapshot_auth_contracts;
           test_case "keeper direct reply contracts" `Quick
             test_keeper_direct_reply_contracts;
           test_case "keeper list cache atomic contracts" `Quick
             test_keeper_list_cache_atomic_contracts;
           test_case "keeper zombie field contracts" `Quick
             test_keeper_zombie_field_contracts;
           test_case "keeper sandbox credential volume contracts" `Quick
             test_keeper_sandbox_credential_volume_contracts;
           test_case "keeper docker multi-keeper isolation contracts" `Quick
             test_keeper_docker_multikeeper_isolation_contracts;
           test_case "keeper required tool contracts" `Quick
             test_keeper_required_tool_contracts;
           test_case "keeper msg timeout contracts" `Quick
             test_keeper_msg_timeout_contracts;
           test_case "board flusher start retry contracts" `Quick
             test_board_flusher_start_retry_contracts;
           test_case "docker config storage contracts" `Quick
             test_docker_config_storage_contracts;
          test_case "tool failure classification contracts" `Quick
            test_tool_failure_classification_contracts;
          test_case "keeper github PR tool contracts" `Quick
            test_keeper_github_pr_tool_contracts;
          test_case "keeper PR audit contracts" `Quick
            test_keeper_pr_audit_contracts;
          test_case "dashboard warm hydration contracts" `Quick
            test_dashboard_warm_hydration_contracts;
           test_case "http read surface contracts" `Quick test_http_read_surface_contracts;
           test_case "operator surface route contracts" `Quick
             test_operator_surface_route_contracts;
           test_case "input validation contracts" `Quick test_input_validation_contracts;
           test_case "room current validation contracts" `Quick
             test_room_current_validation_contracts;
           test_case "root redirect contracts" `Quick test_root_redirect_contracts;
           test_case "dashboard component split contracts" `Quick test_dashboard_component_split_contracts;
           test_case "mission briefing memory guard contracts" `Quick
             test_mission_briefing_memory_guard_contracts;
           test_case "activity surface contracts" `Quick test_activity_surface_contracts;
           test_case "local review script contracts" `Quick test_local_review_script_contracts;
           test_case "keeper oas cleanup contracts" `Quick test_keeper_oas_cleanup_contracts;
           test_case "dashboard executor pool contracts" `Quick
             test_dashboard_executor_pool_contracts;
           test_case "transport route contracts" `Quick
             test_transport_route_contracts;
           test_case "transport health contracts" `Quick
             test_transport_health_contracts;
           test_case "http cancel response contracts (#13059)" `Quick
             test_http_cancel_response_contracts;
           test_case "worktree list contracts" `Quick
             test_worktree_list_contracts;
           test_case "oas worker capability threading contracts" `Quick
             test_oas_worker_capability_threading_contracts;
           test_case "oas capacity restore contracts" `Quick
             test_oas_capacity_restore_contracts;
           test_case "dashboard timeout guard contracts" `Quick
             test_dashboard_timeout_guard_contracts;
           test_case "http client fd safety contracts" `Quick
             test_http_client_fd_safety_contracts;
           test_case "namespace-truth adaptive timeout contracts" `Quick
             test_namespace_truth_adaptive_timeout_contracts;
           test_case "runtime precondition contracts" `Quick
             test_runtime_precondition_contracts;
           test_case "masc_dirname SSOT contracts (#9571 batch 1)" `Quick
             test_masc_dirname_ssot_contracts;
           test_case "SSOT fingerprint gate contracts (#9516)" `Quick
             test_ssot_fingerprint_gate_contracts;
           test_case "human approval credential boundary contracts (#9733)" `Quick
             test_human_approval_credential_boundary_contracts;
           test_case "human approval environment check contracts (#12561)" `Quick
             test_human_approval_environment_check_contracts;
           test_case "copilot zero-diff cleanup contracts (#12567)" `Quick
             test_copilot_zero_diff_cleanup_contracts;
           test_case "dashboard bootstrap contracts (loop #7)" `Quick
             test_dashboard_bootstrap_contracts;
           test_case "board attachment meta contracts (RFC-0037 PR-1)" `Quick
             test_board_attachment_meta_contracts;
         ]);
    ]
