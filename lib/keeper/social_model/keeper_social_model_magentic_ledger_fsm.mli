type phase =
  | Advancing
  | Reactive
  | Stalled
  | Quiet

type event =
  | Progress_observed
  | Signals_pending
  | Goal_idle_timeout
  | All_quiet
  | Failure_observed

type input =
  { has_progress_evidence : bool
  ; has_reactive_signal : bool
  ; has_active_goals : bool
  ; idle_seconds : int
  }

type snapshot = { phase : phase }

val initial : snapshot
val all_phases : phase list
val all_events : event list
val phase_to_string : phase -> string
val phase_of_string : string -> phase option
val event_to_string : event -> string
val event_of_string : string -> event option
val snapshot_of_social_state : Keeper_social_model_types.social_state -> snapshot option
val classify_event : previous:snapshot option -> input -> event
val apply_event : current:snapshot -> event -> snapshot
