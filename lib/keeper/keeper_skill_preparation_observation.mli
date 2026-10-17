(** Observations of actual Skill preparation accesses. No admission authority. *)

type component = Projection | Task_product | Retained_turn_surface
type decision = Constructed | Reused
type outcome = In_progress | Returned | Returned_error | Raised | Cancelled
type coverage = Fiber_capture | Non_eio_unobserved

type sample = private
  { component : component
  ; snapshot_revision : Skill_catalog_snapshot.snapshot_revision
  ; descriptor_count : int
  ; entered_ns : int64
  ; lookup_finished_ns : int64 option
  ; lock_acquired_ns : int64 option
  ; decision_ns : int64 option
  ; decision : decision option
  ; finished_ns : int64 option
  ; outcome : outcome
  }

type report = private
  { coverage : coverage
  ; elapsed_ns : int64
  ; outcome : outcome
  ; samples : sample list
  }

type access
val cache_access :
  component -> snapshot:Skill_catalog_snapshot.t -> descriptor_count:(unit -> int) ->
  (access -> 'a) -> 'a
val lookup_finished : access -> unit
val lock_acquired : access -> unit
val decided : access -> decision -> unit
(** Marks only sample boundaries. With no capture, no clock or descriptor count
    is read. Lock acquisition includes uncontended overhead; it is not proof of
    contention. Missing marks remain absent. *)

val capture_result : on_report:(report -> unit) -> (unit -> ('a, 'e) result) -> ('a, 'e) result
(** Fiber-owned capture, including nested and parallel accesses. Reports keep
    failed/cancelled and still-open samples; late inherited accesses cannot
    append after closure. Nested captures own their own samples. Non-Eio calls
    explicitly report unobserved coverage. A non-reserved sink failure is logged
    without replacing the operation result; cancellation/reserved exceptions
    propagate. No exception text or document body is included in the report. *)

val report_to_json : report -> Yojson.Safe.t
val outcome_to_string : outcome -> string
