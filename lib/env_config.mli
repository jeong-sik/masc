(** MASC Environment Configuration

    Centralized environment variable management following 12-Factor App principles.
    All env vars use MASC_* prefix for consistency.

    This module re-exports Env_config_core, Env_config_runtime,
    Env_config_governance, and Env_config_keeper. *)

include module type of Env_config_core
include module type of Env_config_runtime
include module type of Env_config_governance
include module type of Env_config_keeper

(** Print configuration summary for debugging. *)
val print_summary : unit -> unit

(** Serialize all known configuration as JSON for dashboard introspection. *)
val to_json : unit -> Yojson.Safe.t
