(** Keeper runtime provider candidate mapping utilities.
    Extracted from keeper_turn_driver.ml — sibling pattern (same flat
    masc library, no sub-library).

    Used by the keeper turn driver's [run_named] entry to map providers
    to runtime candidates with deterministic admission keys. *)

(* ================================================================ *)
(* Facade-only: run_named, run_model_by_label, and MASC tool bridges  *)
(* ================================================================ *)

(** Run a single Agent.run() call with MASC-driven runtime model fallback.

    MASC drives the runtime FSM directly:
    - Resolves runtime providers from runtime.toml
    - For each provider, runs OAS with a single provider
    - Uses Runtime_fsm.decide to determine next action on failure

    @param accept Optional response validator. Default accepts all.
    @since Phase 2 — MASC-driven runtime FSM *)
