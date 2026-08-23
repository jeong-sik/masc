(** One authority boundary for Keeper registry admission and its detached
    Librarian lifecycle. Both direct and supervisor launch paths use this
    transaction so neither can publish a lane between registry admission and
    memory-lifecycle ownership. *)

type 'registration_error error =
  | Shutdown_reserved of Keeper_shutdown_types.Operation_id.t
  | Intake_token_not_live
  | Reservation_unavailable of Keeper_lifecycle_reservation.snapshot
  | Registration_failed of 'registration_error
  | Lifecycle_open_failed of
      { error : Keeper_memory_lane.lifecycle_open_error
      ; rollback_error : string option
      }
  | Launch_failed of
      { exception_detail : string
      ; librarian_abort_error : string option
      ; rollback_error : string option
      }

type rollback =
  | Remove_registered
  | Restore_previous of Keeper_registry.registry_entry
  | Retain_registered

val run
  :  ?lifecycle_token:Keeper_lifecycle_reservation.token
  -> ?intake_token:Keeper_shutdown_intake_fence.intake_token
  -> base_path:string
  -> keeper_name:string
  -> register:
       (Keeper_lifecycle_reservation.token ->
        Keeper_shutdown_intake_fence.intake_token ->
        (Keeper_registry.registry_entry, 'registration_error) result)
  -> rollback:rollback
  -> (Keeper_shutdown_intake_fence.intake_token ->
      Keeper_lifecycle_reservation.token ->
      Keeper_registry.registry_entry ->
      'a)
  -> ('a, 'registration_error error) result
(** Own durable intake across registry admission, Librarian lifecycle open, and
    the launch callback. A caller that already owns intake may lend its exact
    token; otherwise this transaction acquires one and fails closed when
    shutdown owns admission.

    Acquire launch ownership unless the caller already owns a lifecycle token,
    then commit the supplied registry admission. A failed lifecycle open runs
    the exact supplied rollback while the same tokens still own the key.
    The launch callback receives the active intake token so nested durable
    mutations remain inside the same intake epoch instead of reacquiring its
    non-reentrant lock.

    A launch exception rolls back only while the lane can still be atomically
    rejected before start. Once the lane has started, its registry and
    Librarian ownership are retained for the lane's terminal cleanup rather
    than detached by rollback. Cancellation follows the same protected
    cleanup decision and is re-raised. Borrowed lifecycle tokens are never
    released here; lifecycle tokens acquired by this function are always
    released outside cancellation. *)

type exit_boundary =
  | Graceful
  | Unexpected

val finish_lifecycle
  :  boundary:exit_boundary
  -> base_path:string
  -> keeper_name:string
  -> terminalize:(unit -> (unit, string) result)
  -> (unit, string) result
(** Apply the shared terminal ordering. Graceful exits drain accepted
    Librarian work before terminal publication. Unexpected exits publish their
    terminal state first, then fence and request cancellation without joining
    root-scoped provider work. *)
