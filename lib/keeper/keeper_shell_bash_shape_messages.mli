type bash_shape_block =
  | Gh_pr_checks
  | Pipe_or_redirect
  | Chaining
  | Substitution
  | Repo_wide_scan

type recovery_plan = {
  next_tool : string;
  next_args : (string * Yojson.Safe.t) list;
  instruction : string;
  reason : string;
  confidence : string;
}

val bash_shape_block_tag : bash_shape_block -> string
val bash_shape_block_reason : bash_shape_block -> string
val bash_shape_block_hint : cmd:string -> bash_shape_block -> string
val bash_shape_block_alternatives : cmd:string -> bash_shape_block -> string list
val recovery_plan_to_json : recovery_plan -> Yojson.Safe.t
val bash_shape_block_recovery_plan : cmd:string -> bash_shape_block -> recovery_plan option
