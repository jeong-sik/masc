include module type of Cp_types

val control_plane_dir : Room.room_config -> string
val control_plane_root_dir : Room.room_config -> string
val legacy_control_plane_root_dir : Room.room_config -> string
val units_path : Room.room_config -> string
val operations_path : Room.room_config -> string
val intents_path : Room.room_config -> string
val events_path : Room.room_config -> string
val detachments_path : Room.room_config -> string
val decisions_path : Room.room_config -> string
val traces_dir : Room.room_config -> string
val operator_dir : Room.room_config -> string
val operator_pending_confirms_path : Room.room_config -> string
val operator_action_log_path : Room.room_config -> string
val swarm_path : Room.room_config -> string
val swarm_live_dirs : Room.room_config -> string list
val swarm_live_run_dirs : Room.room_config -> string -> string list
val primary_swarm_live_run_dir : Room.room_config -> string -> string
val find_swarm_live_artifact_path :
  Room.room_config -> string -> string -> string option
val swarm_live_resolution_path : Room.room_config -> string -> string
val find_swarm_live_artifact_json :
  Room.room_config -> string -> string -> Yojson.Safe.t option
val search_stats_path : Room.room_config -> string
