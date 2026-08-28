(** Per-Keeper ordering preference inside one admitted exact-output lane.

    The runtime registry remains the sole authority for which lanes and slots
    exist. This store may only move one already-admitted slot to the front for
    one exact [(base_path, keeper_name, lane_id)] owner; it cannot add a model,
    remove failover candidates, or bypass bootstrap admission.

    A preference is lane-scoped because the same Keeper may legitimately use
    different first choices for HITL judgment, Board attention, and Librarian
    selection. *)

type t =
  { keeper_name : string
  ; lane_id : string
  ; slot_id : string
  ; actor : string
  ; changed_at : string
  }

val path : base_path:string -> string
(** Producer-owned canonical store path. *)

val all : base_path:string -> (t list, string) result
(** Every explicit preference in stored order. An unreadable file is an error,
    never an empty working configuration. Duplicate [(keeper_name, lane_id)]
    owners are rejected. *)

val find
  :  base_path:string
  -> keeper_name:string
  -> lane_id:string
  -> (t option, string) result

val prefer
  :  slots:'slot list
  -> slot_id_of:('slot -> string)
  -> preferred:string
  -> ('slot list, string) result
(** Move [preferred] to the front and preserve every other slot's declaration
    order. Refuses a slot the admitted lane does not offer. *)

val apply
  :  base_path:string
  -> keeper_name:string
  -> lane_id:string
  -> Runtime_exact_output_registry.resolved_lane
  -> (Runtime_exact_output_registry.resolved_lane, string) result
(** Apply the exact owner's stored preference to an already-resolved admitted
    lane. No preference returns the lane unchanged. *)

val validate_admitted_slot : lane_id:string -> slot_id:string -> (unit, string) result
(** Refuse an operator choice that the currently published lane does not
    admit. This is an authoring-time check; {!apply} repeats the check at the
    execution boundary against the current immutable registry. *)

val set
  :  Workspace.config
  -> actor:string
  -> keeper_name:string
  -> lane_id:string
  -> string option
  -> (t option, string) result
(** Set or clear one exact owner. Returns the canonical stored row. *)
