(** Keeper cascade tier admission helpers + provider candidate identity,
    extracted from keeper_turn_driver.ml — sibling pattern (same flat
    masc_mcp library, no sub-library).

    Used by the keeper turn driver's [run_named] entry to gate cascade
    attempts via [Cascade_tier_admission] and to map tiered providers
    to runtime candidates with deterministic tier ids. *)

open Result.Syntax

let keeper_cascade_tier_admission = Cascade_tier_admission.create ()

let keeper_cascade_wait_scheduler =
  Cascade_tier_wait_scheduler.create keeper_cascade_tier_admission

let cascade_tier_admission_policy_of_priority priority =
  (* RFC-0126: exhaustive typed match over Llm_provider.Request_priority.t
     instead of the previous string-classifier (`to_string |> match`) so that
     future variants in the upstream agent_sdk surface as a compile error
     here rather than silently routing through a permissive default.
     Semantics: only [Background] (P2 heartbeat / status ticks) bypasses
     tier admission per Cascade_tier_admission.mli side-task starvation
     defence; main-path priorities all require admission.  [Unspecified]
     is unreachable after [resolve] (it maps to [Proactive]) but the arm
     keeps the match exhaustive without a catch-all. *)
  match Llm_provider.Request_priority.resolve priority with
  | Background -> Cascade_tier_admission.Bypass
  | Resume | Interactive | Proactive | Unspecified ->
      Cascade_tier_admission.Required

let with_keeper_cascade_tier_admission
    ?(admission = keeper_cascade_tier_admission)
    ?(wait_scheduler = keeper_cascade_wait_scheduler)
    ?(enabled = Env_config_keeper.CascadeTierAdmission.enabled ())
    ?sw
    ~tier_id
    ~admission_policy
    f =
  if not enabled then
    Ok (f ())
  else begin
    match admission_policy with
    | Cascade_tier_admission.Bypass ->
        (* Side tasks skip admission entirely *)
        Ok (f ())
    | Cascade_tier_admission.Required ->
        let wait_enabled =
          Env_config_keeper.CascadeTierWait.enabled ()
        in
        if wait_enabled then begin
          match sw with
          | None ->
              (* No switch available — wait scheduler requires one for
                 fork_daemon.  Fall back to non-blocking admission. *)
              Cascade_tier_admission.with_admission admission
                ~tier_id ~admission_policy f
          | Some sw ->
              (* Phase C.2: bounded wait with backoff *)
              let wait_config =
                { Cascade_tier_wait_scheduler.backoff =
                    Cascade_tier_wait_scheduler.Exponential
                      { initial_s = 0.5; factor = 2.0; max_s = 8.0 };
                  timeout_s =
                    Env_config_keeper.CascadeTierWait.timeout_s ();
                  max_retries =
                    Env_config_keeper.CascadeTierWait.max_retries ();
                }
              in
              (match Cascade_tier_wait_scheduler.try_admission_or_wait
                       wait_scheduler ~tier_id ~wait_config ~sw f with
               | Ok v -> Ok v
               | Error (Cascade_tier_wait_scheduler.Timeout_expired _
                       | Cascade_tier_wait_scheduler.Max_retries_exceeded _) ->
                   Error (Cascade_saturation_signal.Inflight_capacity_full
                            { tier_id;
                              max_inflight =
                                Cascade_tier_admission.configured_max admission
                                  ~tier_id })
               | Error (Cascade_tier_wait_scheduler.Cancelled _) ->
                   Error (Cascade_saturation_signal.Inflight_capacity_full
                            { tier_id;
                              max_inflight =
                                Cascade_tier_admission.configured_max admission
                                  ~tier_id }))
        end
        else
          (* Phase B.2: non-blocking admission *)
          Cascade_tier_admission.with_admission admission ~tier_id
            ~admission_policy f
  end

let cascade_tier_admission_blocked_decision signal =
  `Assoc
    [
      ("blocker", `String "cascade_tier_admission_full");
      ("signal", Cascade_saturation_signal.to_yojson signal);
    ]

let emit_cascade_tier_admission_signal_metric ~cascade_name signal =
  Prometheus.inc_counter
    Keeper_metrics.(to_string CascadeSaturationSignal)
    ~labels:
      [
        ( Cascade_attempt_fsm.label_kind,
          Cascade_saturation_signal.(kind signal |> kind_to_string) );
        ( Cascade_attempt_fsm.label_cascade,
          Cascade_attempt_fsm.provider_label cascade_name );
      ]
    ()

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

let runtime_candidates_of_tiered_providers tiered_providers provider_cfgs =
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
       Queue.add tiered.tier_id queue)
    tiered_providers;
  List.map
    (fun provider_cfg ->
       let tier_id =
         match Hashtbl.find_opt tier_index (provider_config_identity_key provider_cfg) with
         | Some queue when not (Queue.is_empty queue) -> Some (Queue.pop queue)
         | _ -> None
       in
        Cascade_runtime_candidate.of_provider_config ?tier_id provider_cfg)
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
