(** Immutable AGENT_CORE exact-output publication for MASC runtime routing. *)

type t
type publication_error =
  | Registry_not_published
  | Publication_busy
  | Replacement_base_changed
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
      ; cause : Agent_core.Exact_output.target_ref_error
      }
  | Required_lane_unavailable of { lane_id : string }

type rejected_slot =
  { lane_id : string
  ; position : int
  ; slot_id : string
  ; target_ref : string
  }

type rejected_slot_diagnosis =
  | Retired_catalog_target
      (** The id is neither an exact-output target nor a configured runtime:
          the catalog moved on and runtime.toml did not. *)
  | Configured_runtime_id of
      { provider_id : string
      ; api_name : string
      }
      (** The id names a runtime.toml runtime. Exact lanes resolve overlay
          [[targets]] ids only, so the slot can never be admitted; the
          operator wrote a keeper-turn id where a catalog target id belongs. *)

type prepared_replacement

type ('not_committed, 'committed) replacement_effect =
  | Not_committed of 'not_committed
  | Committed of 'committed

type selected_slot =
  { slot_id : string
  ; admitted_target : Agent_core.Exact_output.admitted_target
  }

type resolved_lane =
  { selected_slots : selected_slot list
  ; cli_slots : string list
        (** Official-client runtime ids the lane walks as one-shot fallbacks
            after every catalog slot is exhausted, in declaration order.
            Carried verbatim from [cli_slots]; whether an id resolves to a
            live official-client runtime is answered at execution with a
            typed error, and a lane with only cli slots is still resolvable
            (RFC cli-runtimes-as-lane-slots). *)
  }

type lane_resolution_error =
  | Exact_lane_unconfigured of { lane_id : string }
  | No_admitted_lane_slots of { lane_id : string }

val publish
  :  ?required_lane_ids:string list
  -> lanes:Runtime_schema.exact_output_lane_decl list
  -> Agent_core.Exact_output.resolver_snapshot
  -> (t, publication_error) result
(** Validate and atomically publish one complete resolver-and-lane registry.
    Invalid declarations are rejected before the Atomic is changed.

    Every declaration string present in the frozen catalog is converted to an
    immutable AGENT_CORE admitted-target handle before publication. Credential
    presence is deliberately excluded from publication admission. Unknown
    catalog targets are retained as typed [rejected_slot] observations and do
    not suppress admitted siblings. Blank or duplicate ids and malformed target
    refs remain fatal. A required lane must retain at least one admitted slot.
    Returns [Publication_busy] while a replacement reservation is active. *)

val prepare_replacement
  :  lanes:Runtime_schema.exact_output_lane_decl list
  -> (prepared_replacement, publication_error) result
(** Purely admit [lanes] against the currently published frozen resolver and
    return an immutable candidate tied to that exact base registry identity.
    This performs no credential resolution, global mutation, or publication
    fence. When no registry exists, only an empty lane set can be prepared. *)

val transact_replacement
  :  prepared_replacement
  -> apply_write:(unit -> ('not_committed, 'committed) replacement_effect)
  -> (('not_committed, 'committed) replacement_effect, publication_error) result
(** Reserve the candidate's exact base, run [apply_write] outside the publication
    mutex while all acquisitions observe [Publication_busy], then close the
    private reservation. [Not_committed] preserves the published registry;
    [Committed] publishes the immutable candidate exactly once. The opaque
    reservation never escapes to [apply_write], so it cannot be finished or aborted
    by another caller. An exception clears the fence and is re-raised with its
    original backtrace; effects that made an external commit visible must
    therefore return [Committed] rather than raise. *)

val current : unit -> (t, publication_error) result
(** Return the currently published registry. Returns [Publication_busy] while
    a replacement reservation fences new acquisitions, and
    [Registry_not_published] before bootstrap has published one. *)

val rejected_slots : t -> rejected_slot list

val diagnose_rejected_slot
  :  rejected_slot
  -> configured_runtime:(string -> (string * string) option)
  -> rejected_slot_diagnosis
(** Why a slot was rejected, for the boot report. [configured_runtime] answers
    with the runtime's [(provider_id, api_name)] when the slot id is a
    runtime.toml runtime; the caller supplies it because this module sits
    below [Runtime]. Pure. *)

val catalog_absent_assignments :
  Agent_core.Exact_output.resolver_snapshot ->
  assignments:(string * string) list ->
  (string * string) list
(** Keeper assignments (from [[runtime.assignments]]) whose target is absent
    from the frozen model catalog. Unlike a rejected lane slot this changes
    no admission — the assignment silently stops resolving and the keeper
    falls back to the default runtime — so callers must report it rather than
    let it degrade quietly. Pure. *)

val resolve_lane : t -> lane_id:string -> (resolved_lane, lane_resolution_error) result
(** Acquire one lane exclusively from the immutable admitted handles retained
    by the supplied registry. This does not resolve credentials or
    select provider targets; AGENT_CORE owns those operations while executing the
    exact flow. Slot declaration order is preserved. *)

val publication_error_to_string : publication_error -> string
val lane_resolution_error_to_string : lane_resolution_error -> string

module For_testing : sig
  type reservation
  type reservation_error = Reservation_inactive

  val reserve_replacement
    :  prepared_replacement
    -> (reservation, publication_error) result

  val finish_replacement : reservation -> (unit, reservation_error) result
  val abort_replacement : reservation -> (unit, reservation_error) result
  val reservation_error_to_string : reservation_error -> string
end
