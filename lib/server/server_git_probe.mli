type git_upstream_status =
  Server_dashboard_http_runtime_info_json.git_upstream_status =
  { branch : string option
  ; upstream_ref : string option
  ; upstream_head_commit : string option
  ; ahead_count : int option
  ; behind_count : int option
  }

val git_rev_parse_short : string -> string option

val git_upstream_status : string -> git_upstream_status option

val empty_git_upstream_status : git_upstream_status

val git_rev_parse_short_probe_argv : string -> string list

val clear_git_rev_parse_short_cache_for_tests : unit -> unit
val seed_git_rev_parse_short_cache_for_tests : string -> string option -> refreshed_at:float -> unit

val set_git_rev_parse_short_probe_hook_for_tests : (string -> string option) -> unit
val clear_git_rev_parse_short_probe_hook_for_tests : unit -> unit

val set_git_upstream_status_probe_hook_for_tests : (string -> git_upstream_status option) -> unit
val clear_git_upstream_status_probe_hook_for_tests : unit -> unit

val clear_git_upstream_status_cache_for_tests : unit -> unit
val seed_git_upstream_status_cache_for_tests : string -> git_upstream_status option -> refreshed_at:float -> unit
