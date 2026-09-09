(** Exact queue selections observed by one heartbeat intake. The batch retains
    every source envelope and repetition binding without choosing an invocation. *)
type t
val empty : t
val of_selections : Keeper_event_queue_state.pending_selection list -> t
val selections : t -> Keeper_event_queue_state.pending_selection list
val stimuli : t -> Keeper_event_queue.stimulus list
val count : t -> int
val first : t -> Keeper_event_queue_state.pending_selection option

val validate :
  diagnostic:Keeper_event_queue_state.pending_selection option ->
  validate_selection:(Keeper_event_queue_state.pending_selection -> (unit, string) result) ->
  t -> (unit, string) result
(** Validate the exact batch. Only when no source was admitted, retain the
    existing diagnostic-selection check. That diagnostic never becomes an
    admitted source and is not returned by [selections]. *)

type turn_input
val for_turn : reactive:bool -> t -> turn_input
val sources : turn_input -> t
val wake : turn_input -> Keeper_registry.wake_reason
(** Project payloads only at the observation/prompt boundary. Reactive empty
    input and a cadence tick remain distinct. No Fresh/Resume is inferred. *)
