(** Pure field selection, quoting and grouping; no prompt catalog or observation acquisition. *)
val format_prompt_row : (string * string) list -> string
val approval_observation_fields : Keeper_world_observation.pending_approval_observation -> (string * string) list
val board_event_fields : Keeper_world_observation.pending_board_event -> (string * string) list
(** Ask rows carry original question/answer data, excluding display preview and
    its short excerpt. Other event projections retain their existing fields. *)
val format_board_event_text : Keeper_world_observation.pending_board_event -> string
val format_scheduled_automation_item : Keeper_world_observation.scheduled_automation_item -> string
val scheduled_wake_fields : occurrence_id:string -> Keeper_event_queue.scheduled_wake -> (string * string) list

type scheduled_admission =
  | Unknown
  | Known of Keeper_event_queue_state.pending_selection list
(** [Known []] observes no admitted scheduled input at this entry. [Unknown]
    has no intake observation; it must not be inferred to mean an empty queue. *)
val format_scheduled_admission :
  turn_ref:Ids.Turn_ref.t -> admission:scheduled_admission -> string
(** Always a nonempty, quoted turn-entry fact, including known-empty and unknown
    observations. Only exact admitted Schedule_due identities are projected;
    request prose stays in durable User input. No current standing, permission,
    cancellation, delivery or completion authority is asserted. *)

type scheduled_wake_group
val group_scheduled_wake_events : Keeper_world_observation.pending_board_event list -> scheduled_wake_group list
val scheduled_wake_group_fields : scheduled_wake_group -> (string * string) list
