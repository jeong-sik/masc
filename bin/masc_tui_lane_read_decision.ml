type view = Lanes | Overview | Addons of string option

type result = Read_lanes | Read_addon of string | Ignore

let of_dataset ~view (dataset : Masc.Workspace_dataset_event.dataset) =
  match view, dataset with
  | Lanes, Masc.Workspace_dataset_event.Lanes -> Read_lanes
  | Addons (Some open_id), Masc.Workspace_dataset_event.Lane_addons { instance_id }
    when String.equal open_id instance_id -> Read_addon instance_id
  | (Lanes | Overview | Addons _), (Masc.Workspace_dataset_event.Lanes
    | Masc.Workspace_dataset_event.Machine_live _
    | Masc.Workspace_dataset_event.Browser_observation _
    | Masc.Workspace_dataset_event.Memory_health _
    | Masc.Workspace_dataset_event.Dashboard_observation _
    | Masc.Workspace_dataset_event.World_memory
    | Masc.Workspace_dataset_event.Play_seats
    | Masc.Workspace_dataset_event.Play_room _
    | Masc.Workspace_dataset_event.Lane_addons _) -> Ignore
  | (Lanes | Overview | Addons _), (Masc.Workspace_dataset_event.Repositories
    | Masc.Workspace_dataset_event.Verification_requests
    | Masc.Workspace_dataset_event.Keeper_metrics _
    | Masc.Workspace_dataset_event.Harness_verdicts
    | Masc.Workspace_dataset_event.Goals
    | Masc.Workspace_dataset_event.Runtime_config
    | Masc.Workspace_dataset_event.Connectors
    | Masc.Workspace_dataset_event.Keeper_oauth_attempts _
    | Masc.Workspace_dataset_event.Skill_activations _
    | Masc.Workspace_dataset_event.Skill_catalog
    | Masc.Workspace_dataset_event.Clients
    | Masc.Workspace_dataset_event.Account_emails
    | Masc.Workspace_dataset_event.Provider_usage
    | Masc.Workspace_dataset_event.Provider_standing
    | Masc.Workspace_dataset_event.Keeper_costs
    | Masc.Workspace_dataset_event.Workspace_health
    | Masc.Workspace_dataset_event.Runtime_probe
    | Masc.Workspace_dataset_event.Runtime_metrics) -> Ignore

let of_views ~lanes ~addon dataset =
  match of_dataset ~view:(Addons addon) dataset with
  | (Read_lanes | Read_addon _) as read -> read
  | Ignore -> of_dataset ~view:(if lanes then Lanes else Overview) dataset
