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
  standing:
    (Keeper_event_queue_state.pending_selection ->
     (Keeper_event_queue_state.admitted_selection_standing, string) result) ->
  t -> (t * Keeper_event_queue_state.pending_selection list, string) result
(** Validate the exact batch at provider dispatch. A selection another
    transition withdrew after intake leaves the returned batch and is listed
    separately; the rest keep their order. Only when no source was admitted,
    retain the existing diagnostic-selection check. That diagnostic never
    becomes an admitted source and is not returned by [selections]. *)

type turn_input
val for_turn : reactive:bool -> t -> turn_input
val sources : turn_input -> t
val wake : turn_input -> Keeper_registry.wake_reason
(** Project payloads only at the observation/prompt boundary. Reactive empty
    input and a cadence tick remain distinct. No Fresh/Resume is inferred. *)
