(** Approval_config type + lookup smoke tests. *)

open Masc_exec

let test_strict_is_fail_closed () =
  let o = Approval_config.strict_default in
  assert (o.allow_safe_in_worktree = false);
  assert (o.ask_audited = true);
  assert (o.deny_destructive_git = true)

let test_permissive_default_allows_safe () =
  let o = Approval_config.permissive_default in
  assert (o.allow_safe_in_worktree = true);
  assert (o.deny_destructive_git = true)

let test_empty_uses_strict_defaults () =
  let cfg = Approval_config.empty in
  assert (cfg.per_agent = []);
  let o = Approval_config.lookup cfg ~actor:"anybody" in
  assert (o = Approval_config.strict_default)

let test_lookup_matches_registered_agent () =
  let cfg : Approval_config.t =
    {
      defaults = Approval_config.strict_default;
      per_agent = [
        ("keeper/alpha", Approval_config.permissive_default);
      ];
    }
  in
  let alpha = Approval_config.lookup cfg ~actor:"keeper/alpha" in
  assert (alpha = Approval_config.permissive_default);
  let other = Approval_config.lookup cfg ~actor:"keeper/beta" in
  assert (other = Approval_config.strict_default)

let () =
  test_strict_is_fail_closed ();
  test_permissive_default_allows_safe ();
  test_empty_uses_strict_defaults ();
  test_lookup_matches_registered_agent ();
  print_endline "[test_approval_config] all tests passed"
