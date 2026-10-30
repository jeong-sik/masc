(** Exact queue selections observed by one heartbeat intake. The batch retains
    every source envelope and repetition binding without choosing an invocation. *)
type t
val empty : t
(** No intake read: every pending source counts as a later arrival. *)
val of_selections : Keeper_event_queue_state.pending_selection list -> t
(** Selections supplied without an intake read. Like {!empty}, every pending
    source, these included, counts as a later arrival. *)
val of_intake :
  frontier:Keeper_event_queue_state.frontier ->
  admitted:Keeper_event_queue_state.pending_selection list -> t
(** Preserve the frontier of the very state that intake read when it selected
    [admitted]. Backlog that was not admitted is observation only; it gains no
    execution or acknowledgement authority. *)
val selections : t -> Keeper_event_queue_state.pending_selection list
val arrived_since_intake : t -> Keeper_event_queue_state.pending_selection -> bool
(** True when a pending source reached the queue after the intake read. Edits of
    a source intake already saw, admitted or not, never make it arrive later. *)
val stimuli : t -> Keeper_event_queue.stimulus list
val count : t -> int
val first : t -> Keeper_event_queue_state.pending_selection option

val observed_sources_to_yojson : t -> Yojson.Safe.t
(** Private diagnostic projection of every exact intake selection, in order:
    canonical stimulus id, source snapshot reference, admitted revision and
    optional first-admission clock. No source payload is copied. This records
    observation at turn entry, not provider dispatch, delivery or acknowledgement;
    [validate] may subsequently withdraw a selection. It grants no replay or
    deduplication authority. *)

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
