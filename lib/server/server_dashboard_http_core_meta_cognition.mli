(** Meta-cognition summary cache helpers for dashboard HTTP core. *)

module Mc_cache : module type of Server_dashboard_meta_cognition_cache

val meta_cognition_summary_ttl : float

val dashboard_shell_cache_prefix : Workspace.config -> string

val dashboard_shell_cache_key : ?light:bool -> Workspace.config -> string

val meta_cognition_summary_key : Workspace.config -> string

val clear_meta_cognition_warm_flag : string -> unit

val schedule_meta_cognition_summary_warm : Workspace.config -> unit

val meta_cognition_summary_cached : Workspace.config -> Yojson.Safe.t
