type bash_shape_block =
  | Gh_pr_checks
  | Pipe_or_redirect
  | Chaining
  | Substitution
  | Repo_wide_scan

val bash_shape_block_tag : bash_shape_block -> string
val bash_shape_block_reason : bash_shape_block -> string
val bash_shape_block_hint : cmd:string -> bash_shape_block -> string
val bash_shape_block_alternatives : cmd:string -> bash_shape_block -> string list
