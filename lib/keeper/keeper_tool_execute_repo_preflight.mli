(** Repo readiness preflight for typed Execute.

    This module owns repo currency and git-checkout probes. The path resolver
    only maps cwd/path strings; repo state checks live here so callers can make
    command-shape decisions explicitly. *)

type repo_currency_policy =
  | Reject_repo_currency_sync
  | Allow_repo_currency_sync

val validate_cwd_ready :
  repo_currency_policy:repo_currency_policy ->
  config:Workspace.config ->
  meta:Keeper_meta_contract.keeper_meta ->
  cwd:string ->
  allow_stale_preserved_repo_context:bool ->
  (unit, string) result
(** Reject typed Execute commands from a sandbox [repos/<repo>] path unless the
    cwd is already an independent git checkout/worktree. For direct repo roots,
    also reject normal work when the repo currency probe preserves or skips the
    clone; diagnostic/recovery policy is supplied by the caller. When
    [repo_currency_policy] is [Reject_repo_currency_sync], direct repo-root
    normal work is rejected without fetch/fast-forward side effects. *)

val validate_path_args_ready :
  config:Workspace.config ->
  meta:Keeper_meta_contract.keeper_meta ->
  cwd:string ->
  Masc_exec.Shell_ir.t ->
  (unit, string) result
(** Reject typed Execute path arguments that point into a sandbox [repos/<repo>]
    directory unless that target is already an independent git checkout. This
    never creates directories or changes repo/worktree state. *)

val invalidate_currency_cache :
  config:Workspace.config ->
  meta:Keeper_meta_contract.keeper_meta ->
  repo_name:string ->
  unit
(** Clear the cached currency probe for [repo_name]. *)
