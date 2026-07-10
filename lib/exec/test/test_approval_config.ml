(** Approval_config type + lookup smoke tests. *)

open Masc_exec

let test_enforced_all_is_fail_closed () =
  let o = Approval_config.enforced_all in
  assert (o.safe_trust = Enforced);
  assert (o.audited_trust = Enforced);
  assert (o.privileged_trust = Enforced)

let test_permissive_default_auto_safe () =
  let o = Approval_config.permissive_default in
  assert (o.safe_trust = Auto_safe);
  assert (o.audited_trust = Enforced);
  assert (o.privileged_trust = Enforced)

let test_empty_uses_enforced_defaults () =
  let cfg = Approval_config.empty in
  assert (cfg.per_agent = []);
  let o = Approval_config.lookup cfg ~actor:`Other_agent in
  assert (o = Approval_config.enforced_all)

let test_lookup_matches_registered_agent () =
  let cfg : Approval_config.t =
    {
      defaults = Approval_config.enforced_all;
      per_agent = [
        (`Workspace_git, Approval_config.permissive_default);
      ];
    }
  in
  let alpha = Approval_config.lookup cfg ~actor:`Workspace_git in
  assert (alpha = Approval_config.permissive_default);
  let other = Approval_config.lookup cfg ~actor:`Other_agent in
  assert (other = Approval_config.enforced_all)

let test_shell_ir_approval_overlay_parses_profile () =
  let o = Option.get (Approval_config.shell_ir_approval_overlay_of_string "permissive") in
  assert (o.safe_trust = Auto_safe);
  assert (o.audited_trust = Enforced);
  assert (o.privileged_trust = Enforced)

let test_shell_ir_approval_overlay_parses_profile_with_overrides () =
  let raw = "profile=permissive, safe=observe,audited=auto_safe,privileged=auto_safe" in
  match Approval_config.shell_ir_approval_overlay_of_string raw with
  | None -> assert false
  | Some o ->
    assert (o.safe_trust = Observe);
    assert (o.audited_trust = Auto_safe);
    assert (o.privileged_trust = Auto_safe)

let test_shell_ir_approval_overlay_rejects_unknown_profile () =
  assert (Approval_config.shell_ir_approval_overlay_of_string "nonsense" = None)

let test_shell_ir_approval_overlay_rejects_invalid_key_value () =
  assert (Approval_config.shell_ir_approval_overlay_of_string "permissive,foo=bar" = None)

let () =
  test_enforced_all_is_fail_closed ();
  test_permissive_default_auto_safe ();
  test_empty_uses_enforced_defaults ();
  test_lookup_matches_registered_agent ();
  test_shell_ir_approval_overlay_parses_profile ();
  test_shell_ir_approval_overlay_parses_profile_with_overrides ();
  test_shell_ir_approval_overlay_rejects_unknown_profile ();
  test_shell_ir_approval_overlay_rejects_invalid_key_value ();
  print_endline "[test_approval_config] all tests passed"
