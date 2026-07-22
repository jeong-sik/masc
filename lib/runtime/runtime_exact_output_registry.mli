(** Immutable OAS exact-output publication for MASC runtime routing. *)

type t
type publication_error =
  | Registry_not_published
  | Publication_busy
  | Generation_exhausted
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

type lane_lookup_error = Exact_lane_unconfigured of { lane_id : string }

type slot_resolution_error =
  | Blank_slot_id of { position : int }
  | Duplicate_slot_id of
      { position : int
      ; slot_id : string
      }
  | Invalid_slot_id of
      { position : int
      ; slot_id : string
      ; cause : Agent_sdk.Exact_output.target_ref_error
      }
  | Slot_target_unavailable of
      { position : int
      ; slot_id : string
      ; cause : Agent_sdk.Exact_output.target_selection_error
      }

type reservation
type reservation_error = Reservation_inactive

type selected_slot =
  { slot_id : string
  ; target : Agent_sdk.Exact_output.selected_target
  }

val publish
  :  lanes:Runtime_schema.exact_output_lane_decl list
  -> Agent_sdk.Exact_output.resolver_snapshot
  -> (t, publication_error) result
(** Validate and atomically publish one complete resolver-and-lane registry.
    Each successful publication advances the MASC-local generation
    monotonically. Invalid declarations are rejected before the Atomic is
    changed.

    Credential presence is deliberately excluded from publication admission.
    {!resolve_slots} performs target resolution against the same frozen resolver
    snapshot when execution selects slots. Config-level errors — blank or
    duplicate ids, malformed or unknown target refs — remain fatal at
    publish. Returns [Publication_busy] while a replacement reservation is
    active. *)

val prepare_replacement
  :  lanes:Runtime_schema.exact_output_lane_decl list
  -> (reservation, publication_error) result
(** Validate [lanes], reserve the next generation, and install one opaque
    one-shot publication reservation. When no registry exists, only an empty
    lane set may be reserved; its candidate remains unpublished while fencing
    a concurrent first publication. *)

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

val lane_slots : t -> lane_id:string -> (string list, lane_lookup_error) result
(** Return one lane's opaque target refs in declaration order from exactly the
    supplied registry generation. *)

val resolve_slots : t -> string list -> (selected_slot, slot_resolution_error) result list
(** Resolve an ordered set of opaque slot ids against exactly the supplied
    registry generation. Every input slot produces one outcome in declaration
    order, so a selection failure cannot erase later failover candidates. *)

val publication_error_to_string : publication_error -> string
val lane_lookup_error_to_string : lane_lookup_error -> string
val slot_resolution_error_to_string : slot_resolution_error -> string
val reservation_error_to_string : reservation_error -> string
