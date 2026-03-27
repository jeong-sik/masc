(** MASC Environment Configuration

    Centralized environment variable management following 12-Factor App principles.
    All env vars use MASC_* prefix for consistency.

    This module re-exports Env_config_core, Env_config_runtime,
    Env_config_governance, and Env_config_keeper. *)

include module type of Env_config_core
include module type of Env_config_runtime
include module type of Env_config_governance
include module type of Env_config_keeper

module Server : module type of Env_config_server
(** Server, transport, and storage configuration. *)

module Chain : module type of Env_config_chain
(** Chain engine, model selection, and inference routing. *)

module Dashboard : module type of Env_config_dashboard
(** Dashboard, operator, and alerting configuration. *)

val print_summary : unit -> unit
(** Print configuration summary for debugging. *)

val to_json : unit -> Yojson.Safe.t
(** Serialize all known configuration as JSON for dashboard introspection.
    Sensitive values (passwords, tokens, API keys) are masked. *)
