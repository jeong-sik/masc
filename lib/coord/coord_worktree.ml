(** Coord Worktree - Facade.

    Stage 06 of the godfile decomposition plan (2026-05-18) split the
    1551-LOC [coord_worktree.ml] into narrow-interface submodules:

    - {!Coord_worktree_exec}              — argv-only exec wrappers
    - {!Coord_worktree_policy}            — clone-policy parsing + URL
                                            validation
    - {!Coord_worktree_paths}             — pure path / shape helpers,
                                            mutation lock
    - {!Coord_worktree_repo_discovery}    — repo enumeration + task
                                            evidence scoring
    - {!Coord_worktree_sandbox_clone}     — sandbox clone inspect / repair
                                            / auto-provision
    - {!Coord_worktree_destructive_ops}   — every [rm -rf] /
                                            [git worktree remove] /
                                            [git branch -D] /
                                            [git worktree prune] call
    - {!Coord_worktree_lifecycle}         — public worktree create /
                                            remove / list / link

    This facade keeps the [Coord_worktree.foo] surface intact for callers
    by re-exporting submodule symbols through [include].  The [.mli]
    contract is unchanged. *)

(* Argv-only exec helpers *)
include Coord_worktree_exec

(* Policy parsing & URL validation. [Coord_worktree_exec.first_nonempty_line]
   already exposes that name; policy does not. *)
include Coord_worktree_policy

(* Pure path helpers and the mutation lock. *)
include Coord_worktree_paths

(* Sandbox clone state / inspect / repair / auto-provision. *)
include Coord_worktree_sandbox_clone

(* Repo discovery & scoring. *)
include Coord_worktree_repo_discovery

(* Destructive filesystem / git operations. [rm_rf] is the only public
   symbol from this module that the legacy [.mli] exposes; the other
   helpers (git_worktree_remove, git_branch_force_delete,
   git_worktree_prune) stay internal to lifecycle. *)
include Coord_worktree_destructive_ops

(* Public worktree lifecycle (create / remove / list / link). *)
include Coord_worktree_lifecycle
