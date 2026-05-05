(* Resilience keeper_bridge — Cycle 23 / Tier A6.
   Wires Recovery classifier into the keeper post-turn lifecycle for
   classification + audit-envelope emission only; strategy execution
   (Retry/Fallback/Handoff/Abort) is intentionally deferred — see
   resilience_runtime.mli §Deferred and
   docs/audit-responses/2026-05-05-dashboard-heuristic.md §4.
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

type apply_outcome = {
  working_context : Yojson.Safe.t option;
  resilience_meta : Yojson.Safe.t option;
  audit_envelope_id : string option;
}

let strategy_class_of_mode (mode : Recovery.error_mode) : string =
  match Recovery.default_strategy mode with
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

(* ── Main pipeline ────────────────────────────────────────────── *)

let apply_post_turn_resilience
    (_witness : running_valid_for_resilience)
    ?audit_store
    ~(now : float)
    ~(working_context : Yojson.Safe.t option)
    ~(maybe_error : string option)
    () : apply_outcome =
  match maybe_error with
  | None ->
      (* Inert pass-through: no error to classify. *)
      { working_context; resilience_meta = None; audit_envelope_id = None }
  | Some err ->
      let mode = Recovery.classify_string err in
      let kind = error_mode_kind mode in
      let strategy_class = strategy_class_of_mode mode in
      let envelope_id =
        match audit_store with
        | None -> None
        | Some store ->
            let payload =
              `Assoc
                [
                  ("error_kind", `String kind);
                  ("strategy_class", `String strategy_class);
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
      }
