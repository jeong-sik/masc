open Keeper_approval_queue_rules_types

let () =
  Otel_metric_store.register_counter
    ~name:Keeper_metrics.(to_string HitlSummaryOutcomes)
    ~help:
      "Total HITL exact-output flow outcomes classified by [outcome]. MASC \
       records domain and durability outcomes only; provider selection, \
       admission, dispatch, and failover remain AGENT_CORE-owned."
    ()
;;

(** Every terminal disposition of the HITL exact-output flow.

    Closed on purpose. These were 27 string literals spread over 37 call
    sites, so a branch added later could reach the metric — and any consumer
    derived from it — without the compiler asking. A variant makes each
    derivation an exhaustive match, so the next branch stops the build
    until it is classified. The metric label text is unchanged: it is
    derived here rather than restated at each site. *)
type flow_outcome =
  | Ok_summary
  | Ok_summary_cli
  | Source_resolved
  | Identity_unbound
  | Identity_unbound_source_changed
  | Terminal_sync_unconfirmed
  | Terminal_persistence_failure
  | Terminal_rejected
  | Provenance_mismatch
  | Domain_invalid_output
  | Attempt_replay
  | Attempt_start_failed
  | Measurement_start_failed
  | Measurement_callback_failed
  | Candidates_exhausted
  | Bind_failed
  | Release_failed
  | Execution_failed
  | Cli_slots_exhausted
  | Cli_released_without_binding
  | Cli_walk_fell_back
  | Slots_held
  | Cli_release_unconfirmed
  | Cli_bind_unconfirmed
  | Cli_bind_failed
  | Cancellation
  | Cancellation_settlement_failed
  | Crashed

let outcome_label = function
  | Ok_summary -> "ok_summary"
  | Ok_summary_cli -> "ok_summary_cli"
  | Source_resolved -> "exact_source_resolved"
  | Identity_unbound -> "exact_identity_unbound"
  | Identity_unbound_source_changed -> "exact_identity_unbound_source_changed"
  | Terminal_sync_unconfirmed -> "exact_terminal_sync_unconfirmed"
  | Terminal_persistence_failure -> "exact_terminal_persistence_failure"
  | Terminal_rejected -> "exact_terminal_rejected"
  | Provenance_mismatch -> "exact_provenance_mismatch"
  | Domain_invalid_output -> "exact_domain_invalid_output"
  | Attempt_replay -> "exact_attempt_replay"
  | Attempt_start_failed -> "exact_attempt_start_failed"
  | Measurement_start_failed -> "exact_measurement_start_failed"
  | Measurement_callback_failed -> "exact_measurement_callback_failed"
  | Candidates_exhausted -> "exact_candidates_exhausted"
  | Bind_failed -> "exact_bind_failed"
  | Release_failed -> "exact_release_failed"
  | Execution_failed -> "exact_execution_failed"
  | Cli_slots_exhausted -> "exact_cli_slots_exhausted"
  | Cli_released_without_binding -> "exact_cli_released_without_binding"
  | Cli_walk_fell_back -> "exact_cli_walk_fell_back"
  | Slots_held -> "exact_slots_held"
  | Cli_release_unconfirmed -> "exact_cli_release_unconfirmed"
  | Cli_bind_unconfirmed -> "exact_cli_bind_unconfirmed"
  | Cli_bind_failed -> "exact_cli_bind_failed"
  | Cancellation -> "exact_cancellation"
  | Cancellation_settlement_failed -> "exact_cancellation_settlement_failed"
  | Crashed -> "crashed"
;;

(* The branch a flow last took, kept per fiber so concurrent workers cannot
   read each other's. A flow that ends without a judgment summary knows only
   that it produced none; this is how the run registry gets to say which
   branch it was standing on when that happened. Fiber-local rather than a
   parameter because [record_outcome] is called from top-level helpers that
   have no flow value to thread. *)
let outcome_sink_key : flow_outcome option ref Eio.Fiber.key = Eio.Fiber.create_key ()

let with_outcome_sink sink f = Eio.Fiber.with_binding outcome_sink_key sink f

let next_observed_outcome previous outcome =
  if outcome = Source_resolved
     && Option.is_some previous
     && previous <> Some Source_resolved
  then previous
  else Some outcome

let record_outcome outcome =
  (match Eio.Fiber.get outcome_sink_key with
   | Some sink -> sink := next_observed_outcome !sink outcome
   | None -> ());
  Otel_metric_store.inc_counter
    Keeper_metrics.(to_string HitlSummaryOutcomes)
    ~labels:[ "outcome", outcome_label outcome ]
    ()
;;

(* The outcome a finished exact run earns, decided by whether a summary was
   observed. Named rather than inline because both arms are load-bearing: a
   summary reaches [on_summary] only after domain validation, provenance
   verification and fsync (see the .mli). Its absence is a failure unless the
   source resolved without an earlier recorded failure. *)
let run_outcome_of_observed_summary ~last_outcome = function
  | Some summary ->
    Exact_lane_run_registry.Succeeded, hitl_context_summary_to_yojson summary
  | None when last_outcome = Some Source_resolved ->
    (* The approval disappeared or reached another terminal state before this
       attempt could commit a judgment. Earlier failures retain their code in
       [next_observed_outcome]; only a source-resolution-only path reaches here. *)
    Exact_lane_run_registry.Cancelled,
    `Assoc ["reason", `String "source_resolved_without_recorded_judgment";
            "judgment_recorded", `Bool false]
  | None ->
    let code, detail =
      match last_outcome with
      | Some outcome ->
        ( outcome_label outcome
        , Printf.sprintf
            "exact flow terminalized without a judgment summary; the candidate \
             was quarantined on %s"
            (outcome_label outcome) )
      | None ->
        ( "no_branch_recorded"
        , "exact flow terminalized without a judgment summary and without \
           recording a branch" )
    in
    Exact_lane_run_registry.Failed { code; detail }, `Null
;;
