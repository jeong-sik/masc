let event_type = "workspace_dataset_changed"

type dataset =
  | Repositories
  | Verification_requests
  | Keeper_metrics of { keeper : string }
  | Harness_verdicts
  | Goals
  | Runtime_config
  | Connectors
  | Keeper_oauth_attempts of { keeper : string }
  | Skill_activations of { keeper : string }
  | Skill_catalog
  | Clients
  | Provider_usage
  | Provider_standing
  | Keeper_costs

let repositories_name = "repositories"
let verification_requests_name = "verification_requests"
let keeper_metrics_name = "keeper_metrics"
let harness_verdicts_name = "harness_verdicts"
let goals_name = "goals"
let runtime_config_name = "runtime_config"
let connectors_name = "connectors"
let keeper_oauth_attempts_name = "keeper_oauth_attempts"
let skill_activations_name = "skill_activations"
let skill_catalog_name = "skill_catalog"
let clients_name = "clients"
let provider_usage_name = "provider_usage"
let provider_standing_name = "provider_standing"
let keeper_costs_name = "keeper_costs"

let dataset_name = function
  | Repositories -> repositories_name
  | Verification_requests -> verification_requests_name
  | Keeper_metrics _ -> keeper_metrics_name
  | Harness_verdicts -> harness_verdicts_name
  | Goals -> goals_name
  | Runtime_config -> runtime_config_name
  | Connectors -> connectors_name
  | Keeper_oauth_attempts _ -> keeper_oauth_attempts_name
  | Skill_activations _ -> skill_activations_name
  | Skill_catalog -> skill_catalog_name
  | Clients -> clients_name
  | Provider_usage -> provider_usage_name
  | Provider_standing -> provider_standing_name
  | Keeper_costs -> keeper_costs_name
;;

let keeper_field = function
  | Repositories | Verification_requests | Harness_verdicts | Goals | Runtime_config | Connectors
  | Skill_catalog | Clients | Provider_usage | Provider_standing | Keeper_costs -> []
  | Keeper_metrics { keeper } | Keeper_oauth_attempts { keeper } | Skill_activations { keeper } ->
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
  | Some (`String name) when String.equal name goals_name -> Ok Goals
  | Some (`String name) when String.equal name runtime_config_name -> Ok Runtime_config
  | Some (`String name) when String.equal name connectors_name -> Ok Connectors
  | Some (`String name) when String.equal name skill_catalog_name -> Ok Skill_catalog
  | Some (`String name) when String.equal name clients_name -> Ok Clients
  | Some (`String name) when String.equal name provider_usage_name -> Ok Provider_usage
  | Some (`String name) when String.equal name provider_standing_name -> Ok Provider_standing
  | Some (`String name) when String.equal name keeper_costs_name -> Ok Keeper_costs
  | Some (`String name) when String.equal name keeper_metrics_name ->
    Result.map (fun keeper -> Keeper_metrics { keeper }) (keeper_of_fields name fields)
  | Some (`String name) when String.equal name keeper_oauth_attempts_name ->
    Result.map (fun keeper -> Keeper_oauth_attempts { keeper }) (keeper_of_fields name fields)
  | Some (`String name) when String.equal name skill_activations_name ->
    Result.map (fun keeper -> Skill_activations { keeper }) (keeper_of_fields name fields)
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
