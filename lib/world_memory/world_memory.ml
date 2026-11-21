module Types = World_memory_types
module Store = World_memory_store
module Curator = World_memory_curator
module By_workspace = Map.Make (String)

let curators : Curator.t By_workspace.t Atomic.t = Atomic.make By_workspace.empty

let rec update_table change =
  let before = Atomic.get curators in
  if not (Atomic.compare_and_set curators before (change before)) then update_table change
;;

let workspace_key ~base_path =
  try Unix.realpath base_path with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | Unix.Unix_error _ | Sys_error _ -> base_path
;;

let start_workspace_curator ~sw ~base_path ~now ~on_updated =
  let key = workspace_key ~base_path in
  let curator = Curator.start ~sw ~base_path ~now ~on_updated in
  update_table (By_workspace.add key curator);
  Eio.Switch.on_release sw (fun () ->
    update_table (fun tbl ->
      match By_workspace.find_opt key tbl with
      | Some cur when cur == curator -> By_workspace.remove key tbl
      | Some _ | None -> tbl));
  curator
;;

let find_workspace_curator ~base_path =
  By_workspace.find_opt (workspace_key ~base_path) (Atomic.get curators)
;;

let promote_from_librarian ~base_path ~keeper_id promotions =
  match promotions with
  | [] -> ()
  | _ :: _ ->
    (match find_workspace_curator ~base_path with
     | Some curator -> Curator.enqueue_promotions curator ~keeper_id promotions
     | None ->
       (match
          Curator.process_promotions_sync ~base_path ~now:(Time_compat.now ()) ~keeper_id promotions
        with
        | Ok _ -> ()
        | Error err ->
          Log.Server.warn "world_memory promote_from_librarian failed (%s): %s"
            keeper_id (Store.error_to_string err)))
;;

let read_index_snapshot_for_librarian ~base_path =
  match Store.read_index_snapshot ~base_path with
  | Ok snap -> snap
  | Error err ->
    Log.Server.warn "world_memory index snapshot unavailable: %s" (Store.error_to_string err);
    None
;;
