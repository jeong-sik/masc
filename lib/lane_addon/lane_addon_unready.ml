type reason = Starting | Stopping | Detaching | Failed of Lane_addon_lifecycle.failed

type t = {
  installation : string;
  instance_id : string;
  package_id : string;
  declared_tools : string list;
  service : Lane_addon_types.worker_service;
  reason : reason;
}

let render ~failed t =
  let state = match t.reason with
    | Starting -> "is starting"
    | Stopping -> "is stopping"
    | Detaching -> "is detaching"
    | Failed failure -> failed failure in
  Printf.sprintf "Add-on installation %s (package %s) %s" t.installation t.package_id state

let message = render ~failed:(fun _ -> "failed; the operator can read why in Lane Add-ons")
let operator_message =
  render ~failed:(fun failure -> "failed: " ^ Lane_addon_lifecycle.failed_to_string failure)

let declaring ~name unready = List.filter (fun t -> List.mem name t.declared_tools) unready

let joined render = function
  | [] -> None
  | unready -> Some (String.concat "; " (List.map render unready))
let summary = joined message
let operator_summary = joined operator_message
