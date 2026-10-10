(** Pure field selection, quoting and grouping; no prompt catalog or observation acquisition. *)
val format_prompt_row : (string * string) list -> string
val approval_observation_fields : Keeper_world_observation.pending_approval_observation -> (string * string) list
val board_event_fields : Keeper_world_observation.pending_board_event -> (string * string) list
val format_board_event_text : Keeper_world_observation.pending_board_event -> string
val format_scheduled_automation_item : Keeper_world_observation.scheduled_automation_item -> string
val scheduled_wake_fields : occurrence_id:string -> Keeper_event_queue.scheduled_wake -> (string * string) list

type scheduled_wake_group
val group_scheduled_wake_events : Keeper_world_observation.pending_board_event list -> scheduled_wake_group list
val scheduled_wake_group_fields : scheduled_wake_group -> (string * string) list
