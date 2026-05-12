(** Structured validation for cascade.json preset entries.

    This module lifts the existing static cascade catalog checks out of
    {!Config_doctor} so server routes and other runtime surfaces can
    reject invalid presets before they are assigned to keepers. *)

type severity =
  | Catalog_warn
  | Catalog_error

type issue = {
  profile : string option;
  severity : severity;
  message : string;
}

val discover_profiles : config_path:string -> string list
(** Discover named cascade presets from ["{name}_models"] keys. Returns
    [[]] when the config cannot be loaded. *)

val discover_profiles_for_diagnostics : config_path:string -> string list
(** Diagnostics-only variant of {!discover_profiles}; suppresses TOML
    source-read trace / race telemetry. *)

val diagnose_catalog : config_path:string -> issue list
(** Validate every discovered preset in [config_path].

    - hard-invalid model specs (unknown provider / invalid syntax)
    - unknown strategy names
    - [priority_tier] presets whose tiers collapse structurally

    Provider-unavailable entries are not treated as hard failures here:
    the validator is intended to catch broken catalog structure, not
    environment-specific credential state. *)

val diagnose_catalog_for_diagnostics : config_path:string -> issue list
(** Diagnostics-only variant of {!diagnose_catalog}; suppresses catalog
    validation telemetry and TOML source-read trace / race telemetry. *)

val error_messages_by_profile :
  config_path:string ->
  (string * string list) list
(** Group only [Catalog_error] diagnostics by profile name. Config-wide
    load errors without a concrete profile are omitted from the grouping. *)
