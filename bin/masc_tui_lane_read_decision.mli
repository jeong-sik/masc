type view = Lanes | Overview | Addons of string option

type result = Read_lanes | Read_addon of string | Ignore

val of_dataset : view:view -> Masc.Workspace_dataset_event.dataset -> result
(** Select only the read whose data is visible. [Addons] carries the open
    instance ID, or [None] when its overview has no matching scoped read. *)
