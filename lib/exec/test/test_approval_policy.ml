(** A3 approval_policy + exec_gate tests — policy decides, gate
    dispatches.  Tests use [assert false] on the error arm so the
    lib-scope ratchet on crash-call count stays green. *)

open Masc_exec

let bin_ok name =
  match Exec_program.of_string name with
  | Ok b -> b
  (* bin must classify *)
  | Error _ -> assert false

let simple ?(args = []) ?(env = []) ?(cwd = None) ?(redirects = [])
    ?(sandbox = Sandbox_target.host ()) bin
    : Shell_ir.simple =
  { bin; args; env; cwd; redirects; sandbox }

let lit s = Shell_ir.Lit (s, Shell_ir.default_meta)
let var s = Shell_ir.Var (s, Shell_ir.default_meta)
let concat parts = Shell_ir.Concat parts

let default_policy : Approval_policy.t =
  { raw_source = "(test)"; summary = "(test summary)" }

let strict_overlay = Approval_config.enforced_all

let internal_overlay : Approval_config.agent_overlay =
  {
    safe_trust = Auto_safe;
    audited_trust = Auto_safe;
    privileged_trust = Auto_safe;
  }

let observe_overlay : Approval_config.agent_overlay =
  {
    safe_trust = Observe;
    audited_trust = Observe;
    privileged_trust = Enforced;
  }

let suggest_overlay : Approval_config.agent_overlay =
  {
    safe_trust = Suggest;
    audited_trust = Suggest;
    privileged_trust = Enforced;
  }

(* -- policy decide -------------------------------------------------- *)

let test_safe_bin_strict_asks () =
  let s = simple (bin_ok "ls") in
  let caps = Capability_check.of_simple s in
  match Approval_policy.decide default_policy ~overlay:strict_overlay ~caps ~simple:s with
  | Verdict.Ask req ->
    assert (Exec_program.to_string req.bin = "ls")
  | _ -> assert false

let test_safe_bin_allowed_with_overlay () =
  let s = simple (bin_ok "ls") in
  let caps = Capability_check.of_simple s in
  match Approval_policy.decide default_policy ~overlay:internal_overlay ~caps ~simple:s with
  | Verdict.Allow t ->
    assert (Exec_program.to_string (Verdict.Trusted_argv.bin t) = "ls")
  | _ -> assert false

let test_privileged_bin_asks () =
  let s = simple (bin_ok "sudo") in
  let caps = Capability_check.of_simple s in
  match Approval_policy.decide default_policy ~overlay:strict_overlay ~caps ~simple:s with
  | Verdict.Ask req ->
    assert (Exec_program.to_string req.bin = "sudo")
  | _ -> assert false

let test_audited_bin_asks () =
  let s = simple (bin_ok "git") ~args:[ lit "status" ] in
  let caps = Capability_check.of_simple s in
  match Approval_policy.decide default_policy ~overlay:strict_overlay ~caps ~simple:s with
  | Verdict.Ask _ -> ()
  | _ -> assert false

let test_audited_bin_allowed_with_overlay () =
  let s = simple (bin_ok "git") ~args:[ lit "status" ] in
  let caps = Capability_check.of_simple s in
  match Approval_policy.decide default_policy ~overlay:internal_overlay ~caps ~simple:s with
  | Verdict.Allow t ->
    assert (Exec_program.to_string (Verdict.Trusted_argv.bin t) = "git")
  | _ -> assert false

let test_audited_bin_with_cwd_flag_allowed_with_overlay () =
  let s =
    simple (bin_ok "git")
      ~args:[ lit "-C"; lit "/tmp/repo"; lit "status" ]
  in
  let caps = Capability_check.of_simple s in
  match Approval_policy.decide default_policy ~overlay:internal_overlay ~caps ~simple:s with
  | Verdict.Allow t ->
    assert (Exec_program.to_string (Verdict.Trusted_argv.bin t) = "git")
  | _ -> assert false

let test_destructive_git_denies () =
  let s =
    simple (bin_ok "git")
      ~args:[ lit "push"; lit "--force"; lit "origin"; lit "main" ]
  in
  let caps = Capability_check.of_simple s in
  match Approval_policy.decide default_policy ~overlay:strict_overlay ~caps ~simple:s with
  | Verdict.Deny { reason = Destructive_git (Git_op.Destructive `Push_force); _ } ->
    ()
  | _ -> assert false

(* RFC-0254 §5.3: destructive git is a trust-independent catastrophic floor.
   Pre-RFC-0254 this test expected [Allow] under a permissive overlay
   ([privileged_trust = Auto_safe]) — that behavior was defect §2.2(4):
   loosening privileged trust to run [rm] simultaneously re-enabled
   [git push --force].  The floor now denies it regardless of overlay. *)
let test_destructive_git_denied_under_permissive_overlay () =
  let s =
    simple (bin_ok "git")
      ~args:[ lit "push"; lit "--force"; lit "origin"; lit "main" ]
  in
  let caps = Capability_check.of_simple s in
  match Approval_policy.decide default_policy ~overlay:internal_overlay ~caps ~simple:s with
  | Verdict.Deny { reason = Destructive_git (Git_op.Destructive `Push_force); _ } ->
    ()
  | _ -> assert false

let test_write_outside_denies () =
  let target = Path_scope.classify ~raw:"/etc/motd" ~cwd:"/tmp" in
  let redir =
    Redirect_scope.File
      { fd = 1; target; mode = Redirect_scope.Write }
  in
  let s = simple (bin_ok "echo") ~redirects:[ redir ] in
  let caps = Capability_check.of_simple s in
  match Approval_policy.decide default_policy ~overlay:internal_overlay ~caps ~simple:s with
  | Verdict.Deny { reason = Path_escape _; _ } -> ()
  | _ -> assert false

(* -- P9: trust_level dispatch tests --------------------------------- *)

let test_observe_safe_bin_allows () =
  let s = simple (bin_ok "ls") in
  let caps = Capability_check.of_simple s in
  match Approval_policy.decide default_policy ~overlay:observe_overlay ~caps ~simple:s with
  | Verdict.Allow t ->
    assert (Exec_program.to_string (Verdict.Trusted_argv.bin t) = "ls")
  | _ -> assert false

let test_observe_audited_bin_allows () =
  let s = simple (bin_ok "git") ~args:[ lit "status" ] in
  let caps = Capability_check.of_simple s in
  match Approval_policy.decide default_policy ~overlay:observe_overlay ~caps ~simple:s with
  | Verdict.Allow t ->
    assert (Exec_program.to_string (Verdict.Trusted_argv.bin t) = "git")
  | _ -> assert false

let test_observe_privileged_bin_asks () =
  let s = simple (bin_ok "sudo") in
  let caps = Capability_check.of_simple s in
  match Approval_policy.decide default_policy ~overlay:observe_overlay ~caps ~simple:s with
  | Verdict.Ask req ->
    assert (Exec_program.to_string req.bin = "sudo")
  | _ -> assert false

let test_suggest_safe_bin_suggests () =
  let s = simple (bin_ok "ls") in
  let caps = Capability_check.of_simple s in
  match Approval_policy.decide default_policy ~overlay:suggest_overlay ~caps ~simple:s with
  | Verdict.Suggest_confirm (t, token) ->
    assert (Exec_program.to_string (Verdict.Trusted_argv.bin t) = "ls");
    assert (token.risk_class = `Safe);
    assert (token.ttl_sec = 60.0)
  | _ -> assert false

let test_suggest_audited_bin_suggests () =
  let s = simple (bin_ok "git") ~args:[ lit "status" ] in
  let caps = Capability_check.of_simple s in
  match Approval_policy.decide default_policy ~overlay:suggest_overlay ~caps ~simple:s with
  | Verdict.Suggest_confirm (_, token) ->
    assert (token.risk_class = `Audited)
  | _ -> assert false

let test_suggest_privileged_bin_asks () =
  let s = simple (bin_ok "sudo") in
  let caps = Capability_check.of_simple s in
  match Approval_policy.decide default_policy ~overlay:suggest_overlay ~caps ~simple:s with
  | Verdict.Ask _ -> ()
  | _ -> assert false

(* RFC-0254 §5.3: a [Suggest] privileged trust used to downgrade
   [git push --force] to [Suggest_confirm].  The floor now denies it before
   any trust level is consulted, so even [privileged_trust = Suggest] yields
   [Deny]. *)
let test_destructive_git_denied_under_suggest_overlay () =
  let suggest_all : Approval_config.agent_overlay =
    { safe_trust = Suggest; audited_trust = Suggest; privileged_trust = Suggest }
  in
  let s =
    simple (bin_ok "git")
      ~args:[ lit "push"; lit "--force"; lit "origin"; lit "main" ]
  in
  let caps = Capability_check.of_simple s in
  match Approval_policy.decide default_policy ~overlay:suggest_all ~caps ~simple:s with
  | Verdict.Deny { reason = Destructive_git (Git_op.Destructive `Push_force); _ } ->
    ()
  | _ -> assert false

(* RFC-0254 §5.3 regression guard for defect §2.2(4): the destructive-git
   floor is independent of every trust level.  No overlay — not even the
   fully-permissive autonomous one — produces anything but [Deny]. *)
let test_destructive_git_floor_independent_of_trust () =
  let s =
    simple (bin_ok "git")
      ~args:[ lit "push"; lit "--force"; lit "origin"; lit "main" ]
  in
  let caps = Capability_check.of_simple s in
  let overlays =
    [ strict_overlay
    ; internal_overlay
    ; observe_overlay
    ; suggest_overlay
    ; Approval_config.autonomous
    ]
  in
  List.iter
    (fun overlay ->
      match Approval_policy.decide default_policy ~overlay ~caps ~simple:s with
      | Verdict.Deny { reason = Destructive_git (Git_op.Destructive `Push_force); _ } ->
        ()
      | _ -> assert false)
    overlays

(* RFC-0254 §5.4: [mkfs] is catastrophic by binary identity — denied under
   any overlay, including the autonomous one. *)
let test_mkfs_denied_under_autonomous () =
  let s = simple (bin_ok "mkfs") ~args:[ lit "/dev/sdb1" ] in
  let caps = Capability_check.of_simple s in
  match Approval_policy.decide default_policy ~overlay:Approval_config.autonomous ~caps ~simple:s with
  | Verdict.Deny { reason = Catastrophic_program bin; _ } ->
    assert (Exec_program.to_string bin = "mkfs")
  | _ -> assert false

(* RFC-0254 §5.4 boundary: a path-bearing destructive program ([rm]) is NOT
   in the floor.  At the policy layer it is graded by [privileged_trust], so
   under the autonomous overlay it is [Allow].  Its target path — including a
   catastrophic [/] — is jailed by [Exec_policy.validate_shell_ir_paths]
   downstream of this decision, NOT by the approval policy.  This test pins
   that boundary so the policy is not "fixed" to re-classify argv paths (the
   duplicate-classification anti-pattern P0 was dropped to avoid). *)
let test_rm_root_allowed_at_policy_layer_jailed_downstream () =
  let s = simple (bin_ok "rm") ~args:[ lit "-rf"; lit "/" ] in
  let caps = Capability_check.of_simple s in
  match Approval_policy.decide default_policy ~overlay:Approval_config.autonomous ~caps ~simple:s with
  | Verdict.Allow t ->
    assert (Exec_program.to_string (Verdict.Trusted_argv.bin t) = "rm")
  | _ -> assert false

(* RFC-0254 §5.2: under the autonomous overlay the keeper toolchain runs.
   A non-catastrophic audited bin ([git status]) is [Allow], not [Ask]. *)
let test_autonomous_allows_toolchain () =
  let s = simple (bin_ok "git") ~args:[ lit "status" ] in
  let caps = Capability_check.of_simple s in
  match Approval_policy.decide default_policy ~overlay:Approval_config.autonomous ~caps ~simple:s with
  | Verdict.Allow t ->
    assert (Exec_program.to_string (Verdict.Trusted_argv.bin t) = "git")
  | _ -> assert false

(* Floor completeness — the [mkfs.<fstype>] family (mkfs.ext4, mkfs.xfs, ...)
   is catastrophic-by-identity exactly like bare [mkfs], so it hits the floor
   regardless of overlay. Probe finding 2026-06-18: the family bypassed the
   floor when only bare [mkfs] was a recognized program. *)
let test_mkfs_family_denied_under_autonomous () =
  let s = simple (bin_ok "mkfs.ext4") ~args:[ lit "/dev/sdb1" ] in
  let caps = Capability_check.of_simple s in
  match Approval_policy.decide default_policy ~overlay:Approval_config.autonomous ~caps ~simple:s with
  | Verdict.Deny { reason = Catastrophic_program bin; _ } ->
    assert (Exec_program.to_string bin = "mkfs.ext4")
  | _ -> assert false

(* System-power control ([shutdown]/[reboot]/[halt]/[poweroff]) is
   catastrophic-by-identity and path-independent — a keeper has no legitimate
   argument form for halting/rebooting the host, so it is denied under every
   overlay including autonomous, exactly like [mkfs]. All four are tested so a
   future sparse-match (encoding only a subset) is caught. RFC
   eliminate-substring-destructive-classifier §3-A (path-independent floor). *)
let test_system_power_denied_under_autonomous () =
  List.iter
    (fun (name, args) ->
       let s = simple (bin_ok name) ~args:(List.map lit args) in
       let caps = Capability_check.of_simple s in
       match
         Approval_policy.decide default_policy ~overlay:Approval_config.autonomous ~caps
           ~simple:s
       with
       | Verdict.Deny { reason = Catastrophic_program bin; _ } ->
         assert (Exec_program.to_string bin = name)
       | _ -> assert false)
    [ "shutdown", [ "-h"; "now" ]; "reboot", []; "halt", []; "poweroff", [] ]

(* Destructive SQL on a database CLI is the typed replacement for the
   sql_destructive substring catalogue: floored under every overlay including
   autonomous. psql executes [-c], mysql/mariadb/cockroach execute [-e]. RFC
   eliminate-substring-destructive-classifier §3-A. *)
let test_destructive_sql_denied_under_autonomous () =
  List.iter
    (fun (bin, flag, sql) ->
       let s = simple (bin_ok bin) ~args:[ lit flag; lit sql ] in
       let caps = Capability_check.of_simple s in
       match
         Approval_policy.decide default_policy ~overlay:Approval_config.autonomous ~caps
           ~simple:s
       with
       | Verdict.Deny { reason = Destructive_db _; _ } -> ()
       | _ -> Alcotest.failf "%s %s %S: expected Deny Destructive_db" bin flag sql)
    [ "psql", "-c", "drop table users"
    ; "psql", "-c", "DELETE FROM logs"
    ; "psql", "--command", "truncate table cache"
    ; "psql", "-c", "COPY logs FROM PROGRAM 'cat /etc/passwd'"
    ; "mysql", "-e", "drop database prod"
    ; "mariadb", "-e", "delete from sessions"
    ; "cockroach", "-e", "drop table users"
    ]

(* A database CLI may accept multiple SQL command flags.  The floor must scan
   every literal value so a harmless first query cannot mask a later
   destructive query. *)
let test_destructive_sql_later_flag_denied_under_autonomous () =
  List.iter
    (fun (bin, args) ->
       let s = simple (bin_ok bin) ~args:(List.map lit args) in
       let caps = Capability_check.of_simple s in
       match
         Approval_policy.decide default_policy ~overlay:Approval_config.autonomous ~caps
           ~simple:s
       with
       | Verdict.Deny { reason = Destructive_db _; _ } -> ()
       | _ -> Alcotest.failf "%s repeated SQL flags: expected Deny Destructive_db" bin)
    [ "psql", [ "-c"; "select 1"; "-c"; "drop table users" ]
    ; "psql", [ "-cselect 1"; "-cdrop table users" ]
    ; "psql", [ "--command=select 1"; "--command=truncate table cache" ]
    ; "mysql", [ "-e"; "select 1"; "-e"; "drop database prod" ]
    ; "mariadb", [ "--execute=select 1"; "--execute=delete from sessions" ]
    ]

(* A read query on a database CLI is NOT floored — database CLIs are audited, so
   under the autonomous overlay it is Allow (a keeper may query). This pins that
   the DB floor keys on the SQL verb, not the binary identity. *)
let test_read_sql_allowed_under_autonomous () =
  let s = simple (bin_ok "psql") ~args:[ lit "-c"; lit "select count(*) from users" ] in
  let caps = Capability_check.of_simple s in
  match Approval_policy.decide default_policy ~overlay:Approval_config.autonomous ~caps ~simple:s with
  | Verdict.Allow t -> assert (Exec_program.to_string (Verdict.Trusted_argv.bin t) = "psql")
  | _ -> Alcotest.fail "psql -c select should be Allow under autonomous"

let test_gh_irreversible_repo_hosting_ops_denied_under_autonomous () =
  List.iter
    (fun (label, args) ->
       let s = simple (bin_ok "gh") ~args:(List.map lit args) in
       let caps = Capability_check.of_simple s in
       match
         Approval_policy.decide default_policy ~overlay:Approval_config.autonomous ~caps
           ~simple:s
       with
       | Verdict.Deny { reason = Destructive_repo_hosting_cli bin; _ } ->
         assert (Exec_program.to_string bin = "gh")
       | _ -> Alcotest.failf "%s: expected gh irreversible op to be denied" label)
    (* W4/G-9: repo create/fork, discussion create, and graphql create* moved
       to R1 (reversible) — they are no longer Deny; they Ask via the capability
       axis (asserted in [test_gh_durable_remote_asks_under_autonomous]). Only
       the genuinely irreversible ops remain Deny here. *)
    [ "gh pr merge", [ "pr"; "merge"; "123"; "--squash" ]
    ; "gh repo delete", [ "repo"; "delete"; "owner/repo"; "--yes" ]
    ; "gh discussion delete", [ "discussion"; "delete"; "42" ]
    ; "gh api delete", [ "api"; "-X"; "DELETE"; "/repos/owner/repo" ]
    ; "gh graphql deleteDiscussion"
      , [ "api"; "graphql"; "-f"; "query=mutation{deleteDiscussion}" ]
    ]

let test_gh_pr_merge_with_dynamic_pr_number_denied_under_autonomous () =
  let s = simple (bin_ok "gh") ~args:[ lit "pr"; lit "merge"; var "PR_NUMBER" ] in
  let caps = Capability_check.of_simple s in
  match Approval_policy.decide default_policy ~overlay:Approval_config.autonomous ~caps ~simple:s with
  | Verdict.Deny { reason = Destructive_repo_hosting_cli bin; _ } ->
    assert (Exec_program.to_string bin = "gh")
  | _ -> Alcotest.fail "gh pr merge with dynamic PR number should be denied"

let test_gh_reversible_repo_hosting_ops_allowed_under_autonomous () =
  let s =
    simple (bin_ok "gh")
      ~args:[ lit "pr"; lit "create"; lit "--title"; lit "T"; lit "--body"; lit "B" ]
  in
  let caps = Capability_check.of_simple s in
  match Approval_policy.decide default_policy ~overlay:Approval_config.autonomous ~caps ~simple:s with
  | Verdict.Allow t -> assert (Exec_program.to_string (Verdict.Trusted_argv.bin t) = "gh")
  | _ -> Alcotest.fail "gh pr create should remain allowed under autonomous"

(* Issue #23390 regression: a leading value-taking global flag ([gh --repo o/r
   pr merge]) must not slip the destructive op past the floor. gh (Cobra)
   accepts flags before the subcommand and consumes their values, so the
   word-list classifier's position-based subcommand slot is wrong; the typed
   lowering locates the real subcommand. *)
let test_gh_leading_flag_destructive_floored_under_autonomous () =
  List.iter
    (fun (label, args) ->
       let s = simple (bin_ok "gh") ~args:(List.map lit args) in
       let caps = Capability_check.of_simple s in
       match
         Approval_policy.decide default_policy ~overlay:Approval_config.autonomous
           ~caps ~simple:s
       with
       | Verdict.Deny { reason = Destructive_repo_hosting_cli bin; _ } ->
         assert (Exec_program.to_string bin = "gh")
       | _ ->
         Alcotest.failf "%s: leading-flag destructive op must be floored" label)
    [ "gh --repo o/r pr merge", [ "--repo"; "o/r"; "pr"; "merge"; "123" ]
    ; "gh --repo o/r pr ready", [ "--repo"; "o/r"; "pr"; "ready"; "123" ]
    ; "gh --repo o/r repo delete"
      , [ "--repo"; "o/r"; "repo"; "delete"; "o/r"; "--yes" ]
    ]

let test_gh_leading_dynamic_flag_destructive_floored_under_autonomous () =
  List.iter
    (fun (label, args) ->
       let s = simple (bin_ok "gh") ~args in
       let caps = Capability_check.of_simple s in
       match
         Approval_policy.decide default_policy ~overlay:Approval_config.autonomous
           ~caps ~simple:s
       with
       | Verdict.Deny { reason = Destructive_repo_hosting_cli bin; _ } ->
         assert (Exec_program.to_string bin = "gh")
       | _ ->
         Alcotest.failf "%s: dynamic leading-flag destructive op must be floored" label)
    [ ( "gh --repo $REPO pr merge"
      , [ lit "--repo"; var "REPO"; lit "pr"; lit "merge"; lit "5" ] )
    ; ( "gh --repo o/r pr merge $PR_NUMBER"
      , [ lit "--repo"; lit "o/r"; lit "pr"; lit "merge"; var "PR_NUMBER" ] )
    ; ( "gh --hostname $HOST api -X DELETE"
      , [ lit "--hostname"; var "HOST"; lit "api"; lit "-X"; lit "DELETE"
        ; lit "/repos/owner/repo"
        ] )
    ]

(* Control: a leading global flag on a READ must NOT be over-blocked — the fix
   restores correct subcommand location without flooring reads. *)
let test_gh_leading_flag_read_not_floored_under_autonomous () =
  List.iter
    (fun (label, args) ->
       let s = simple (bin_ok "gh") ~args in
       let caps = Capability_check.of_simple s in
       match
         Approval_policy.decide default_policy ~overlay:Approval_config.autonomous
           ~caps ~simple:s
       with
       | Verdict.Deny { reason = Destructive_repo_hosting_cli _; _ } ->
         Alcotest.failf "%s: leading-flag read must not be floored" label
       | _ -> ())
    [ "gh --repo o/r pr view", [ lit "--repo"; lit "o/r"; lit "pr"; lit "view"; lit "123" ]
    ; "gh --repo o/r pr list", [ lit "--repo"; lit "o/r"; lit "pr"; lit "list" ]
    ; ( "gh --repo $REPO pr view $PR_NUMBER"
      , [ lit "--repo"; var "REPO"; lit "pr"; lit "view"; var "PR_NUMBER" ] )
    ]

(* RFC-0309 W3 (G-6/G-8): the capability axis escalates a durable-remote gh
   mutation to [Ask] even under the autonomous (all-Observe) overlay — the
   non-blocking HITL queue is the resolver. This is the enable path: instead of
   auto-running (old autonomous behavior) or being disabled (#23362), a
   [Requires_approval] verb asks. *)
let test_gh_durable_remote_asks_under_autonomous () =
  List.iter
    (fun (label, args) ->
       let s = simple (bin_ok "gh") ~args:(List.map lit args) in
       let caps = Capability_check.of_simple s in
       match
         Approval_policy.decide default_policy ~overlay:Approval_config.autonomous
           ~caps ~simple:s
       with
       | Verdict.Ask { bin; _ } ->
         assert (Exec_program.to_string bin = "gh")
       | _ ->
         Alcotest.failf "%s: durable-remote gh op must Ask under autonomous"
           label)
    (* W4/G-9 ENABLED: repo create/fork and discussion mutations moved R2->R1,
       so they now take the capability Ask path (durable-remote R1) instead of
       the floor Deny path — the active-keeper enablement. Plus the R1
       durable-remote ops that already existed (repo edit/sync/set-default) and
       unknown gh. *)
    [ "gh repo create", [ "repo"; "create"; "o/new" ]
    ; "gh repo fork", [ "repo"; "fork"; "o/r" ]
    ; "gh discussion create", [ "discussion"; "create"; "--title"; "T" ]
    ; "gh discussion comment", [ "discussion"; "comment"; "42"; "--body"; "B" ]
    ; "gh repo edit", [ "repo"; "edit"; "--description"; "d" ]
    ; "gh repo sync", [ "repo"; "sync" ]
    ; "gh repo set-default", [ "repo"; "set-default"; "o/r" ]
    ; "gh frobnicate (unknown family -> Requires_approval)", [ "frobnicate"; "now" ]
    (* Gap fix: an unrecognized ACTION on a known mutating family no longer
       auto-runs as a read — it Asks under autonomous. *)
    ; "gh repo upsert-magic (unknown action)", [ "repo"; "upsert-magic"; "o/r" ]
    ; "gh pr teleport (unknown action)", [ "pr"; "teleport"; "123" ]
    ]

(* RFC-0309 W4 axis-symmetry regression: the string-borne GraphQL form of a
   durable-remote create must Ask under autonomous exactly like the typed
   [gh repo create] form. W4 demoted createRepository/createDiscussion/
   addDiscussionComment from the R2 deny floor to R1 (they are reversible), so
   the floor no longer catches them; the typed verb is [Gh_verb.Api] which is
   body-blind by design (RFC-0208), so the body-blind capability disposition
   would wrongly [Allow] them. The capability axis must inspect the graphql body
   for durable-remote create fragments and escalate to Ask — otherwise the typed
   path asks while the equivalent string path auto-runs (an axis-asymmetry
   bypass). *)
let test_gh_graphql_durable_remote_asks_under_autonomous () =
  List.iter
    (fun (label, body) ->
       let s =
         simple (bin_ok "gh")
           ~args:[ lit "api"; lit "graphql"; lit "-f"; lit ("query=" ^ body) ]
       in
       let caps = Capability_check.of_simple s in
       match
         Approval_policy.decide default_policy ~overlay:Approval_config.autonomous
           ~caps ~simple:s
       with
       | Verdict.Ask { bin; _ } -> assert (Exec_program.to_string bin = "gh")
       | _ ->
         Alcotest.failf
           "%s: string-borne graphql durable-remote create must Ask under \
            autonomous"
           label)
    [ ( "createRepository"
      , "mutation { createRepository(input: {name: \"x\"}) { repository { id } } }"
      )
    ; ( "createDiscussion"
      , "mutation { createDiscussion(input: {repositoryId: \"r\", title: \"t\", \
         body: \"b\", categoryId: \"c\"}) { discussion { id } } }" )
    ; ( "addDiscussionComment"
      , "mutation { addDiscussionComment(input: {discussionId: \"d\", body: \
         \"b\"}) { comment { id } } }" )
    ]

(* Opaque GraphQL [query] bodies are not inspectable by the durable-remote
   fragment classifier. They must fail closed to the same non-blocking approval
   route, while opaque non-query variables stay non-blocking. *)
let test_gh_graphql_opaque_query_asks_under_autonomous () =
  List.iter
    (fun (label, args) ->
       let s = simple (bin_ok "gh") ~args in
       let caps = Capability_check.of_simple s in
       match
         Approval_policy.decide default_policy ~overlay:Approval_config.autonomous
           ~caps ~simple:s
       with
       | Verdict.Ask { bin; _ } -> assert (Exec_program.to_string bin = "gh")
       | _ ->
         Alcotest.failf
           "%s: opaque graphql query body must Ask under autonomous" label)
    [ ( "query=$MUTATION concat"
      , [ lit "api"; lit "graphql"; lit "-f"; concat [ lit "query="; var "MUTATION" ] ]
      )
    ; "query field variable", [ lit "api"; lit "graphql"; lit "-f"; var "FIELD" ]
    ; ( "attached --field=query=$MUTATION"
      , [ lit "api"; lit "graphql"; concat [ lit "--field=query="; var "MUTATION" ] ]
      )
    ]

let test_gh_graphql_non_query_opaque_field_allowed_under_autonomous () =
  let s =
    simple (bin_ok "gh")
      ~args:
        [ lit "api"
        ; lit "graphql"
        ; lit "-F"
        ; concat [ lit "owner="; var "OWNER" ]
        ; lit "-f"
        ; lit "query=query { viewer { login } }"
        ]
  in
  let caps = Capability_check.of_simple s in
  match Approval_policy.decide default_policy ~overlay:Approval_config.autonomous ~caps ~simple:s with
  | Verdict.Allow t ->
    assert (Exec_program.to_string (Verdict.Trusted_argv.bin t) = "gh")
  | _ -> Alcotest.fail "opaque non-query graphql variables must not Ask"

(* External-body graphql: gh reads a [-F/--field] value starting with '@'
   from a file ('@-' = stdin), and [--input FILE] reads the whole body
   externally. The mutation text is therefore not in argv, so the LITERAL body
   scanners cannot see it. These forms are literal (no Shell_ir Var/Concat), so
   the earlier $VAR opacity check does not fire; they must still Ask. *)
let test_gh_graphql_external_body_asks_under_autonomous () =
  List.iter
    (fun (label, args) ->
       let s = simple (bin_ok "gh") ~args:(List.map lit args) in
       let caps = Capability_check.of_simple s in
       match
         Approval_policy.decide default_policy ~overlay:Approval_config.autonomous
           ~caps ~simple:s
       with
       | Verdict.Ask { bin; _ } -> assert (Exec_program.to_string bin = "gh")
       | _ ->
         Alcotest.failf "%s: external graphql body must Ask under autonomous"
           label)
    [ ("-F query=@file", [ "api"; "graphql"; "-F"; "query=@mutation.graphql" ])
    ; ("-F query=@- (stdin)", [ "api"; "graphql"; "-F"; "query=@-" ])
    ; ( "--field=query=@file"
      , [ "api"; "graphql"; "--field=query=@mutation.graphql" ] )
    ; ("--input file", [ "api"; "graphql"; "--input"; "body.json" ])
    ; ("attached -Fquery=@file", [ "api"; "graphql"; "-Fquery=@mutation.graphql" ])
    ; ("--input=file attached", [ "api"; "graphql"; "--input=body.json" ])
    ]

(* [-f/--raw-field] is a static string parameter in gh; [query=@...] is not a
   file/stdin-backed external body. It can still Ask when the value is Shell IR
   opaque (Var/Concat), but a literal raw-field [@...] must not be documented or
   tested as an external body. *)
let test_gh_graphql_raw_field_at_literal_allowed () =
  List.iter
    (fun (label, args) ->
       let s = simple (bin_ok "gh") ~args:(List.map lit args) in
       let caps = Capability_check.of_simple s in
       match
         Approval_policy.decide default_policy ~overlay:Approval_config.autonomous
           ~caps ~simple:s
       with
       | Verdict.Allow _ -> ()
       | _ ->
         Alcotest.failf
           "%s: raw-field literal @ value is not an external graphql body" label)
    [ ("-f query=@-", [ "api"; "graphql"; "-f"; "query=@-" ])
    ; ( "--raw-field query=@file"
      , [ "api"; "graphql"; "--raw-field"; "query=@mutation.graphql" ] )
    ; ("attached -fquery=@file", [ "api"; "graphql"; "-fquery=@mutation.graphql" ])
    ; ( "--raw-field=query=@file"
      , [ "api"; "graphql"; "--raw-field=query=@mutation.graphql" ] )
    ]

(* Regression guard for the external-body fix: an '@'-file on a NON-query field
   (a graphql variable) combined with an inline READ query must NOT be
   over-blocked. Only the query body being external is a capability concern. *)
let test_gh_graphql_external_non_query_field_allowed () =
  let s =
    simple (bin_ok "gh")
      ~args:
        (List.map lit
           [ "api"; "graphql"; "-F"; "owner=@owner.txt"; "-f"
           ; "query=query { viewer { login } }" ])
  in
  let caps = Capability_check.of_simple s in
  match
    Approval_policy.decide default_policy ~overlay:Approval_config.autonomous
      ~caps ~simple:s
  with
  | Verdict.Allow _ -> ()
  | _ ->
    Alcotest.fail
      "external @-file on a non-query field with an inline read query must not \
       Ask"

(* RFC-0309 W3 pipeline coverage: a gh durable-remote op in a NON-final pipeline
   stage must still Ask. [gh repo create ... | cat] shifts the representative
   (last) simple to [cat]; the capability axis folds over ALL caps so the create
   is still seen. Without the fold this auto-runs (R1, no longer floored after
   W4 moved repo/discussion create R2->R1). The caller hands [decide] the last
   stage as [~simple], mirroring [last_simple_of_ir]. *)
let test_gh_durable_remote_in_pipeline_asks_under_autonomous () =
  let cat_stage = simple (bin_ok "cat") in
  List.iter
    (fun (label, gh_args) ->
       let gh_stage = simple (bin_ok "gh") ~args:(List.map lit gh_args) in
       let ir =
         Shell_ir.Pipeline
           [ Shell_ir.Simple gh_stage; Shell_ir.Simple cat_stage ]
       in
       let caps = Capability_check.of_ir ir in
       match
         Approval_policy.decide default_policy ~overlay:Approval_config.autonomous
           ~caps ~simple:cat_stage
       with
       | Verdict.Ask { bin; _ } -> assert (Exec_program.to_string bin = "gh")
       | _ ->
         Alcotest.failf "%s | cat must still Ask under autonomous" label)
    [ ("gh repo create", [ "repo"; "create"; "o/new" ])
    ; ("gh discussion create", [ "discussion"; "create"; "--title"; "T" ])
    ; ( "gh api graphql -F query=@file (composed with pipeline)"
      , [ "api"; "graphql"; "-F"; "query=@mutation.graphql" ] )
    ]

(* Regression guard: the W3 capability layer is ADDITIVE. Reads and local /
   in-repo reversible mutations stay [Allow] under autonomous — no over-block of
   routine keeper work. *)
let test_gh_reads_and_local_still_allowed_under_autonomous () =
  List.iter
    (fun (label, args) ->
       let s = simple (bin_ok "gh") ~args:(List.map lit args) in
       let caps = Capability_check.of_simple s in
       match
         Approval_policy.decide default_policy ~overlay:Approval_config.autonomous
           ~caps ~simple:s
       with
       | Verdict.Allow _ -> ()
       | _ -> Alcotest.failf "%s: should stay Allow under autonomous" label)
    [ "gh pr view", [ "pr"; "view"; "1" ]
    ; "gh pr create", [ "pr"; "create"; "--title"; "T" ]
    ; "gh issue comment", [ "issue"; "comment"; "5"; "--body"; "B" ]
    ; "gh repo clone (local)", [ "repo"; "clone"; "o/r" ]
    ; "gh repo view", [ "repo"; "view"; "o/r" ]
    ]

(* Non-gh commands are untouched by the capability layer. *)
let test_non_gh_unaffected_by_capability_layer () =
  let s = simple (bin_ok "ls") ~args:[ lit "-la" ] in
  let caps = Capability_check.of_simple s in
  match Approval_policy.decide default_policy ~overlay:Approval_config.autonomous ~caps ~simple:s with
  | Verdict.Allow _ -> ()
  | _ -> Alcotest.fail "ls should stay Allow under autonomous"

(* Floor completeness — [git clean] with a bundled force flag ([-fd], the
   common force-delete-untracked form) is destructive and hits the floor.
   Probe finding 2026-06-18: [git clean -fd] was graded as plain audited git
   because the classifier matched only the standalone [-f] token. *)
let test_git_clean_bundled_force_denied () =
  let s = simple (bin_ok "git") ~args:[ lit "clean"; lit "-fd" ] in
  let caps = Capability_check.of_simple s in
  match Approval_policy.decide default_policy ~overlay:Approval_config.autonomous ~caps ~simple:s with
  | Verdict.Deny { reason = Destructive_git (Git_op.Destructive `Clean_force); _ } -> ()
  | _ -> assert false

(* RFC-0255 §4.5 review response: [reset --hard] is only partly
   reflog-recoverable.  Uncommitted tracked changes are not recoverable, so it
   stays in the trust-independent floor until a structured recovery path can
   prove a clean/snapshotted worktree. *)
let test_reset_hard_floored_under_autonomous () =
  let s = simple (bin_ok "git") ~args:[ lit "reset"; lit "--hard"; lit "HEAD~1" ] in
  let caps = Capability_check.of_simple s in
  match Approval_policy.decide default_policy ~overlay:Approval_config.autonomous ~caps ~simple:s with
  | Verdict.Deny { reason = Destructive_git (Git_op.Destructive `Reset_hard); _ } -> ()
  | _ -> assert false

(* RFC-0255 §4.5 review response: [branch -D] can only be safely automated
   after proving the branch is merged/reachable, unused by another worktree, or
   snapshotted.  The raw command stays floored. *)
let test_branch_delete_floored_under_autonomous () =
  let s = simple (bin_ok "git") ~args:[ lit "branch"; lit "-D"; lit "feature-x" ] in
  let caps = Capability_check.of_simple s in
  match Approval_policy.decide default_policy ~overlay:Approval_config.autonomous ~caps ~simple:s with
  | Verdict.Deny { reason = Destructive_git (Git_op.Destructive `Branch_delete); _ } -> ()
  | _ -> assert false

(* RFC-0255 P1 review response: [git push --delete] and [git push -d] delete
   remote refs and are irreversible at the syntax classifier, so they must be
   in the trust-independent destructive floor. *)
let test_push_delete_floored_under_autonomous () =
  let s =
    simple (bin_ok "git")
      ~args:[ lit "push"; lit "--delete"; lit "origin"; lit "feature-x" ]
  in
  let caps = Capability_check.of_simple s in
  match Approval_policy.decide default_policy ~overlay:Approval_config.autonomous ~caps ~simple:s with
  | Verdict.Deny { reason = Destructive_git (Git_op.Destructive `Push_delete); _ } -> ()
  | _ -> assert false

let test_push_delete_short_flag_floored_under_autonomous () =
  let s =
    simple (bin_ok "git") ~args:[ lit "push"; lit "-d"; lit "origin"; lit "feature-x" ] in
  let caps = Capability_check.of_simple s in
  match Approval_policy.decide default_policy ~overlay:Approval_config.autonomous ~caps ~simple:s with
  | Verdict.Deny { reason = Destructive_git (Git_op.Destructive `Push_delete); _ } -> ()
  | _ -> assert false

let test_push_force_with_lease_floored_under_autonomous () =
  let s =
    simple (bin_ok "git")
      ~args:[ lit "push"; lit "--force-with-lease=main"; lit "origin"; lit "main" ]
  in
  let caps = Capability_check.of_simple s in
  match Approval_policy.decide default_policy ~overlay:Approval_config.autonomous ~caps ~simple:s with
  | Verdict.Deny { reason = Destructive_git (Git_op.Destructive `Push_force); _ } -> ()
  | _ -> assert false

let test_push_mirror_floored_under_autonomous () =
  let s = simple (bin_ok "git") ~args:[ lit "push"; lit "--mirror"; lit "origin" ] in
  let caps = Capability_check.of_simple s in
  match Approval_policy.decide default_policy ~overlay:Approval_config.autonomous ~caps ~simple:s with
  | Verdict.Deny { reason = Destructive_git (Git_op.Destructive `Push_mirror); _ } -> ()
  | _ -> assert false

let test_push_prune_floored_under_autonomous () =
  let s =
    simple (bin_ok "git")
      ~args:[ lit "push"; lit "--prune"; lit "origin"; lit "main" ]
  in
  let caps = Capability_check.of_simple s in
  match
    Approval_policy.decide default_policy ~overlay:Approval_config.autonomous
      ~caps ~simple:s
  with
  | Verdict.Deny { reason = Destructive_git (Git_op.Destructive `Push_delete); _ }
    -> ()
  | _ -> assert false

(* Refspec-borne destructive push must hit the trust-independent floor under the
   autonomous overlay, exactly like the flag forms. [:dst] deletes the remote
   ref; [+ref] force-overwrites it. Without refspec parsing these auto-ran. *)
let test_push_delete_refspec_floored_under_autonomous () =
  let s =
    simple (bin_ok "git")
      ~args:[ lit "push"; lit "origin"; lit ":refs/heads/main" ]
  in
  let caps = Capability_check.of_simple s in
  match
    Approval_policy.decide default_policy ~overlay:Approval_config.autonomous
      ~caps ~simple:s
  with
  | Verdict.Deny { reason = Destructive_git (Git_op.Destructive `Push_delete); _ }
    -> ()
  | _ -> assert false

let test_push_force_refspec_floored_under_autonomous () =
  let s =
    simple (bin_ok "git")
      ~args:[ lit "push"; lit "origin"; lit "+refs/heads/main" ]
  in
  let caps = Capability_check.of_simple s in
  match
    Approval_policy.decide default_policy ~overlay:Approval_config.autonomous
      ~caps ~simple:s
  with
  | Verdict.Deny { reason = Destructive_git (Git_op.Destructive `Push_force); _ }
    -> ()
  | _ -> assert false

(* RFC-0255 §4.5: [worktree remove] is NOT recoverable (discards uncommitted
   worktree state and races concurrent keepers/the conveyor) — it STAYS in the
   floor and is [Deny] under every overlay including autonomous. *)
let test_worktree_remove_floored_under_autonomous () =
  let s = simple (bin_ok "git") ~args:[ lit "worktree"; lit "remove"; lit "wt" ] in
  let caps = Capability_check.of_simple s in
  match Approval_policy.decide default_policy ~overlay:Approval_config.autonomous ~caps ~simple:s with
  | Verdict.Deny { reason = Destructive_git (Git_op.Destructive `Worktree_remove); _ } -> ()
  | _ -> assert false

let () =
  test_safe_bin_strict_asks ();
  test_safe_bin_allowed_with_overlay ();
  test_privileged_bin_asks ();
  test_audited_bin_asks ();
  test_audited_bin_allowed_with_overlay ();
  test_audited_bin_with_cwd_flag_allowed_with_overlay ();
  test_destructive_git_denies ();
  test_destructive_git_denied_under_permissive_overlay ();
  test_write_outside_denies ();
  (* P9 trust_level dispatch *)
  test_observe_safe_bin_allows ();
  test_observe_audited_bin_allows ();
  test_observe_privileged_bin_asks ();
  test_suggest_safe_bin_suggests ();
  test_suggest_audited_bin_suggests ();
  test_suggest_privileged_bin_asks ();
  test_destructive_git_denied_under_suggest_overlay ();
  (* RFC-0254 catastrophic floor *)
  test_destructive_git_floor_independent_of_trust ();
  test_mkfs_denied_under_autonomous ();
  test_mkfs_family_denied_under_autonomous ();
  test_system_power_denied_under_autonomous ();
  test_destructive_sql_denied_under_autonomous ();
  test_destructive_sql_later_flag_denied_under_autonomous ();
  test_read_sql_allowed_under_autonomous ();
  test_gh_irreversible_repo_hosting_ops_denied_under_autonomous ();
  test_gh_pr_merge_with_dynamic_pr_number_denied_under_autonomous ();
  test_gh_reversible_repo_hosting_ops_allowed_under_autonomous ();
  test_gh_leading_flag_destructive_floored_under_autonomous ();
  test_gh_leading_dynamic_flag_destructive_floored_under_autonomous ();
  test_gh_leading_flag_read_not_floored_under_autonomous ();
  test_gh_durable_remote_asks_under_autonomous ();
  test_gh_graphql_durable_remote_asks_under_autonomous ();
  test_gh_graphql_opaque_query_asks_under_autonomous ();
  test_gh_graphql_non_query_opaque_field_allowed_under_autonomous ();
  test_gh_graphql_external_body_asks_under_autonomous ();
  test_gh_graphql_raw_field_at_literal_allowed ();
  test_gh_graphql_external_non_query_field_allowed ();
  test_gh_durable_remote_in_pipeline_asks_under_autonomous ();
  test_gh_reads_and_local_still_allowed_under_autonomous ();
  test_non_gh_unaffected_by_capability_layer ();
  test_git_clean_bundled_force_denied ();
  (* RFC-0255 §4.5 review response: no raw destructive-git demotion. *)
  test_reset_hard_floored_under_autonomous ();
  test_branch_delete_floored_under_autonomous ();
  test_push_delete_floored_under_autonomous ();
  test_push_delete_short_flag_floored_under_autonomous ();
  test_push_force_with_lease_floored_under_autonomous ();
  test_push_mirror_floored_under_autonomous ();
  test_push_prune_floored_under_autonomous ();
  test_push_delete_refspec_floored_under_autonomous ();
  test_push_force_refspec_floored_under_autonomous ();
  test_worktree_remove_floored_under_autonomous ();
  test_rm_root_allowed_at_policy_layer_jailed_downstream ();
  test_autonomous_allows_toolchain ();
  print_endline "[test_approval_policy] all tests passed"
