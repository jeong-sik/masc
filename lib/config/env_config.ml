(** MASC Environment Configuration

    Centralized environment variable management following 12-Factor App principles.
    All env vars use MASC_* prefix for consistency.
*)

include Env_config_core
include Env_config_runtime
include Env_config_runtime_services
include Env_config_keeper

(** Compatibility wrapper around the canonical config snapshot categories.
    Keep callers on [Env_config] while root-level wrappers may enrich the same
    read model with additional server metadata. *)
