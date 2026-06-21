include Server_dashboard_http_composite_claims
include Server_dashboard_http_composite_recommendations

let enrich_composite_snapshot_json
      ~(config : Workspace.config)
      (entry : Keeper_registry.registry_entry)
      json
  =
  let keeper_name = entry.name in
  match json with
  | `Assoc fields ->
    let fields =
      List.filter
        (fun (name, _) ->
           not
             (String.equal name "keeper"
              || String.equal name "execution"
              || String.equal name "activation_readiness"
              || String.equal name "runtime_attention"
              || String.equal name "recommended_actions"))
        fields
    in
    let execution = composite_execution_receipt_json ~config ~keeper_name in
    let attention = composite_runtime_attention ~snapshot:json ~execution in
    let recommended_actions =
      composite_recommended_actions_json ~keeper_name ~snapshot:json ~execution ~attention
    in
    let runtime_attention = composite_runtime_attention_json attention ~snapshot:json in
    let secret_projection =
      Keeper_secret_projection.dashboard_status_json
        ~base_path:config.base_path
        ~keeper_name
    in
    `Assoc
      (fields
       @ [ "keeper", `String keeper_name
         ; "activation_readiness", keeper_activation_readiness_json entry.meta
         ; "execution", execution
         ; "runtime_attention", runtime_attention
         ; "recommended_actions", recommended_actions
         ; "secret_projection", secret_projection
         ])
  | other -> other
;;

let dashboard_keeper_composite_json
      ~(config : Workspace.config)
      (entry : Keeper_registry.registry_entry)
  : Yojson.Safe.t
  =
  Keeper_composite_observer.observe entry
  |> Keeper_composite_observer.snapshot_to_json
  |> enrich_composite_snapshot_json ~config entry
;;

let dashboard_fleet_composite_json ~(config : Workspace.config) () : Yojson.Safe.t =
  (* Cache the fleet-composite envelope so each dashboard poll does not re-run
     the sequential [List.map] over keepers. Every [dashboard_keeper_composite_json]
     reaches [Keeper_secret_projection.dashboard_status_json], a synchronous disk
     read, so N keepers cost N reads per uncached hit. Mirrors the [/tool-stats]
     endpoint (keeper_api.ml) — the same [Dashboard_cache.get_or_compute] +
     [Domain_pool_ref.submit_io_or_inline] layer, keyed by [base_path] so distinct
     workspaces do not cross-contaminate. [generated_at] is stamped at compute
     time; the dashboard already treats it as a possibly-stale value for
     runtime-attention arithmetic (fleet-fsm-matrix.ts). This is a fleet-level
     envelope cache, not a second per-keeper cache layered on the projection
     rebuild cycle (RFC-0029 §3 non-goal), so it does not re-introduce
     projection-staleness drift. *)
  let cache_key =
    Printf.sprintf "dashboard:fleet-composite:%s" config.base_path
  in
  Dashboard_cache.get_or_compute cache_key
    ~ttl:Server_dashboard_http_core_cache.standard_cache_ttl_s
    (fun () ->
      Domain_pool_ref.submit_io_or_inline (fun () ->
        let entries = Keeper_registry.all ~base_path:config.base_path () in
        let snapshots = List.map (dashboard_keeper_composite_json ~config) entries in
        `Assoc
          (* generated_at is a unix-second number (not ISO8601 string) to match the
             sibling timestamps in this same envelope (snapshots[].started_at /
             last_progress_at / ended_at are all `Float) and the dashboard's
             runtime-attention staleness arithmetic (fleet-fsm-matrix.ts:558 computes
             `generatedAt - latest`, which requires a number). The dashboard valibot
             schema FleetCompositeSnapshotSchema declares generated_at: number(). *)
          [ "generated_at", `Float (Unix.gettimeofday ())  (* NDT-OK: compute-time wall-clock; envelope SWR-cached per-TTL; HTTP/WS response surface, not replayable *)
          ; "count", `Int (List.length snapshots)
          ; "snapshots", `List snapshots
          ]))
;;
