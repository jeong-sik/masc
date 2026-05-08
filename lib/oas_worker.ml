(** Oas_worker — Unified entry point for OAS-based MASC tool modules.

    Facade module: re-exports sub-modules for backward compatibility.

    Implementation split into:
    - {!Cascade_legacy_runner} — cascade metrics types, observation, recording
    - {!Oas_worker_exec} — config, build, run, run_with_masc_tools
    - {!Oas_worker_named} — run_named, run_model_by_label, convenience wrappers

    @since God file decomposition *)

(* Oas_worker_exec defines [module Oas = Agent_sdk]; include it first
   so the alias is available for the .mli contract. *)
include Oas_worker_exec
include Cascade_legacy_runner
include Oas_worker_named
