(** RFC-0254 follow-up — gh REST/GraphQL endpoint path-jail false positive.

    [Exec_policy.validate_shell_ir_paths] jailed [gh api /repos/...] because
    the [looks_like_path_token] fallback treated the leading-[/] REST endpoint
    as an absolute filesystem path. The descriptor intentionally excludes [gh]
    from path-materializing commands (its positional args are issue numbers,
    refs, repo specs, and API endpoints), so these tests pin that a gh endpoint
    is exempt from the jail while a real file argument and any [..] traversal
    stay jailed. End-to-end against [Exec_policy.validate_shell_ir_paths]. *)

module Shell_ir = Masc_exec.Shell_ir
module Exec_program = Masc_exec.Exec_program
module Sandbox_target = Masc_exec.Sandbox_target

let lit s = Shell_ir.Lit (s, Shell_ir.default_meta)

let bin name =
  match Exec_program.of_string name with
  | Ok b -> b
  (* bin must classify *)
  | Error _ -> assert false

let ir name args : Shell_ir.t =
  Shell_ir.Simple
    {
      bin = bin name;
      args = List.map lit args;
      env = [];
      cwd = None;
      redirects = [];
      sandbox = Sandbox_target.host ();
    }

let workdir = "/tmp"
let is_ok = function Ok () -> true | Error _ -> false
let is_err = function Error _ -> true | Ok () -> false

(* The reported false positive: a gh api REST endpoint with a leading slash
   must not be jailed as an absolute filesystem path. *)
let test_gh_api_endpoint_allowed () =
  let shell_ir = ir "gh" [ "api"; "/repos/jeong-sik/masc/check-runs?head_sha=abc" ] in
  assert (is_ok (Exec_policy.validate_shell_ir_paths ~workdir shell_ir))

(* Repo-spec / no-leading-slash endpoint form is exempt too. *)
let test_gh_api_repo_spec_allowed () =
  let shell_ir = ir "gh" [ "api"; "repos/jeong-sik/masc/pulls/21434" ] in
  assert (is_ok (Exec_policy.validate_shell_ir_paths ~workdir shell_ir))

(* Safety: a [..] traversal under gh is still jailed. *)
let test_gh_parent_traversal_blocked () =
  let shell_ir = ir "gh" [ "api"; "../../../etc/passwd" ] in
  assert (is_err (Exec_policy.validate_shell_ir_paths ~workdir shell_ir))

(* Safety: the exemption is gh-specific. A path-materializing command (cat)
   with the same look-alike token stays jailed. *)
let test_non_gh_endpointlike_token_blocked () =
  let shell_ir = ir "cat" [ "/repos/jeong-sik/masc/secret" ] in
  assert (is_err (Exec_policy.validate_shell_ir_paths ~workdir shell_ir))

let () =
  test_gh_api_endpoint_allowed ();
  test_gh_api_repo_spec_allowed ();
  test_gh_parent_traversal_blocked ();
  test_non_gh_endpointlike_token_blocked ();
  print_endline "[test_exec_policy_gh_endpoint_jail] all tests passed"
