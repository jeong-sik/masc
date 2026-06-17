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
  test_rm_root_allowed_at_policy_layer_jailed_downstream ();
  test_autonomous_allows_toolchain ();
  print_endline "[test_approval_policy] all tests passed"
