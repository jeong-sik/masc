(** Keeper_profile_load_failure_site — closed sum for the [site] label on
    [metric_keeper_profile_load_failures].

    Replaces 7 hardcoded literals scattered across 7 emit sites in
    [keeper_types_profile.ml].  Each `site` corresponds to a distinct
    failure path in Keeper configuration loading. *)

type t =
  | Toml_discovery_error (** Discovery retained an unreadable / invalid TOML entry. *)
  | Materializable_check (** Runtime materialization probe failed and blocked admission. *)

val to_label : t -> string
