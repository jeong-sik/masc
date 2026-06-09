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

(* Inverse of [to_string], derived from it so the two cannot drift: a string
   is a valid op iff it round-trips through some variant. Returns None for an
   unknown op, which the dispatch boundary turns into a typed rejection
   instead of letting an unrecognized string flow into a string match. *)
let of_string s = List.find_opt (fun v -> String.equal (to_string v) s) all
