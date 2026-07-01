(** MASC Environment Configuration — facade.

    Centralized environment-variable management following 12-Factor
    App principles. All env vars use the [MASC_*] prefix.

    Re-exports the public surface of {!Env_config_core},
    {!Env_config_runtime}, {!Env_config_governance}, and
    {!Env_config_keeper} so callers can [Env_config.<symbol>] without
    knowing which sub-module owns each knob. The interface uses
    [include module type of] so the facade auto-tracks the underlying
    modules without manual maintenance.

    Underlying modules currently have no [.mli] of their own; the
    inferred surface is what propagates here. When narrower [.mli]
    files land for those modules, this facade automatically picks up
    the tightened contract. *)

include module type of Env_config_core
include module type of Env_config_runtime
include module type of Env_config_governance
include module type of Env_config_hitl
include module type of Env_config_keeper

