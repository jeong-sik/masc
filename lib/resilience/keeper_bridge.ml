(* Resilience keeper_bridge — Cycle 23 / Tier A6.
   Wires Recovery classifier into the keeper post-turn lifecycle for
   classification, optional callback-driven strategy execution, and
   audit-envelope emission. The bridge never fabricates keeper actions:
   callers must supply concrete Retry/Fallback/Handoff/Abort callbacks
   before Recovery.execute_strategy can mutate anything.
   See keeper_bridge.mli for design rationale. *)

(* ── Pure helpers ─────────────────────────────────────────────── *)

let masc_resilience_enabled () =
  match Sys.getenv_opt "MASC_RESILIENCE" with
  | Some ("1" | "true" | "yes" | "on") -> true
  | _ -> false

let upsert_resilience_meta
    (working_context : Yojson.Safe.t option)
    (resilience_meta : Yojson.Safe.t) : Yojson.Safe.t option =
  let updated_kv =
    match working_context with
    | None -> [ ("resilience_meta", resilience_meta) ]
    | Some (`Assoc kv) ->
        let kv_without =
          List.filter (fun (k, _) -> k <> "resilience_meta") kv
        in
        ("resilience_meta", resilience_meta) :: kv_without
    | Some _ ->
        (* Conservative: the caller passed a non-[`Assoc] working
           context. Wrap under our key so downstream consumers see
           a usable [`Assoc] without us silently overwriting the
           unexpected payload. *)
        [ ("resilience_meta", resilience_meta) ]
  in
  Some (`Assoc updated_kv)

(* ── Phantom witness ──────────────────────────────────────────── *)

type running_valid_for_resilience = Resilience_witness

let running_witness = Resilience_witness

(* ── Classification helpers ───────────────────────────────────── *)

type strategy_execution =
  | Strategy_execution_not_configured
  | Strategy_execution_completed of Recovery.execution_outcome
  | Strategy_execution_failed of string

type apply_outcome = {
  working_context : Yojson.Safe.t option;
  resilience_meta : Yojson.Safe.t option;
  audit_envelope_id : string option;
  strategy_execution : strategy_execution option;
}

let strategy_class_of_strategy : type a. a Recovery.strategy -> string =
  function
  | Recovery.Retry _ -> "Retry"
  | Recovery.Fallback _ -> "Fallback"
  | Recovery.Handoff _ -> "Handoff"
  | Recovery.Abort _ -> "Abort"

let error_mode_kind (mode : Recovery.error_mode) : string =
  match mode with
  | Recovery.TransientError _ -> "Transient"
  | Recovery.PermanentError _ -> "Permanent"
  | Recovery.ResourceExhausted _ -> "ResourceExhausted"
  | Recovery.AmbiguityError _ -> "Ambiguity"
  | Recovery.ConsensusError _ -> "Consensus"
  | Recovery.DegradationRequired _ -> "DegradationRequired"

let execution_outcome_to_json
    (outcome : Recovery.execution_outcome) : Yojson.Safe.t =
  match outcome with
  | Recovery.RetrySucceeded { attempts } ->
      `Assoc [ ("outcome", `String "retry_succeeded"); ("attempts", `Int attempts) ]
  | Recovery.RetryExhausted { attempts; last_error } ->
      `Assoc
        [
          ("outcome", `String "retry_exhausted");
          ("attempts", `Int attempts);
          ( "last_error",
            match last_error with
            | None -> `Null
            | Some error -> `String error );
        ]
  | Recovery.RetryFatal { attempt; error } ->
      `Assoc
        [
          ("outcome", `String "retry_fatal");
          ("attempt", `Int attempt);
          ("error", `String error);
        ]
  | Recovery.FallbackApplied { value; confidence_delta } ->
      `Assoc
        [
          ("outcome", `String "fallback_applied");
          ("value", `String value);
          ("confidence_delta", `Float confidence_delta);
        ]
  | Recovery.HandoffRequested { message; preserve_state } ->
      `Assoc
        [
          ("outcome", `String "handoff_requested");
          ("message", `String message);
          ("preserve_state", `Bool preserve_state);
        ]
  | Recovery.Aborted { reason } ->
      `Assoc [ ("outcome", `String "aborted"); ("reason", `String reason) ]

let strategy_execution_to_json = function
  | Strategy_execution_not_configured ->
      `Assoc [ ("status", `String "not_configured") ]
  | Strategy_execution_completed outcome ->
      `Assoc
        [
          ("status", `String "completed");
          ("result", execution_outcome_to_json outcome);
        ]
  | Strategy_execution_failed error ->
      `Assoc [ ("status", `String "failed"); ("error", `String error) ]

let execute_strategy_if_configured strategy_executor strategy =
  match strategy_executor with
  | None -> Strategy_execution_not_configured
  | Some executor -> (
      match Recovery.execute_strategy executor strategy with
      | Ok outcome -> Strategy_execution_completed outcome
      | Error error -> Strategy_execution_failed error)

(* ── Main pipeline ────────────────────────────────────────────── *)

let apply_post_turn_resilience
    (_witness : running_valid_for_resilience)
    ?audit_store
    ?strategy_executor
    ~(now : float)
    ~(working_context : Yojson.Safe.t option)
    ~(maybe_error : string option)
    () : apply_outcome =
  match maybe_error with
  | None ->
      (* Inert pass-through: no error to classify. *)
      {
        working_context;
        resilience_meta = None;
        audit_envelope_id = None;
        strategy_execution = None;
      }
  | Some err ->
      let mode = Recovery.classify_string err in
      let kind = error_mode_kind mode in
      let strategy = Recovery.default_strategy mode in
      let strategy_class = strategy_class_of_strategy strategy in
      let strategy_execution =
        execute_strategy_if_configured strategy_executor strategy
      in
      let strategy_execution_json =
        strategy_execution_to_json strategy_execution
      in
      let envelope_id =
        match audit_store with
        | None -> None
        | Some store ->
            let payload =
              `Assoc
                [
                  ("error_kind", `String kind);
                  ("strategy_class", `String strategy_class);
                  ("strategy_execution", strategy_execution_json);
                  ("error_detail", `String err);
                  ("now", `Float now);
                ]
            in
            let envelope =
              Shared_audit.Store.append store
                ~category:"RecoveryAttempted" ~payload
            in
            Some envelope.Shared_audit.Envelope.id
      in
      let resilience_meta =
        `Assoc
          [
            ("classified_kind", `String kind);
            ("default_strategy_class", `String strategy_class);
            ("strategy_execution", strategy_execution_json);
            ("classified_at", `Float now);
            ( "audit_envelope_id",
              match envelope_id with
              | None -> `Null
              | Some s -> `String s );
          ]
      in
      let new_wc = upsert_resilience_meta working_context resilience_meta in
      {
        working_context = new_wc;
        resilience_meta = Some resilience_meta;
        audit_envelope_id = envelope_id;
        strategy_execution = Some strategy_execution;
      }
