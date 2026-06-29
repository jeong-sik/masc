(** Path-policy unit tests for [Keeper_tool_policy.is_masc_write_allowed].

    The internal [normalize_path] is exercised indirectly through
    the public [is_masc_write_allowed].  Audit P3 (2026-04-29 §1.1)
    flagged the unit-test gap on traversal cases.

    Note: [test/test_decision_pipeline.ml] (the
    [test_keeper_writable_prefix_paths] block) already covers
    6 baseline cases (3 allowed prefixes + 3 disallowed,
    including one [..] escape `.masc/playground/../reputation/evil.json`).
    This suite is a {b dedicated, exhaustive} pin for the lexical
    normaliser — 20 cases including prefix-name boundaries
    ([.masc/decision_audit_sneaky/], plural [playgrounds],
    [.worktrees-stale/]), root-overshoot semantics tested via
    a writable-prefix path so the rejection signal is unambiguous
    ([.masc/playground/../../../.masc/playground/x] →
    still allowed because the lexical collapse drops [..] beyond
    root, leaving a writable prefix), and the non-escape
    "round-trip into writable" case
    ([playground/../playground/x] → still allowed).  Cases
    overlap with [test_decision_pipeline] are intentional
    redundancy at a different abstraction level (pure isolated
    test vs the integrated decision pipeline).

    Properties pinned:

    1. {b Allowed prefixes} — keeper-writable paths under
       [.masc/playground/], [.masc/decision_audit/], and
       [.worktrees/] return [true].
    2. {b Disallowed paths} — paths outside the writable prefix
       set return [false] (e.g. [.masc/reputation/],
       [.masc/economy/], [/etc/passwd]).
    3. {b Lexical [..] traversal collapse} — paths that resolve
       to outside the writable set after [.] / [..] collapse
       are correctly rejected, even if the literal prefix
       matched.  Example: [.masc/playground/../reputation/data]
       must collapse to [.masc/reputation/data] and be rejected.
    4. {b Same-prefix-name boundary} — paths that share a
       byte-prefix with a writable directory but are siblings
       (not children) are rejected.  Example:
       [.masc/decision_audit_sneaky/x] must not match the
       [.masc/decision_audit/] prefix.

    The audit doc (§1.1) explicitly noted symlink resolution is
    out of scope for this lexical normaliser ("Does not resolve
    symlinks — pure lexical normalisation"), so we do not test
    symlink behavior here. *)

module P = Masc.Keeper_tool_policy

let with_temp_dir prefix f =
  let dir = Filename.temp_file prefix "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  let rec rm_rf path =
    if Sys.file_exists path then
      if Sys.is_directory path then begin
        Sys.readdir path
        |> Array.iter (fun name -> rm_rf (Filename.concat path name));
        Unix.rmdir path
      end else
        Sys.remove path
  in
  Fun.protect ~finally:(fun () -> rm_rf dir) (fun () -> f dir)

(* ── (1) writable prefixes ───────────────────────────────────────── *)

let test_playground_root_allowed () =
  assert (P.is_masc_write_allowed ".masc/playground/keeper-1/file.txt")

let test_playground_deep_allowed () =
  assert (
    P.is_masc_write_allowed
      ".masc/playground/keeper-2/repos/proj/src/main.ml")

let test_decision_audit_allowed () =
  assert (
    P.is_masc_write_allowed
      ".masc/decision_audit/2026-05-04/keeper-3.json")

let test_worktrees_allowed () =
  assert (P.is_masc_write_allowed ".worktrees/feature-x/lib/foo.ml")

(* ── (2) disallowed paths ────────────────────────────────────────── *)

let test_reputation_rejected () =
  assert (not (P.is_masc_write_allowed ".masc/reputation/keeper-1.json"))

let test_economy_rejected () =
  assert (not (P.is_masc_write_allowed ".masc/economy/ledger.toml"))

let test_etc_passwd_rejected () =
  assert (not (P.is_masc_write_allowed "/etc/passwd"))

let test_root_rejected () =
  assert (not (P.is_masc_write_allowed "/"))

let test_empty_rejected () =
  assert (not (P.is_masc_write_allowed ""))

let test_relative_rejected () =
  (* a bare relative path that doesn't begin with one of the
     writable prefixes *)
  assert (not (P.is_masc_write_allowed "src/keeper.ml"))

(* ── (3) lexical [..] collapse must reject escapes ───────────────── *)

let test_traversal_to_reputation_rejected () =
  (* [.masc/playground/../reputation/] collapses to
     [.masc/reputation/] which is NOT in the writable set, so
     write must be rejected. *)
  assert (
    not
      (P.is_masc_write_allowed
         ".masc/playground/../reputation/data.json"))

let test_traversal_to_economy_rejected () =
  assert (
    not
      (P.is_masc_write_allowed
         ".masc/playground/keeper-1/../../economy/ledger.toml"))

let test_traversal_to_etc_rejected () =
  (* [.worktrees/x/../../../etc/passwd] should collapse to
     something well outside the writable set. *)
  assert (
    not
      (P.is_masc_write_allowed
         ".worktrees/x/../../../etc/passwd"))

let test_dotdot_at_root_drops () =
  (* Audit §1.1 noted "already at root — drop" semantics.  Pin
     that a [..] beyond the root is dropped (not raised) and the
     resulting path is still consistent. *)
  assert (
    not (P.is_masc_write_allowed "../../etc/passwd"))

let test_root_overshoot_drops_to_writable_prefix () =
  (* Review caught that test_dotdot_at_root_drops above
     can't distinguish "[..] beyond root drops" from "[/etc/]
     just isn't writable" — both produce false.

     This test isolates the "drop" semantics: pass a path with
     more leading [..]s than there are segments, but ending in
     a writable prefix.  The lexical normaliser should drop the
     excess [..]s (not raise, not preserve them as literal
     segments) so the final path collapses to a writable
     subdir.  Path:

       .masc/playground/../../../.masc/playground/x

     collapse:
       [.masc] [playground] [..] [..] [..] [.masc] [playground] [x]
                          ↓
       [.masc] [playground]   →   pop, [.masc]
                              →   pop, []
                              →   drop, []
                              →   push, [.masc]
                              →   push, [.masc, playground]
                              →   push, [.masc, playground, x]
       Final: ".masc/playground/x"  → WRITABLE.

     If the normaliser raised or preserved literal [..]s, the
     final path would not match the writable prefix and this
     would return false. *)
  assert (
    P.is_masc_write_allowed
      ".masc/playground/../../../.masc/playground/x")

let test_self_ref_dot_collapse_allowed () =
  (* [.] segments must be silently dropped without changing
     write-allowed semantics. *)
  assert (
    P.is_masc_write_allowed ".masc/playground/./keeper-1/./file.txt")

let test_traversal_back_into_writable_allowed () =
  (* [.masc/playground/../playground/x] collapses to
     [.masc/playground/x] which IS still writable.  The lexical
     normaliser should accept this — it's not an escape. *)
  assert (
    P.is_masc_write_allowed
      ".masc/playground/../playground/keeper-1/file.txt")

(* ── (4) prefix-name boundary cases ──────────────────────────────── *)

let test_decision_audit_sneaky_rejected () =
  (* Audit §1.2 flagged this exact pattern as a potential
     prefix-confusion: [.masc/decision_audit_sneaky/x] shares the
     bytes [.masc/decision_audit] with the writable prefix but is
     a sibling directory, NOT a child.  The current code uses
     [String.starts_with path ~prefix] where prefix ends in '/',
     so [.masc/decision_audit_sneaky/x] does NOT start with
     [.masc/decision_audit/] (different byte at position 21:
     '_' vs '/').  Pin this. *)
  assert (
    not
      (P.is_masc_write_allowed ".masc/decision_audit_sneaky/x"))

let test_playground_sibling_rejected () =
  (* Same boundary class as decision_audit_sneaky, applied to
     playground.  [.masc/playgrounds/x] (note plural) must not
     match the [.masc/playground/] singular prefix. *)
  assert (not (P.is_masc_write_allowed ".masc/playgrounds/x"))

let test_worktrees_sibling_rejected () =
  assert (not (P.is_masc_write_allowed ".worktrees-stale/x"))

let test_exec_policy_validate_path_survives_deleted_cwd () =
  with_temp_dir "exec-policy-deleted-cwd-" @@ fun root ->
  let doomed = Filename.concat root "doomed" in
  Unix.mkdir doomed 0o755;
  let saved_cwd = Sys.getcwd () in
  Fun.protect
    ~finally:(fun () -> Sys.chdir saved_cwd)
    (fun () ->
       Sys.chdir doomed;
       Unix.rmdir doomed;
       ignore (Exec_policy.Paths.validate_path "/not-under-tmp-or-workspace"))

(* ── runner ──────────────────────────────────────────────────────── *)

let () =
  test_playground_root_allowed ();
  test_playground_deep_allowed ();
  test_decision_audit_allowed ();
  test_worktrees_allowed ();
  test_reputation_rejected ();
  test_economy_rejected ();
  test_etc_passwd_rejected ();
  test_root_rejected ();
  test_empty_rejected ();
  test_relative_rejected ();
  test_traversal_to_reputation_rejected ();
  test_traversal_to_economy_rejected ();
  test_traversal_to_etc_rejected ();
  test_dotdot_at_root_drops ();
  test_root_overshoot_drops_to_writable_prefix ();
  test_self_ref_dot_collapse_allowed ();
  test_traversal_back_into_writable_allowed ();
  test_decision_audit_sneaky_rejected ();
  test_playground_sibling_rejected ();
  test_worktrees_sibling_rejected ();
  test_exec_policy_validate_path_survives_deleted_cwd ();
  print_endline "test_keeper_tool_policy_paths: all assertions passed"
