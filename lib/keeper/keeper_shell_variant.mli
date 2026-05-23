(** Variant SSOT for keeper_shell ops (issue #8524).

    Adding a constructor forces compilation across:
    - [shell_op_to_string] / [shell_op_of_string] (round-trip invariant)
    - [valid_shell_op_strings] (schema mirror in [tool_shard.ml])
    - [all_shell_ops] (test enumeration)
    - The dispatcher arms in [Keeper_shell_ops.handle_keeper_shell]

    Historical drift: the schema previously omitted [git_worktree]
    even though the dispatcher listed it.  Closed-variant SSOT
    prevents that class of bug. *)

type shell_op =
  | Pwd
  | Ls
  | Cat
  | Rg
  | Git_status
  | Find
  | Head
  | Tail
  | Wc
  | Tree
  | Git_log
  | Git_diff
  | Git_worktree
  | Git_clone
  | Gh

val shell_op_to_string : shell_op -> string
val shell_op_of_string : string -> shell_op option
val all_shell_ops : shell_op list
val valid_shell_op_strings : string list
