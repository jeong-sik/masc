(* Stage 08 — JSON serializers for the cascade catalog snapshot /
   rejection / state.  These power the [server_runtime_bootstrap.ml]
   "Validated active cascade catalog: ..." boot log and the
   dashboard/config-doctor surfaces.

   The boot log is an internal observability surface, NOT an external
   API or dashboard surface — Runtime Lens redaction at external
   boundaries (Prometheus labels, dashboard OAS bridge, redacted
   variants in [keeper_unified_metrics]) lives outside this module.  So
   the boot log emits real [model_string], [provider_kind], [model_id]
   and [base_url] values from the probe record. *)

open Cascade_catalog_runtime_cache

let float_opt_to_json = function
  | Some value -> `Float value
  | None -> `Null

let int_opt_to_json = function
  | Some value -> `Int value
  | None -> `Null

let candidate_probe_to_yojson (probe : candidate_probe) =
  `Assoc
    [
      ("model_string", `String probe.model_string);
      ("provider_kind", `String probe.provider_kind);
      ("model_id", `String probe.model_id);
      ("base_url", `String probe.base_url);
      ( "status",
        match probe.status with
        | Probe_ok -> `String "ok"
        | Probe_skipped _ -> `String "skipped"
        | Probe_not_applicable _ -> `String "not_applicable"
        | Probe_error _ -> `String "error" );
      ( "error",
        match probe.status with
        | Probe_ok -> `Null
        | Probe_skipped message -> `String message
        | Probe_not_applicable message -> `String message
        | Probe_error message -> `String message );
    ]

let profile_snapshot_to_yojson (profile : profile_snapshot) =
  `Assoc
    [
      ("name", `String profile.name);
      ( "strategy",
        `String (Cascade_strategy.kind_to_string profile.strategy.kind) );
      ("ollama_max_concurrent", int_opt_to_json profile.ollama_max_concurrent);
      ("cli_max_concurrent", int_opt_to_json profile.cli_max_concurrent);
      ( "candidates",
        `List (List.map candidate_probe_to_yojson profile.probes) );
    ]

let snapshot_to_yojson (snapshot : snapshot) =
  `Assoc
    [
      ("source_path", `String snapshot.source_path);
      ("source_mtime", `Float snapshot.mtime);
      ("validated_at", `Float snapshot.validated_at);
      ("default_profile_name", `String snapshot.default_profile_name);
      ("profile_count", `Int (List.length snapshot.profiles));
      ( "profiles",
        `List (List.map profile_snapshot_to_yojson snapshot.profiles) );
    ]

let profile_rejection_to_yojson (profile : profile_rejection) =
  `Assoc
    [
      ("name", `String profile.name);
      ( "errors",
        `List (List.map (fun value -> `String value) profile.errors) );
      ( "candidates",
        `List (List.map candidate_probe_to_yojson profile.probes) );
    ]

let rejection_to_yojson (rejection : rejection) =
  `Assoc
    [
      ("source_path", `String rejection.source_path);
      ("attempted_mtime", float_opt_to_json rejection.attempted_mtime);
      ("checked_at", `Float rejection.checked_at);
      ( "errors",
        `List (List.map (fun value -> `String value) rejection.errors) );
      ( "profiles",
        `List (List.map profile_rejection_to_yojson rejection.profiles) );
    ]

let state_to_yojson = function
  | Validated snapshot ->
      `Assoc
        [
          ("status", `String "validated");
          ("serving_last_known_good", `Bool false);
          ("snapshot", snapshot_to_yojson snapshot);
          ("rejected_update", `Null);
        ]
  | Validated_with_rejections { snapshot; rejected_update } ->
      `Assoc
        [
          ("status", `String "validated");
          ("serving_last_known_good", `Bool false);
          ("snapshot", snapshot_to_yojson snapshot);
          ("rejected_update", rejection_to_yojson rejected_update);
        ]
  | Serving_last_known_good { snapshot; rejected_update } ->
      `Assoc
        [
          ("status", `String "serving_last_known_good");
          ("serving_last_known_good", `Bool true);
          ("snapshot", snapshot_to_yojson snapshot);
          ("rejected_update", rejection_to_yojson rejected_update);
        ]
