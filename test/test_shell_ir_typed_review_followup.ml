(** test_shell_ir_typed_review_followup — invariants enforced by the
    Codex review on PR #14240.

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
  let bin = Result.get_ok (Bin.of_string bin) in
  let args = List.map (fun s -> Shell_ir.Lit s) args in
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
     | Shell_ir_typed.Generic _ -> "Generic")

(* ── P1: env / redirects force Generic fallback ──────────────── *)

let test_env_forces_generic () =
  let simple =
    make_simple ~env:[ "PATH", Shell_ir.Lit "/tmp" ] "ls" [ "-l" ]
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
      Shell_ir.bin = Result.get_ok (Bin.of_string "ls");
      args = [ Shell_ir.Var "HOME" ];
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
  (* `pwd` is safe-bin-kind but has no dedicated parser. *)
  let simple = make_simple "pwd" [] in
  let result = Shell_ir_typed.of_simple simple in
  check bool
    "safe-bin without dedicated parser must fall through to Generic"
    true (is_generic result)

let test_docker_falls_through_to_generic () =
  let simple = make_simple "docker" [ "ps" ] in
  let result = Shell_ir_typed.of_simple simple in
  check bool
    "docker (Docker bin kind) has no typed parser yet — must be \
     Generic, not silently dropped"
    true (is_generic result)

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
        | Shell_ir.Lit s -> s
        | Shell_ir.Var _ | Shell_ir.Concat _ -> failwith "unexpected non-lit arg")
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
          "docker falls through" `Quick
          test_docker_falls_through_to_generic
      ] )
  ; ( "Sudo argv tokenization (P2)"
    , [ test_case "sudo lifts argv as list" `Quick test_sudo_lifts_argv_as_list
      ; test_case
          "sudo round trip preserves quoted arg" `Quick
          test_sudo_round_trip_preserves_quoted_arg
      ] )
  ]

let () = run "shell_ir_typed_review_followup" suite
