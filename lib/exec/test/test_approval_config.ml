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

let test_parse_trust_level () =
  assert (Approval_config.trust_level_of_string "OBSERVE" = Some Observe);
  assert (Approval_config.trust_level_of_string "  suggest " = Some Suggest);
  assert (Approval_config.trust_level_of_string "auto-safe" = Some Auto_safe);
  assert (Approval_config.trust_level_of_string "deny" = Some Enforced);
  assert (Approval_config.trust_level_of_string "garbage" = None)

let test_parse_profile () =
  (match Approval_config.agent_overlay_of_profile " AUTONOMOUS " with
   | Some overlay ->
     assert (overlay.safe_trust = Observe);
     assert (overlay.audited_trust = Observe);
     assert (overlay.privileged_trust = Observe)
   | None -> assert false);
  (match Approval_config.agent_overlay_of_profile "permissive" with
   | Some overlay ->
     assert (overlay.safe_trust = Auto_safe);
     assert (overlay.audited_trust = Enforced);
     assert (overlay.privileged_trust = Enforced)
   | None -> assert false);
  assert (Approval_config.agent_overlay_of_profile "bad-profile" = None)

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

let () =
  test_enforced_all_is_fail_closed ();
  test_permissive_default_auto_safe ();
  test_empty_uses_enforced_defaults ();
  test_lookup_matches_registered_agent ();
  test_parse_trust_level ();
  test_parse_profile ();
  print_endline "[test_approval_config] all tests passed"
