(** Keeper shell tool handlers — bash execution and structured shell ops.

    Handles [keeper_bash] (arbitrary commands with blocklist) and
    [keeper_shell] (structured ops: ls, cat, find, rg, head, tail, wc, tree,
    git-log, git-diff, git-status, git-clone, git-worktree, bash).

    Both tools default to the keeper playground unless an explicit
    allowed [cwd] is provided. *)

val handle_keeper_bash :
  config:Room.config ->
  meta:Keeper_types.keeper_meta ->
  args:Yojson.Safe.t ->
  string

val docker_playground_cwd :
  playground_abs:string ->
  meta:Keeper_types.keeper_meta ->
  string ->
  string

val handle_keeper_shell :
  config:Room.config ->
  meta:Keeper_types.keeper_meta ->
  args:Yojson.Safe.t ->
  string
