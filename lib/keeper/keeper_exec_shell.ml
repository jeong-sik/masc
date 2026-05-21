(* Facade: keeper_exec_shell — thin re-export layer.
   Types, constants, and helpers live in [Keeper_shell_shared].
   [handle_keeper_bash] lives in [Keeper_shell_bash].
   [handle_keeper_shell] lives in [Keeper_shell_ops].
   Docker/GH-context sub-modules remain as before. *)

include Keeper_shell_shared

include Keeper_shell_bash

(* ── GH repo context (extracted to Keeper_shell_gh_context) ──── *)
type gh_repo_context = Keeper_shell_gh_context.gh_repo_context = {
  task_id : string;
  git_root : string;
  worktree_cwd : string;
  repo_slug : string option;
}

let gh_repo_context_error = Keeper_shell_gh_context.gh_repo_context_error
let gh_claim_first_hint = Keeper_shell_gh_context.gh_claim_first_hint
let gh_repo_context_error_json = Keeper_shell_gh_context.gh_repo_context_error_json
let resolve_gh_repo_context = Keeper_shell_gh_context.resolve_gh_repo_context

include Keeper_shell_ops

module For_testing = struct
  let elapsed_duration_ms = Keeper_shell_bash.For_testing.elapsed_duration_ms
end
