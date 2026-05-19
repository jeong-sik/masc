(** Cascade health endpoint.

    Composes:
    - {!Dashboard_cascade_health.provider_entry_to_json} for the tracker
      snapshot.
    - {!Dashboard_cascade_recommendations} for the embedded
      ["recommendations"] field.
    - Optional per-provider perf rollup from
      {!Model_inference_metrics.provider_rollup} when [?base_path] is
      supplied. *)

open Dashboard_cascade_helpers
open Dashboard_cascade_health
open Dashboard_cascade_recommendations

(** [provider_scheme_of_model_string s] returns the text before the first
    [:] in [s], or [s] itself if no colon is present.  This is a legacy
    cascade-health helper; keeper-facing runtime telemetry no longer uses it to
    derive provider identity. *)
let provider_scheme_of_model_string (s : string) : string =
  match String.index_opt s ':' with
  | Some i -> String.sub s 0 i
  | None -> s
;;

(** Collect the set of provider scheme prefixes declared by any cascade
    profile in [config_path].  Reads the typed catalog (so invalid
    profiles are skipped) and then each profile's raw model list.  Errors
    are swallowed into an empty set — a missing/malformed [cascade.toml]
    is already surfaced by [config_json]; we do not want the health
    endpoint to disappear just because the catalog loader fails.

    Path-explicit reads validate that exact TOML path so fixture tests do
    not cross-talk through the process-global active snapshot. *)
let declared_provider_schemes_set ?(config_path : string option) () : StringSet.t =
  match config_path with
  | None -> StringSet.empty
  | Some path ->
    (match Cascade_catalog_runtime.validate_path ~config_path:path () with
     | Error _ -> StringSet.empty
     | Ok snapshot ->
       List.fold_left
         (fun acc (profile : Cascade_catalog_runtime.profile_build) ->
            List.fold_left
              (fun acc (candidate : Cascade_catalog_runtime.candidate_runtime) ->
                 StringSet.add
                   (provider_scheme_of_model_string candidate.model_string)
                   acc)
              acc
              profile.candidates)
         StringSet.empty
         snapshot.profiles)
;;

(** Public list version of {!declared_provider_schemes_set}.  Sorted and
    deduplicated for stable dashboard rendering and easy test assertions
    that do not want to depend on a [Set.Make] type leaking across the
    .mli boundary. *)
let declared_provider_schemes_of_config ?config_path () : string list =
  StringSet.elements (declared_provider_schemes_set ?config_path ())
;;

(** When [?base_path] is supplied, [health_json] augments each provider
    entry with performance fields (see {!provider_entry_to_json}) sourced
    from {!Model_inference_metrics.provider_rollup} over the last
    [?window_minutes] (default 30) of keeper decisions.jsonl.  When
    omitted the perf fields are [null] and no jsonl scan happens — the
    endpoint keeps the zero-dependency behaviour expected by tests that
    run without a room_config.

    Errors from the aggregator (corrupt jsonl, missing directory) are
    caught and the perf fields fall back to [null]; a broken log must
    not take down the dashboard. *)
let health_json ?(window_minutes = 30) ?(base_path : string option) () =
  let config_path = Cascade_runtime.cascade_config_path () in
  let declared = declared_provider_schemes_set ?config_path () in
  let tracked = Health.all_providers Health.global in
  let tracked_keys =
    List.fold_left
      (fun acc (p : Health.provider_info) -> StringSet.add p.provider_key acc)
      StringSet.empty
      tracked
  in
  let perf_by_provider : (string, Model_inference_metrics.provider_stats) Hashtbl.t =
    Hashtbl.create 8
  in
  (match base_path with
   | None -> ()
   | Some base_path ->
     (try
        let agg = Model_inference_metrics.compute ~base_path ~window_minutes in
        let rollup = Model_inference_metrics.provider_rollup agg in
        List.iter
          (fun (s : Model_inference_metrics.provider_stats) ->
             Hashtbl.replace perf_by_provider s.ps_provider s)
          rollup
      with
      | Eio.Cancel.Cancelled _ as e -> raise e
      | exn ->
        Log.Keeper.warn
          "dashboard_cascade.health_json: provider perf aggregate failed: %s"
          (Stdlib.Printexc.to_string exn)));
  let perf_for key =
    match Hashtbl.find_opt perf_by_provider key with
    | Some _ as some -> some
    | None -> None
  in
  let tracked_entries =
    List.map
      (fun (info : Health.provider_info) ->
         provider_entry_to_json
           ~declared:(StringSet.mem info.provider_key declared)
           ?perf:(perf_for info.provider_key)
           info)
      tracked
  in
  let declared_only = StringSet.diff declared tracked_keys in
  let untouched_entries =
    StringSet.fold
      (fun key acc ->
         provider_entry_to_json
           ~declared:true
           ?perf:(perf_for key)
           (zero_provider_info key)
         :: acc)
      declared_only
      []
  in
  `Assoc
    [ "updated_at", `String (now_iso ())
    ; (* Health tracker is the SSOT for these values; reading env here would
       diverge from what the tracker actually applied (e.g. if the operator
       sets a malformed value that falls back to the default, the tracker
       has the fallback but a second env read would pick up the malformed
       string). *)
      "window_sec", `Float Health.window_sec
    ; "cooldown_threshold", `Int Health.cooldown_threshold
    ; "cooldown_sec", `Float Health.cooldown_sec
    ; "hard_quota_cooldown_sec", `Float Health.hard_quota_cooldown_sec
    ; ( "perf_window_minutes"
      , match base_path with
        | Some _ -> `Int window_minutes
        | None -> `Null )
    ; "providers", `List (tracked_entries @ untouched_entries)
    ; (* Phase 2a: low-trust recommendations attached to health_json so
       operators can see action items next to the raw trust scores.
       The recommendation list reads the same [Health.global] snapshot
       that produced [tracked] above; we recompute from [tracked] rather
       than re-scanning the tracker so both views are temporally
       consistent under concurrent updates. *)
      ( "recommendations"
      , `List (List.map recommendation_to_json (low_trust_recommendations tracked)) )
    ]
;;
