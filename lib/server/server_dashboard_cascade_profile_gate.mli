(** Dashboard cascade profile gate — determines which cascade
    profiles are assignable to a keeper.

    Pure derivation pipeline over [Cascade_catalog_runtime] (preferred)
    + [Cascade_catalog_validator] (fallback on snapshot unavailability)
    + [Keeper_cascade_profile.keeper_catalog_names] (keeper-assignable
    filter). *)

(** Result of one gate computation:
    - [valid_profiles]: assignable profile names;
    - [invalid_profiles]: profile → error message list (config /
      validator-level errors);
    - [invalid_assignments]: profile → reason list (public profile
      that resolves to an invalid internal profile). *)
type t = {
  valid_profiles : string list;
  invalid_profiles : (string * string list) list;
  invalid_assignments : (string * string list) list;
}

(** [compute ()] runs the gate end-to-end and returns the
    classification for the current cascade config. Reads the runtime
    snapshot first; falls back to the on-disk validator when the
    snapshot is in an error state (logs a WARN line in that case). *)
val compute : unit -> t

(** [available_profiles ()] is [(compute ()).valid_profiles]. *)
val available_profiles : unit -> string list

(** [invalid_profiles ()] is [(compute ()).invalid_profiles]. *)
val invalid_profiles : unit -> (string * string list) list

(** [invalid_assignment_profiles ()] is
    [(compute ()).invalid_assignments]. *)
val invalid_assignment_profiles : unit -> (string * string list) list
