type view = Lanes | Overview | Addons of string option

type result = Read_lanes | Read_addon of string | Ignore

let of_dataset ~view (dataset : Masc.Workspace_dataset_event.dataset) =
  match view, dataset with
  | Lanes, Masc.Workspace_dataset_event.Lanes -> Read_lanes
  | Addons (Some open_id), Masc.Workspace_dataset_event.Lane_addons { instance_id }
    when String.equal open_id instance_id -> Read_addon instance_id
  | (Lanes | Overview | Addons _), (Masc.Workspace_dataset_event.Lanes
    | Masc.Workspace_dataset_event.Lane_addons _) -> Ignore
