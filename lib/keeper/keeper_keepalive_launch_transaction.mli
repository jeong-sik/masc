(** One authority boundary for Keeper registry admission and its detached
    Librarian lifecycle. Both direct and supervisor launch paths use this
    transaction so neither can publish a lane between registry admission and
    memory-lifecycle ownership. *)

type 'registration_error error =
  | Reservation_unavailable of Keeper_lifecycle_reservation.snapshot
  | Registration_failed of 'registration_error
  | Lifecycle_open_failed of
      { error : Keeper_memory_lane.lifecycle_open_error
      ; rollback_error : string option
      }

val run
  :  ?lifecycle_token:Keeper_lifecycle_reservation.token
  -> base_path:string
  -> keeper_name:string
  -> expected_generation:int
  -> register:
       (Keeper_lifecycle_reservation.token ->
        (Keeper_registry.registry_entry, 'registration_error) result)
  -> rollback:
       (Keeper_lifecycle_reservation.token ->
        Keeper_registry.registry_entry ->
        (unit, string) result)
  -> (Keeper_lifecycle_reservation.token ->
      Keeper_registry.registry_entry ->
      'a)
  -> ('a, 'registration_error error) result
(** Acquire launch ownership unless the caller already owns a lifecycle token,
    commit the supplied registry admission, open the Librarian lifecycle, and
    invoke the launch callback. A failed open runs the exact supplied rollback
    while the same token still owns the key. Borrowed tokens are never released
    here; tokens acquired by this function are always released. *)

val rollback_remove_registered
  :  Keeper_lifecycle_reservation.token
  -> Keeper_registry.registry_entry
  -> (unit, string) result

val rollback_restore_previous
  :  previous:Keeper_registry.registry_entry
  -> Keeper_lifecycle_reservation.token
  -> Keeper_registry.registry_entry
  -> (unit, string) result

val rollback_retain_registered
  :  Keeper_lifecycle_reservation.token
  -> Keeper_registry.registry_entry
  -> (unit, string) result

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
