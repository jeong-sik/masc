(** Keeper shell tool handlers — bash execution and structured shell ops.

    Handles [keeper_bash] (arbitrary commands with blocklist) and
    [keeper_shell] (structured ops: ls, cat, find, rg, head, tail, wc, tree,
    git-log, git-diff, git-status, git-clone, git-worktree, bash).

    Both tools default to the keeper playground unless an explicit
    allowed [cwd] is provided. *)

(** Canonical list of [keeper_shell.op] identifiers accepted by the
    handler. SSOT for the schema enum (mirrored in
    [Tool_shard.keeper_shell_op_enum_strings] to avoid a Tool_shard ->
    Keeper_* -> Tool_shard cycle) and the [supported_ops] self-advert
    response. Issue #8524. *)
val valid_keeper_shell_op_strings : string list

val handle_keeper_bash :
  config:Coord.config ->
  meta:Keeper_types.keeper_meta ->
  args:Yojson.Safe.t ->
  string

val handle_keeper_shell :
  config:Coord.config ->
  meta:Keeper_types.keeper_meta ->
  args:Yojson.Safe.t ->
  string
