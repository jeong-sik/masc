(** Keeper shell tool handlers — bash execution and read-only ops.

    Handles [keeper_bash] (write-capable) and [keeper_shell_readonly]
    (ls, cat, find, grep, head, tail, wc, tree, git-log, git-diff, git-status,
    git-clone).

    Write-capable bash blocks dangerous commands (rm, mv, chmod, etc.)
    and chaining operators (&&, ||, ;) via substring blocklist.
    Both tools default to the keeper playground unless an explicit
    allowed [cwd] is provided. *)

val handle_keeper_bash :
  config:Room.config ->
  meta:Keeper_types.keeper_meta ->
  args:Yojson.Safe.t ->
  string

val handle_keeper_shell_readonly :
  config:Room.config ->
  meta:Keeper_types.keeper_meta ->
  args:Yojson.Safe.t ->
  string
