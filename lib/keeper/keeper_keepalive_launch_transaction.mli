(** One authority boundary for Keeper registry admission. Both direct and
    supervisor launch paths use this transaction so neither can publish a lane
    before the registry admission that owns it, and so both submit the
    Librarian's durable catch-up the same way. The Librarian lane itself is
    the server's (RFC librarian-lifecycle section 4.3): admission does not
    open, fence or join it. *)

type 'registration_error error =
  | Shutdown_reserved of Keeper_shutdown_types.Operation_id.t
  | Intake_token_not_live
  | Reservation_unavailable of Keeper_lifecycle_reservation.snapshot
  | Registration_failed of 'registration_error
  | Launch_failed of
      { exception_detail : string
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
(** Own durable intake across registry admission, durable catch-up
    submission, and the launch callback. A caller that already owns intake may
    lend its exact token; otherwise this transaction acquires one and fails
    closed when shutdown owns admission.

    Acquire launch ownership unless the caller already owns a lifecycle token,
    then commit the supplied registry admission. The launch callback receives
    the active intake token so nested durable mutations remain inside the
    same intake epoch instead of reacquiring its non-reentrant lock.

    A launch exception rolls back only while the lane can still be atomically
    rejected before start. Once the lane has started, its registry entry is
    retained for the lane's terminal cleanup rather than detached by rollback.
    Cancellation follows the same protected cleanup decision and is re-raised.
    Borrowed lifecycle tokens are never released here; lifecycle tokens
    acquired by this function are always released outside cancellation. *)

val finish_lifecycle
  :  terminalize:(unit -> (unit, string) result)
  -> (unit, string) result
(** Publish a Keeper's terminal state under cancellation protection. Exit
    settlement usually runs after the lane has observed cancellation, and the
    publication must not be cut short by it. The Librarian lane is not
    drained, joined or cancelled here: it is the server's (RFC
    librarian-lifecycle section 4.3, I7). *)
