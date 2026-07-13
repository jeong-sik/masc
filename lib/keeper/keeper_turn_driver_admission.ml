(** Keeper runtime provider candidate mapping utilities.
    Extracted from keeper_turn_driver.ml — sibling pattern (same flat
    masc library, no sub-library).

    Used by the keeper turn driver's [run_named] entry to map providers
    to runtime candidates with deterministic admission keys. *)

let release_client_capacity_quietly = function
  | None -> ()
  | Some release ->
      (match release () with
       | () -> ()
       | exception _ -> ())

let provider_config_identity_key (cfg : Llm_provider.Provider_config.t) =
  Hashtbl.hash
    ( Llm_provider.Provider_config.string_of_provider_kind cfg.kind,
      cfg.model_id,
      cfg.base_url,
      cfg.request_path,
      Llm_provider.Secret.header_value cfg.api_key,
      cfg.headers,
      cfg.supports_tool_choice_override )

let runtime_candidates_of_providers provider_cfgs =
  Runtime_candidate.of_provider_configs provider_cfgs

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
