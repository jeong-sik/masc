type reason = Starting | Stopping | Detaching | Failed of string

type t = {
  installation : string;
  instance_id : string;
  package_id : string;
  declared_tools : string list;
  service : Lane_addon_types.worker_service;
  reason : reason;
}

let message t =
  let state = match t.reason with
    | Starting -> "is starting"
    | Stopping -> "is stopping"
    | Detaching -> "is detaching"
    | Failed detail -> "failed: " ^ detail in
  Printf.sprintf "Add-on installation %s (package %s) %s" t.installation t.package_id state

let declaring ~name unready = List.filter (fun t -> List.mem name t.declared_tools) unready

let summary = function
  | [] -> None
  | unready -> Some (String.concat "; " (List.map message unready))
