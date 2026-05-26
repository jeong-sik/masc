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

let all =
  [ Pwd; Ls; Cat; Rg; Git_status; Find; Head; Tail; Wc; Tree; Git_log; Git_diff ]

let valid_strings = List.map to_string all
