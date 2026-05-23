(* Issue #8524: Variant SSOT for keeper_shell op.  Adding a constructor
   forces compilation in [shell_op_to_string] AND extends
   [valid_shell_op_strings]; the schema in [tool_shard.ml] mirrors
   the SSOT (cycle-aware, sync test) and [supported_ops] in
   [handle_keeper_shell_unsupported] derives from it (replaced the
   hand-rolled list which had drifted from the dispatcher). The
   schema previously omitted [git_worktree] even though the
   dispatcher and supported_ops both list it — same drift class as
   #8430 / #8471 / #8474 / #8493 / #8513. *)
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

let shell_op_to_string = function
  | Pwd -> "pwd"
  | Ls -> "ls"
  | Cat -> "cat"
  | Rg -> "rg"
  | Git_status -> "git_status"
  | Find -> "find"
  | Head -> "head"
  | Tail -> "tail"
  | Wc -> "wc"
  | Tree -> "tree"
  | Git_log -> "git_log"
  | Git_diff -> "git_diff"
  | Git_worktree -> "git_worktree"
  | Git_clone -> "git_clone"
  | Gh -> "gh"

let normalize_shell_op_alias s =
  match s with
  | "git status" | "status" -> "git_status"
  | "git log" -> "git_log"
  | "git diff" -> "git_diff"
  | "git worktree" | "worktree" -> "git_worktree"
  | "read" | "file" | "type" -> "cat"
  | "grep" | "search" -> "rg"
  | "dir" | "list" -> "ls"
  | "git clone" | "clone" -> "git_clone"
  | s -> s

let shell_op_of_string raw =
  let s = String.trim (String.lowercase_ascii raw) in
  match normalize_shell_op_alias s with
  | "pwd" -> Some Pwd
  | "ls" -> Some Ls
  | "cat" -> Some Cat
  | "rg" -> Some Rg
  | "git_status" -> Some Git_status
  | "find" -> Some Find
  | "head" -> Some Head
  | "tail" -> Some Tail
  | "wc" -> Some Wc
  | "tree" -> Some Tree
  | "git_log" -> Some Git_log
  | "git_diff" -> Some Git_diff
  | "git_worktree" -> Some Git_worktree
  | "git_clone" -> Some Git_clone
  | "gh" -> Some Gh
  | _ -> None

let all_shell_ops =
  [ Pwd; Ls; Cat; Rg; Git_status; Find; Head; Tail; Wc; Tree;
    Git_log; Git_diff; Git_worktree; Git_clone; Gh ]

let valid_shell_op_strings = List.map shell_op_to_string all_shell_ops
