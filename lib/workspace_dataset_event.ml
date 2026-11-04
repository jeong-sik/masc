let event_type = "workspace_dataset_changed"

type dataset =
  | Repositories
  | Verification_requests
  | Harness_verdicts
  | Runtime_config
  | Keeper_oauth_attempts of { keeper : string }
  | Clients
  | Provider_usage
  | Provider_standing
  | Keeper_costs
  | Workspace_health
  | Runtime_probe
  | Runtime_metrics
  | Lanes

let repositories_name = "repositories"
let verification_requests_name = "verification_requests"
let harness_verdicts_name = "harness_verdicts"
let runtime_config_name = "runtime_config"
let keeper_oauth_attempts_name = "keeper_oauth_attempts"
let clients_name = "clients"
let provider_usage_name = "provider_usage"
let provider_standing_name = "provider_standing"
let keeper_costs_name = "keeper_costs"
let workspace_health_name = "workspace_health"
let runtime_probe_name = "runtime_probe"
let runtime_metrics_name = "runtime_metrics"
let lanes_name = "lanes"

let dataset_name = function
  | Repositories -> repositories_name
  | Verification_requests -> verification_requests_name
  | Harness_verdicts -> harness_verdicts_name
  | Runtime_config -> runtime_config_name
  | Keeper_oauth_attempts _ -> keeper_oauth_attempts_name

  | Clients -> clients_name
  | Provider_usage -> provider_usage_name
  | Provider_standing -> provider_standing_name
  | Keeper_costs -> keeper_costs_name
  | Workspace_health -> workspace_health_name
  | Runtime_probe -> runtime_probe_name
  | Runtime_metrics -> runtime_metrics_name
  | Lanes -> lanes_name
;;

let keeper_field = function
  | Repositories | Verification_requests | Harness_verdicts | Runtime_config
  | Provider_usage | Provider_standing -> []
  | Keeper_oauth_attempts { keeper } -> [ "keeper", `String keeper ]
  | Workspace_health -> []
  | Workspace_health | Runtime_probe -> []
  | Workspace_health | Runtime_probe | Runtime_metrics -> []
  | Workspace_health | Runtime_probe | Runtime_metrics | Lanes -> []
    [ "keeper", `String keeper ]
;;

let keeper_of_fields name fields =
  match List.assoc_opt "keeper" fields with
  | Some (`String keeper) when not (String.equal keeper "") -> Ok keeper
  | Some _ | None -> Error (event_type ^ " " ^ name ^ " names no keeper")
;;

let of_fields fields =
  match List.assoc_opt "dataset" fields with
  | Some (`String name) when String.equal name repositories_name -> Ok Repositories
  | Some (`String name) when String.equal name verification_requests_name ->
    Ok Verification_requests
  | Some (`String name) when String.equal name harness_verdicts_name -> Ok Harness_verdicts
  | Some (`String name) when String.equal name runtime_config_name -> Ok Runtime_config

  | Some (`String name) when String.equal name clients_name -> Ok Clients
  | Some (`String name) when String.equal name provider_usage_name -> Ok Provider_usage
  | Some (`String name) when String.equal name provider_standing_name -> Ok Provider_standing
  | Some (`String name) when String.equal name keeper_costs_name -> Ok Keeper_costs
  | Some (`String name) when String.equal name workspace_health_name -> Ok Workspace_health
  | Some (`String name) when String.equal name runtime_probe_name -> Ok Runtime_probe
  | Some (`String name) when String.equal name runtime_metrics_name -> Ok Runtime_metrics
  | Some (`String name) when String.equal name lanes_name -> Ok Lanes
  | Some (`String name) when String.equal name keeper_oauth_attempts_name ->
    (match keeper_of_fields name fields with
     | Ok keeper -> Ok (Keeper_oauth_attempts { keeper })
     | Error err -> Error err)
  | Some (`String name) -> Error (event_type ^ " names an unknown dataset " ^ name)
  | Some _ | None -> Error (event_type ^ " carries no dataset name")
;;
let announce ~base_path dataset =
  let name = dataset_name dataset in
  match
    let authority = Sse.runtime_authority_exn ~base_path in
    Sse.broadcast_to (Sse.Runtime_observers authority)
      (`Assoc
        ([ "type", `String event_type; "dataset", `String name ]
         @ keeper_field dataset
         @ [ "ts_unix", `Float (Time_compat.now ()) ]))
  with
  | () -> ()
  | exception exn ->
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string SseBroadcastFailures)
      ~labels:[ "site", event_type ^ ":" ^ name ]
      ();
    Log.Keeper.warn "workspace_dataset_event: %s %s failed: %s" event_type name
      (Printexc.to_string exn)
;;

let install_store_observers () =
  Repo_store.install_written_observer (fun ~base_path -> announce ~base_path Repositories);
  Keeper_oauth_pending.install_change_observer (fun ~base_path ~keeper ->
    announce ~base_path (Keeper_oauth_attempts { keeper }));
  Workspace_agent_record.install_rows_changed_observer (fun config ->
    announce ~base_path:config.Workspace_utils_backend_setup.base_path Clients)
;;
