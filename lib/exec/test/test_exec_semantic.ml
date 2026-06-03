(** Exec_semantic — post-exec classification tests.

    Exhaustive table-driven coverage of [interpret] heuristics and
    stability of [to_json] shape. *)

open Masc_exec

let ws code = Unix.WEXITED code
let wsig n = Unix.WSIGNALED n

let test_ok () =
  assert (
    Exec_semantic.interpret
      ~argv:[ "ls" ]
      ~status:(ws 0)
      ~stdout:""
      ~stderr:""
    = `Ok)

let test_fail_generic () =
  assert (
    Exec_semantic.interpret
      ~argv:[ "ls" ]
      ~status:(ws 2)
      ~stdout:""
      ~stderr:"ls: cannot access …"
    = `Fail 2)

let test_tool_missing () =
  match
    Exec_semantic.interpret
      ~argv:[ "notarealtool"; "--help" ]
      ~status:(ws 127)
      ~stdout:""
      ~stderr:"bash: notarealtool: command not found"
  with
  | `Tool_missing "notarealtool" -> ()
  | _ -> assert false

let test_permission_denied () =
  match
    Exec_semantic.interpret
      ~argv:[ "/tmp/not-executable" ]
      ~status:(ws 126)
      ~stdout:""
      ~stderr:"permission denied"
  with
  | `Permission_denied "/tmp/not-executable" -> ()
  | _ -> assert false

let test_git_not_a_repo () =
  assert (
    Exec_semantic.interpret
      ~argv:[ "git"; "status" ]
      ~status:(ws 128)
      ~stdout:""
      ~stderr:"fatal: not a git repository"
    = `Git_not_a_repo)

let test_git_not_a_repo_via_path () =
  assert (
    Exec_semantic.interpret
      ~argv:[ "/opt/homebrew/bin/git"; "log" ]
      ~status:(ws 128)
      ~stdout:""
      ~stderr:""
    = `Git_not_a_repo)

(* git exit 128 inside a valid repo with a bad ref must NOT be
   classified as not-a-repo: the self-correction is opposite. *)
let test_git_unknown_revision () =
  assert (
    Exec_semantic.interpret
      ~argv:[ "git"; "log"; "origin/task-575" ]
      ~status:(ws 128)
      ~stdout:""
      ~stderr:
        "fatal: ambiguous argument 'origin/task-575': unknown revision or \
         path not in the working tree."
    = `Git_unknown_revision)

let test_git_unknown_revision_unknown_revision_only () =
  assert (
    Exec_semantic.interpret
      ~argv:[ "git"; "rev-parse"; "deadbeef" ]
      ~status:(ws 128)
      ~stdout:""
      ~stderr:"fatal: bad revision 'deadbeef'\nfatal: unknown revision"
    = `Git_unknown_revision)

(* The merged-output path (interpret_cmd) must reach the same split,
   since git fatals are written to stderr and merged into [output]. *)
let test_git_unknown_revision_via_cmd () =
  assert (
    Exec_semantic.interpret_cmd
      ~cmd:"git log origin/task-575"
      ~status:(ws 128)
      ~output:"fatal: ambiguous argument 'origin/task-575': unknown revision"
    = `Git_unknown_revision)

let test_git_unknown_revision_hint_and_alternatives () =
  (match Exec_semantic.to_hint `Git_unknown_revision with
   | Some h ->
       assert (String_util.contains_substring h "valid repository");
       (* must NOT recycle the not-a-repo wording *)
       assert (not (String_util.contains_substring h "not inside a git"))
   | None -> assert false);
  (match Exec_semantic.to_alternatives `Git_unknown_revision with
   | alts ->
       assert (List.length alts > 0);
       (* must NOT advise cloning — the repo already exists *)
       assert (
         not
           (List.exists
              (fun a -> String_util.contains_substring a "git clone")
              alts)))

let test_git_unknown_revision_kind_and_payload () =
  assert (Exec_semantic.to_kind `Git_unknown_revision = "git_unknown_revision");
  assert (Exec_semantic.to_payload `Git_unknown_revision = [])

let test_non_git_128_is_fail () =
  assert (
    Exec_semantic.interpret
      ~argv:[ "curl"; "example.com" ]
      ~status:(ws 128)
      ~stdout:""
      ~stderr:""
    = `Fail 128)

let test_oom_killed () =
  assert (
    Exec_semantic.interpret
      ~argv:[ "big-mem-hog" ]
      ~status:(wsig Sys.sigkill)
      ~stdout:""
      ~stderr:"kernel: Out of memory: killed process 4242"
    = `Oom_killed)

let test_signaled_plain () =
  match
    Exec_semantic.interpret
      ~argv:[ "sleep"; "999" ]
      ~status:(wsig Sys.sigterm)
      ~stdout:""
      ~stderr:""
  with
  | `Signaled n -> assert (n = Sys.sigterm)
  | _ -> assert false

let test_kind_stable_strings () =
  assert (Exec_semantic.to_kind `Ok = "ok");
  assert (Exec_semantic.to_kind (`Fail 2) = "fail");
  assert (Exec_semantic.to_kind `Git_not_a_repo = "git_not_a_repo");
  assert (Exec_semantic.to_kind `Oom_killed = "oom_killed");
  assert (Exec_semantic.to_kind (`Tool_missing "foo") = "tool_missing")

let test_payload_nullary_empty () =
  assert (Exec_semantic.to_payload `Ok = []);
  assert (Exec_semantic.to_payload `Git_not_a_repo = []);
  assert (Exec_semantic.to_payload `Oom_killed = [])

let test_payload_fail_has_exit_code () =
  match Exec_semantic.to_payload (`Fail 42) with
  | [ ("exit_code", `Int 42) ] -> ()
  | _ -> assert false

let test_payload_tool_missing_has_tool () =
  match Exec_semantic.to_payload (`Tool_missing "foo") with
  | [ ("tool", `String "foo") ] -> ()
  | _ -> assert false

(* Post-#8721: MASC_BASH_SEMANTIC_EXIT defaults to on.  The flag
   now serves as an explicit opt-out ("0" / "false" / …) rather
   than opt-in, and the unset case resolves to [true]. *)
let test_enabled_flag_default_on () =
  Unix.putenv "MASC_BASH_SEMANTIC_EXIT" "";
  assert (Exec_semantic.enabled ())

let test_enabled_flag_explicit_off () =
  Unix.putenv "MASC_BASH_SEMANTIC_EXIT" "0";
  assert (not (Exec_semantic.enabled ()));
  Unix.putenv "MASC_BASH_SEMANTIC_EXIT" "false";
  assert (not (Exec_semantic.enabled ()));
  Unix.putenv "MASC_BASH_SEMANTIC_EXIT" ""

let test_enabled_flag_explicit_on () =
  Unix.putenv "MASC_BASH_SEMANTIC_EXIT" "1";
  assert (Exec_semantic.enabled ());
  Unix.putenv "MASC_BASH_SEMANTIC_EXIT" ""

let () =
  test_ok ();
  test_fail_generic ();
  test_tool_missing ();
  test_permission_denied ();
  test_git_not_a_repo ();
  test_git_not_a_repo_via_path ();
  test_git_unknown_revision ();
  test_git_unknown_revision_unknown_revision_only ();
  test_git_unknown_revision_via_cmd ();
  test_git_unknown_revision_hint_and_alternatives ();
  test_git_unknown_revision_kind_and_payload ();
  test_non_git_128_is_fail ();
  test_oom_killed ();
  test_signaled_plain ();
  test_kind_stable_strings ();
  test_payload_nullary_empty ();
  test_payload_fail_has_exit_code ();
  test_payload_tool_missing_has_tool ();
  test_enabled_flag_default_on ();
  test_enabled_flag_explicit_off ();
  test_enabled_flag_explicit_on ();
  print_endline "test_exec_semantic: ok"
