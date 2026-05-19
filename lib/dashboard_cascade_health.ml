(** Cascade health provider serializers.

    Pure conversions between [Cascade_health_tracker.provider_info]
    snapshots and dashboard JSON.  No I/O.  The aggregator-driven
    [health_json] surface lives in {!Dashboard_cascade_health_json}. *)

module Health = Cascade_health_tracker

(** Classify a provider's operational state for dashboard rendering.

    - [cooldown]: tracker opened a cooldown window.
    - [active]: events arrived in the current window and the tracker is
      not cooled down.
    - [configured]: declared in [cascade.toml] but has not produced
      tracker events in the current window (either untouched since
      startup, or expired from the window). The UI uses this to tell
      "declared-but-never-called" apart from the normal healthy case.

    A future [disabled] state (e.g. missing API key, registry drop)
    would live here too, but currently we have no per-provider health
    tracker entry for that condition. *)
let provider_status (info : Health.provider_info) : string =
  if info.in_cooldown
  then "cooldown"
  else if info.events_in_window > 0
  then "active"
  else "configured"
;;

(** Synthesise a provider_info with optimistic defaults for a
    cascade-declared provider that has not been observed by the tracker
    in the current window.  [success_rate = 1.0] mirrors
    [Cascade_health_tracker]'s "unknown = optimistic" convention. *)
let zero_provider_info (key : string) : Health.provider_info =
  { provider_key = key
  ; success_rate = 1.0
  ; consecutive_failures = 0
  ; in_cooldown = false
  ; cooldown_expires_at = None
  ; events_in_window = 0
  ; rejected_in_window = 0
  ; top_fingerprints = []
  ; last_failure_at = None
  ; p50_latency_ms = None
  ; p95_latency_ms = None
  ; latency_samples = 0
  ; avg_confidence = None
  ; confidence_samples = 0
  ; avg_cost_usd = None
  ; cost_samples = 0
  ; health_score = 1.0
  }
;;

(** [provider_entry_to_json ~declared info] serialises a provider_info
    together with two derived fields:

    - [declared : bool]  — [true] iff any [cascade.toml] profile lists a
      model whose scheme prefix matches [info.provider_key].  Lets the
      UI distinguish "still referenced in config" from "left over in the
      tracker after a config change".
    - [status : string] — see {!provider_status}.

    Existing callers (tests, UI) read the previous 7 behavioural fields
    unchanged; the two new keys are strictly additive. *)
let provider_entry_to_json
      ~(declared : bool)
      ?(perf : Model_inference_metrics.provider_stats option)
      (info : Health.provider_info)
  : Yojson.Safe.t
  =
  let opt_float = function
    | Some f -> `Float f
    | None -> `Null
  in
  let trust_score = Cascade_trust.trust_score info in
  let health_score =
    let score = Float.max 0.0 (Float.min 1.0 trust_score) in
    int_of_float (floor ((score *. 100.0) +. 0.5))
  in
  let perf_fields =
    match perf with
    | None ->
      (* Distinguish "the aggregator was not available this call"
         (absent base_path) from "the aggregator ran and this provider
         had no entries".  We use [null] in both cases — the UI reads
         the sibling [request_count] to tell them apart: [null] with
         [request_count = null] means no aggregator; [null] with
         [request_count = 0] means aggregator ran and found nothing. *)
      [ "avg_prompt_tok_per_sec", `Null
      ; "avg_decode_tok_per_sec", `Null
      ; "avg_tok_per_sec", `Null
      ; "avg_latency_ms", `Null
      ; "p50_latency_ms", `Null
      ; "p95_latency_ms", `Null
      ; "request_count", `Null
      ]
    | Some (stats : Model_inference_metrics.provider_stats) ->
      [ "avg_prompt_tok_per_sec", opt_float stats.ps_avg_prompt_tok_per_sec
      ; "avg_decode_tok_per_sec", opt_float stats.ps_avg_decode_tok_per_sec
      ; "avg_tok_per_sec", opt_float stats.ps_avg_tok_per_sec
      ; "avg_latency_ms", opt_float stats.ps_avg_latency_ms
      ; "p50_latency_ms", opt_float stats.ps_p50_latency_ms
      ; "p95_latency_ms", opt_float stats.ps_p95_latency_ms
      ; "request_count", `Int stats.ps_entry_count
      ]
  in
  let top_fingerprints_json =
    `List
      (List.map
         (fun (fp, count) -> `Assoc [ "fingerprint", `String fp; "count", `Int count ])
         info.top_fingerprints)
  in
  `Assoc
    ([ "provider_key", `String info.provider_key
     ; "success_rate", `Float info.success_rate
     ; "consecutive_failures", `Int info.consecutive_failures
     ; "in_cooldown", `Bool info.in_cooldown
     ; ( "cooldown_expires_at"
       , match info.cooldown_expires_at with
         | Some t -> `Float t
         | None -> `Null )
     ; "events_in_window", `Int info.events_in_window
     ; "trust_score", `Float trust_score
     ; "health_score", `Int health_score
     ; (* rejected_in_window ⊆ events_in_window: responses that arrived
       but were rejected by the cascade's accept predicate.  Split out
       so dashboards can distinguish "provider down" from "provider
       returns unusable output". *)
       "rejected_in_window", `Int info.rejected_in_window
     ; (* top_fingerprints / last_failure_at are Phase 0 trust observability
       anchors (cumulative, not window-bounded).  Surfaced so dashboards
       can show "which error keeps recurring" alongside the existing
       success-rate snapshot. *)
       "top_fingerprints", top_fingerprints_json
     ; "last_failure_at", opt_float info.last_failure_at
     ; "declared", `Bool declared
     ; "status", `String (provider_status info)
     ; "avg_confidence", opt_float info.avg_confidence
     ; "confidence_samples", `Int info.confidence_samples
     ]
     @ perf_fields)
;;

(** Back-compat alias: older call sites may still reference the previous
    serializer name.  Keeping it as a thin wrapper keeps the diff in
    this PR focused on the health_json merge. *)
let provider_info_to_json (info : Health.provider_info) : Yojson.Safe.t =
  provider_entry_to_json ~declared:false info
;;
