(** Keeper_profile_load_failure_site — closed sum for the [site] label on
    [metric_keeper_profile_load_failures].

    Replaces 7 hardcoded literals scattered across 7 emit sites in
    [keeper_types_profile.ml].  Each `site` corresponds to a distinct
    failure path in the persona/profile loading pipeline. *)

type t =
  | Personas_root (** Could not enumerate the personas root directory. *)
  | Personas_dirs_resolve (** Failed to resolve one or more configured personas dirs. *)
  | Toml_discovery_error (** Discovery retained an unreadable / invalid TOML entry. *)
  | Materializable_check (** Runtime materialization probe failed and blocked admission. *)
  | Load_persona_extended (** Extended persona body failed to load. *)
  | Agent_md_read (** AGENT.md sidecar read failed. *)
  | List_persona_summaries (** Building the persona-summary listing raised an error. *)

val to_label : t -> string
