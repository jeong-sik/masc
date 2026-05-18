val lowercase_contains : string -> string -> bool
val command_mentions_task_state_file : string -> bool
val command_looks_like_task_state_http_probe : string -> bool
val command_looks_like_task_state_discovery : string -> bool
val task_state_shell_hint : string
val task_state_shell_alternatives : string list
val command_looks_like_search_pipeline : string -> bool
val command_looks_like_find_pipeline : string -> bool
val command_looks_like_cd_chained_search : string -> bool
val command_looks_like_repo_wide_git_log_grep : string -> bool
val command_looks_like_repo_wide_rg : string -> bool
