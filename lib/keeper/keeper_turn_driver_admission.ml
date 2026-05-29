(** Keeper cascade provider candidate mapping utilities.
    Extracted from keeper_turn_driver.ml — sibling pattern (same flat
    masc_mcp library, no sub-library).

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
      cfg.api_key,
      cfg.headers,
      cfg.supports_tool_choice_override )

let runtime_candidates_of_providers tiered_providers provider_cfgs =
  let tier_index = Hashtbl.create (List.length tiered_providers) in
  List.iter
    (fun (tiered : Cascade_catalog_runtime_named_providers.tiered_provider) ->
       let key = provider_config_identity_key tiered.provider_cfg in
       let queue =
         match Hashtbl.find_opt tier_index key with
         | Some queue -> queue
         | None ->
           let queue = Queue.create () in
           Hashtbl.add tier_index key queue;
           queue
       in
       Queue.add tiered.admission_key queue)
    tiered_providers;
  List.map
    (fun provider_cfg ->
       let admission_key =
         match Hashtbl.find_opt tier_index (provider_config_identity_key provider_cfg) with
         | Some queue when not (Queue.is_empty queue) -> Some (Queue.pop queue)
         | _ -> None
       in
        Cascade_runtime_candidate.of_provider_config ?admission_key provider_cfg)
    provider_cfgs

(* ================================================================ *)
(* Facade-only: run_named, run_model_by_label, and MASC tool bridges  *)
(* ================================================================ *)

(** Run a single Agent.run() call with MASC-driven cascade model fallback.

    MASC drives the cascade FSM directly:
    - Resolves cascade providers from cascade.toml
    - For each provider, runs OAS with a single provider
    - Uses Cascade_fsm.decide to determine next action on failure
    - Cascade loop runs inside Admission_queue permit

    @param accept Optional response validator. Default accepts all.
    @since Phase 2 — MASC-driven cascade FSM *)
