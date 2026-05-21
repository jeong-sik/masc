(** Meta-cognition summary cache helpers for dashboard HTTP core. *)

module Mc_cache : module type of Server_dashboard_meta_cognition_cache

val meta_cognition_summary_ttl : float

val meta_cognition_summary_stale_for : float

val meta_cognition_summary_empty_json : Yojson.Safe.t

val dashboard_shell_cache_prefix : Coord.config -> string

val dashboard_shell_cache_key : ?light:bool -> Coord.config -> string

val meta_cognition_summary_key : Coord.config -> string

val store_last_good_meta_cognition_summary : string -> Yojson.Safe.t -> unit

val find_last_good_meta_cognition_summary : string -> Yojson.Safe.t option

val clear_meta_cognition_warm_flag : string -> unit

val schedule_meta_cognition_summary_warm : Coord.config -> unit

val meta_cognition_summary_cached : Coord.config -> Yojson.Safe.t
