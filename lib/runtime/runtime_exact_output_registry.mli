(** Immutable OAS exact-output publication for MASC runtime routing. *)

type t
type publication_error =
  | Registry_not_published
  | Publication_busy
  | Generation_exhausted
  | Replacement_base_changed of
      { expected_generation : int64 option
      ; actual_generation : int64 option
      }
  | Blank_lane_id of { position : int }
  | Duplicate_lane_id of
      { position : int
      ; lane_id : string
      }
  | Empty_lane of { lane_id : string }
  | Blank_lane_slot of
      { lane_id : string
      ; position : int
      }
  | Duplicate_lane_slot of
      { lane_id : string
      ; position : int
      ; slot_id : string
      }
  | Invalid_lane_slot of
      { lane_id : string
      ; position : int
      ; slot_id : string
      ; cause : Agent_sdk.Exact_output.target_ref_error
      }
  | Unknown_lane_slot of
      { lane_id : string
      ; position : int
      ; slot_id : string
      ; target_ref : string
      }

type prepared_replacement
type reservation
type reservation_error = Reservation_inactive

type selected_slot =
  { slot_id : string
  ; target : Agent_sdk.Exact_output.selected_target
  }

type unavailable_slot =
  { position : int
  ; slot_id : string
  ; cause : Agent_sdk.Exact_output.target_selection_error
  }

type resolved_lane =
  { selected_slots : selected_slot list
  ; unavailable_slots : unavailable_slot list
  }

type lane_resolution_error =
  | Exact_lane_unconfigured of { lane_id : string }
  | No_usable_lane_slots of
      { lane_id : string
      ; unavailable_slots : unavailable_slot list
      }

val publish
  :  lanes:Runtime_schema.exact_output_lane_decl list
  -> Agent_sdk.Exact_output.resolver_snapshot
  -> (t, publication_error) result
(** Validate and atomically publish one complete resolver-and-lane registry.
    Each successful publication advances the MASC-local generation
    monotonically. Invalid declarations are rejected before the Atomic is
    changed.

    Every declaration string is converted to an immutable OAS admitted-target
    handle before publication. Credential presence is deliberately excluded
    from publication admission. Config-level errors — blank or duplicate ids,
    malformed or unknown target refs — remain fatal at publish. Returns
    [Publication_busy] while a replacement reservation is active. *)

val prepare_replacement
  :  lanes:Runtime_schema.exact_output_lane_decl list
  -> (prepared_replacement, publication_error) result
(** Purely admit [lanes] against the currently published frozen resolver and
    return an immutable candidate tied to that exact base registry identity.
    This performs no credential resolution, global mutation, or publication
    fence. When no registry exists, only an empty lane set can be prepared. *)

val reserve_replacement
  :  prepared_replacement
  -> (reservation, publication_error) result
(** Atomically verify that the candidate's exact base registry is still
    current, then install its opaque one-shot publication reservation. A stale
    candidate fails with [Replacement_base_changed]; an active reservation
    fails with [Publication_busy]. *)

val finish_replacement : reservation -> (unit, reservation_error) result
(** Consume the active reservation and publish its prepared candidate. An empty
    pre-publication candidate leaves the registry unpublished. *)

val abort_replacement : reservation -> (unit, reservation_error) result
(** Consume the active reservation without changing the published registry. *)

val current : unit -> (t, publication_error) result
(** Return the currently published registry. Returns [Publication_busy] while
    a replacement reservation fences new acquisitions, and
    [Registry_not_published] before bootstrap has published one. *)

val generation : t -> int64

val resolve_lane : t -> lane_id:string -> (resolved_lane, lane_resolution_error) result
(** Resolve one lane exclusively from the immutable admitted handles retained
    by the supplied registry generation. Credential-missing, invalid, and
    read-failed slots are returned as typed unavailable diagnostics in
    declaration order while usable slots retain their relative order. The lane
    fails only when it is unconfigured or no admitted slot is usable. *)

val publication_error_to_string : publication_error -> string
val unavailable_slot_to_string : unavailable_slot -> string
val lane_resolution_error_to_string : lane_resolution_error -> string
val reservation_error_to_string : reservation_error -> string
