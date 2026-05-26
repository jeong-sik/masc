include Server_dashboard_http_composite_claims
include Server_dashboard_http_composite_recommendations

let enrich_composite_snapshot_json
      ~(config : Coord.config)
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
    `Assoc
      (fields
       @ [ "keeper", `String keeper_name
         ; "activation_readiness", keeper_activation_readiness_json entry.meta
         ; "execution", execution
         ; "runtime_attention", runtime_attention
         ; "recommended_actions", recommended_actions
         ])
  | other -> other
;;

let dashboard_keeper_composite_json
      ~(config : Coord.config)
      (entry : Keeper_registry.registry_entry)
  : Yojson.Safe.t
  =
  Keeper_composite_observer.observe entry
  |> Keeper_composite_observer.snapshot_to_json
  |> enrich_composite_snapshot_json ~config entry
;;

let dashboard_fleet_composite_json ~(config : Coord.config) () : Yojson.Safe.t =
  let entries = Keeper_registry.all ~base_path:config.base_path () in
  let snapshots = List.map (dashboard_keeper_composite_json ~config) entries in
  `Assoc
    [ "generated_at", `Float (Unix.gettimeofday ())
    ; "count", `Int (List.length snapshots)
    ; "snapshots", `List snapshots
    ]
;;
