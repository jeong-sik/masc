type t =
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

let to_string = function
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

let all =
  [ Pwd; Ls; Cat; Rg; Git_status; Find; Head; Tail; Wc; Tree; Git_log; Git_diff; Git_worktree ]

let valid_strings = List.map to_string all
