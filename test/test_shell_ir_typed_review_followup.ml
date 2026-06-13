(** test_shell_ir_typed_review_followup — invariants enforced by the
    review on PR #14240.

    Each test below pins one of the three contracts that the review
    surfaced:

    - P1: [Shell_ir_typed.of_simple] forces the [Generic] fallback when
      the source [Shell_ir.simple] carries non-empty [env] or
      [redirects], so [Capability_check_typed.of_command] routes the
      capability derivation back to [Capability_check.of_simple] and
      preserves [Env_set] / [Read_path] / [Write_path] capabilities.

    - P2 (None → Generic): [of_simple] never returns [None]. Any input
      that does not match a specific constructor — non-literal args,
      unhandled binary kind, bin-kind-with-no-parser — falls through to
      [W (Generic _)] so callers cannot mishandle a silent
      "no typed command" outcome.

    - P2 (sudo argv tokenization): [Sudo.target_argv] survives a
      [to_simple] → [of_simple] round trip without losing token
      boundaries, so [sudo sh -c "echo hi"] does not become
      [sudo sh -c echo hi]. *)

open Alcotest
open Masc_exec

(* ── Helpers ─────────────────────────────────────────────────── *)

let make_simple
      ?(env = [])
      ?(redirects = [])
      ?(cwd = None)
      bin
      args
  =
  let bin = Result.get_ok (Exec_program.of_string bin) in
  let args = List.map (fun s -> Shell_ir.Lit (s, Shell_ir.default_meta)) args in
  {
    Shell_ir.bin;
    args;
    env;
    cwd;
    redirects;
    sandbox = Sandbox_target.host ();
  }

let is_generic = function
  | Shell_ir_typed.W (Shell_ir_typed.Generic _) -> true
  | _ -> false

let constructor_label = function
  | Shell_ir_typed.W cmd ->
    (match cmd with
     | Shell_ir_typed.Ls _ -> "Ls"
     | Shell_ir_typed.Cat _ -> "Cat"
     | Shell_ir_typed.Rg _ -> "Rg"
     | Shell_ir_typed.Git_status _ -> "Git_status"
     | Shell_ir_typed.Git_clone _ -> "Git_clone"
     | Shell_ir_typed.Curl _ -> "Curl"
     | Shell_ir_typed.Rm _ -> "Rm"
     | Shell_ir_typed.Sudo _ -> "Sudo"
     | Shell_ir_typed.Find _ -> "Find"
     | Shell_ir_typed.Head _ -> "Head"
     | Shell_ir_typed.Tail _ -> "Tail"
     | Shell_ir_typed.Grep _ -> "Grep"
     | Shell_ir_typed.Mkdir _ -> "Mkdir"
     | Shell_ir_typed.Wc _ -> "Wc"
     | Shell_ir_typed.Git_diff _ -> "Git_diff"
     | Shell_ir_typed.Git_log _ -> "Git_log"
     | Shell_ir_typed.Git_commit _ -> "Git_commit"
     | Shell_ir_typed.Git_push _ -> "Git_push"
     | Shell_ir_typed.Git_pull _ -> "Git_pull"
     | Shell_ir_typed.Git_stash _ -> "Git_stash"
     | Shell_ir_typed.Git_rebase _ -> "Git_rebase"
     | Shell_ir_typed.Git_merge _ -> "Git_merge"
     | Shell_ir_typed.Git_branch _ -> "Git_branch"
     | Shell_ir_typed.Git_checkout _ -> "Git_checkout"
     | Shell_ir_typed.Git_fetch _ -> "Git_fetch"
     | Shell_ir_typed.Git_show _ -> "Git_show"
     | Shell_ir_typed.Git_reset _ -> "Git_reset"
     | Shell_ir_typed.Git_blame _ -> "Git_blame"
     | Shell_ir_typed.Git_add _ -> "Git_add"
     | Shell_ir_typed.Pwd _ -> "Pwd"
     | Shell_ir_typed.Echo _ -> "Echo"
     | Shell_ir_typed.Which _ -> "Which"
     | Shell_ir_typed.Sort _ -> "Sort"
     | Shell_ir_typed.Cut _ -> "Cut"
     | Shell_ir_typed.Tr _ -> "Tr"
     | Shell_ir_typed.Date _ -> "Date"
     | Shell_ir_typed.Env _ -> "Env"
     | Shell_ir_typed.Printenv _ -> "Printenv"
     | Shell_ir_typed.Uniq _ -> "Uniq"
     | Shell_ir_typed.Basename _ -> "Basename"
     | Shell_ir_typed.Dirname _ -> "Dirname"
     | Shell_ir_typed.Test _ -> "Test"
     | Shell_ir_typed.Stat _ -> "Stat"
     | Shell_ir_typed.Hostname _ -> "Hostname"
     | Shell_ir_typed.Whoami _ -> "Whoami"
     | Shell_ir_typed.Du _ -> "Du"
     | Shell_ir_typed.Df _ -> "Df"
     | Shell_ir_typed.File _ -> "File"
     | Shell_ir_typed.Printf _ -> "Printf"
     | Shell_ir_typed.Uname _ -> "Uname"
     | Shell_ir_typed.Ps _ -> "Ps"
     | Shell_ir_typed.Tty _ -> "Tty"
     | Shell_ir_typed.Wget _ -> "Wget"
     | Shell_ir_typed.Ssh _ -> "Ssh"
     | Shell_ir_typed.Scp _ -> "Scp"
     | Shell_ir_typed.Tar _ -> "Tar"
     | Shell_ir_typed.Make _ -> "Make"
     | Shell_ir_typed.Diff _ -> "Diff"
     | Shell_ir_typed.Sed _ -> "Sed"
     | Shell_ir_typed.Rsync _ -> "Rsync"
     | Shell_ir_typed.Node _ -> "Node"
     | Shell_ir_typed.Python _ -> "Python"
     | Shell_ir_typed.Python3 _ -> "Python3"
     | Shell_ir_typed.Pip _ -> "Pip"
     | Shell_ir_typed.Patch _ -> "Patch"
     | Shell_ir_typed.Npm _ -> "Npm"
     | Shell_ir_typed.Cargo _ -> "Cargo"
     | Shell_ir_typed.Go _ -> "Go"
     | Shell_ir_typed.Gh _ -> "Gh"
     | Shell_ir_typed.Chmod _ -> "Chmod"
     | Shell_ir_typed.Chown _ -> "Chown"
     | Shell_ir_typed.Docker _ -> "Docker"
     | Shell_ir_typed.Opam _ -> "Opam"
     | Shell_ir_typed.Npx _ -> "Npx"
     | Shell_ir_typed.Yarn _ -> "Yarn"
     | Shell_ir_typed.Pnpm _ -> "Pnpm"
     | Shell_ir_typed.Uv _ -> "Uv"
     | Shell_ir_typed.Glab _ -> "Glab"
     | Shell_ir_typed.Pytest _ -> "Pytest"
     | Shell_ir_typed.Terminal_notifier _ -> "Terminal_notifier"
     | Shell_ir_typed.Ruff _ -> "Ruff"
     | Shell_ir_typed.Pyright _ -> "Pyright"
     | Shell_ir_typed.Tsc _ -> "Tsc"
     | Shell_ir_typed.Ocamlfind _ -> "Ocamlfind"
     | Shell_ir_typed.Rustc _ -> "Rustc"
     | Shell_ir_typed.Gofmt _ -> "Gofmt"
     | Shell_ir_typed.Gradle _ -> "Gradle"
     | Shell_ir_typed.Ninja _ -> "Ninja"
     | Shell_ir_typed.Java _ -> "Java"
     | Shell_ir_typed.Javac _ -> "Javac"
     | Shell_ir_typed.Mvn _ -> "Mvn"
     | Shell_ir_typed.Cmake _ -> "Cmake"
     | Shell_ir_typed.Dune_local_sh _ -> "Dune_local_sh"
     | Shell_ir_typed.Osascript _ -> "Osascript"
     | Shell_ir_typed.Play _ -> "Play"
     | Shell_ir_typed.Rec _ -> "Rec"
     | Shell_ir_typed.Ffplay _ -> "Ffplay"
     | Shell_ir_typed.Mpg123 _ -> "Mpg123"
     | Shell_ir_typed.Open _ -> "Open"
     | Shell_ir_typed.Su _ -> "Su"
     | Shell_ir_typed.Dd _ -> "Dd"
     | Shell_ir_typed.Mkfs _ -> "Mkfs"
     | Shell_ir_typed.Cp _ -> "Cp"
     | Shell_ir_typed.Mv _ -> "Mv"
     | Shell_ir_typed.Ln _ -> "Ln"
     | Shell_ir_typed.Touch _ -> "Touch"
     | Shell_ir_typed.Tee _ -> "Tee"
     | Shell_ir_typed.Awk _ -> "Awk"
     | Shell_ir_typed.Xargs _ -> "Xargs"
     | Shell_ir_typed.Generic _ -> "Generic")

(* ── P1: env / redirects force Generic fallback ──────────────── *)

let test_env_forces_generic () =
  let simple =
    make_simple ~env:[ "PATH", Shell_ir.Lit ("/tmp", Shell_ir.default_meta) ] "ls" [ "-l" ]
  in
  let result = Shell_ir_typed.of_simple simple in
  check bool
    "ls with env=[PATH=/tmp] must fall through to Generic so \
     Env_set capability is preserved"
    true (is_generic result)

let test_redirects_force_generic () =
  let target = Path_scope.classify ~raw:"/tmp/out.txt" ~cwd:"/tmp" in
  let redir =
    Redirect_scope.File { fd = 1; target; mode = Redirect_scope.Write }
  in
  let simple = make_simple ~redirects:[ redir ] "cat" [ "/etc/hosts" ] in
  let result = Shell_ir_typed.of_simple simple in
  check bool
    "cat with > redirect must fall through to Generic so Write_path \
     capability is preserved (Approval_policy.find_write_escape \
     depends on this)"
    true (is_generic result)

let test_clean_simple_lifts_to_specific () =
  let simple = make_simple "ls" [ "-l"; "/tmp" ] in
  let result = Shell_ir_typed.of_simple simple in
  check string
    "ls without env / redirects lifts to the Ls constructor"
    "Ls" (constructor_label result)

(* ── P2 (None → Generic): no silent option-None outcome ──────── *)

let test_non_literal_arg_falls_through_to_generic () =
  let simple_with_var =
    {
      Shell_ir.bin = Result.get_ok (Exec_program.of_string "ls");
      args = [ Shell_ir.Var ("HOME", Shell_ir.default_meta) ];
      env = [];
      cwd = None;
      redirects = [];
      sandbox = Sandbox_target.host ();
    }
  in
  let result = Shell_ir_typed.of_simple simple_with_var in
  check bool
    "non-literal arg (Var) must fall through to Generic, never \
     swallowed silently"
    true (is_generic result)

let test_unhandled_safe_bin_falls_through_to_generic () =
  (* `awk` was added to Exec_program.known in this branch; use a bin that is
     deliberately absent from known to keep the Generic fallback invariant. *)
  let simple = make_simple "frobnicate" [ "--help" ] in
  let result = Shell_ir_typed.of_simple simple in
  check bool
    "unknown-bin without dedicated parser must fall through to Generic"
    true (is_generic result)

let test_docker_lifts_to_docker_constructor () =
  let simple = make_simple "docker" [ "ps" ] in
  let result = Shell_ir_typed.of_simple simple in
  check string
    "docker now has a typed parser — must lift to Docker constructor"
    "Docker" (constructor_label result)

let test_su_lifts_to_su_constructor () =
  let simple = make_simple "su" [ "root" ] in
  let result = Shell_ir_typed.of_simple simple in
  check string
    "su now has a typed parser — must lift to Su constructor"
    "Su" (constructor_label result)

(* ── P2 (sudo argv): no whitespace-loss round trip ───────────── *)

let extract_sudo_argv = function
  | Shell_ir_typed.W (Shell_ir_typed.Sudo { target_argv }) -> target_argv
  | _ -> failwith "expected Sudo wrapper"

let test_sudo_lifts_argv_as_list () =
  let simple = make_simple "sudo" [ "sh"; "-c"; "echo hi" ] in
  let result = Shell_ir_typed.of_simple simple in
  let argv = extract_sudo_argv result in
  check (list string)
    "sudo lifts argv as a list of three tokens, NOT a single \
     space-joined string"
    [ "sh"; "-c"; "echo hi" ] argv

let test_sudo_round_trip_preserves_quoted_arg () =
  (* The whole point of target_argv : string list. Round-trip must not
     re-split the third arg ("echo hi") on its embedded space. *)
  let original = make_simple "sudo" [ "sh"; "-c"; "echo hi" ] in
  let typed = Shell_ir_typed.of_simple original in
  let reconstructed =
    match typed with
    | Shell_ir_typed.W cmd -> Shell_ir_typed.to_simple cmd
  in
  let reconstructed_argv =
    List.map
      (function
        | Shell_ir.Lit (s, _) -> s
        | Shell_ir.Var (_, _) | Shell_ir.Concat _ -> failwith "unexpected non-lit arg")
      reconstructed.Shell_ir.args
  in
  check (list string)
    "sudo round trip keeps the third token intact (would be \
     [sh; -c; echo; hi] under the old space-join encoding)"
    [ "sh"; "-c"; "echo hi" ] reconstructed_argv

(* ── Test runner ─────────────────────────────────────────────── *)

let suite =
  [ ( "of_simple Generic fallback (P1 + P2)"
    , [ test_case "env forces Generic" `Quick test_env_forces_generic
      ; test_case "redirects force Generic" `Quick test_redirects_force_generic
      ; test_case "clean simple lifts to specific" `Quick test_clean_simple_lifts_to_specific
      ; test_case
          "non-literal arg falls through" `Quick
          test_non_literal_arg_falls_through_to_generic
      ; test_case
          "unhandled safe bin falls through" `Quick
          test_unhandled_safe_bin_falls_through_to_generic
      ; test_case
          "docker lifts to Docker" `Quick
          test_docker_lifts_to_docker_constructor
      ; test_case
          "su lifts to Su" `Quick
          test_su_lifts_to_su_constructor
      ] )
  ; ( "Sudo argv tokenization (P2)"
    , [ test_case "sudo lifts argv as list" `Quick test_sudo_lifts_argv_as_list
      ; test_case
          "sudo round trip preserves quoted arg" `Quick
          test_sudo_round_trip_preserves_quoted_arg
      ] )
  ]

let () = run "shell_ir_typed_review_followup" suite
