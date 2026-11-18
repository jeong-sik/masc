type lookup =
  | Owner_absent
  | Owner_projection of Keeper_owner_reducer.projection

module Owner_map = Set_util.StringMap

let owners : Keeper_owner.t Owner_map.t Atomic.t = Atomic.make Owner_map.empty

let cells_mu = Stdlib.Mutex.create ()

let key ~base_path ~keeper_name =
  Keeper_registry_types.canonical_base_path_exn base_path ^ "\000" ^ keeper_name
;;

let install ~base_path ~keeper_name owner =
  let key = key ~base_path ~keeper_name in
  Stdlib.Mutex.protect cells_mu (fun () ->
    Atomic.set owners (Owner_map.add key owner (Atomic.get owners)))
;;

let remove ~base_path ~keeper_name owner =
  let key = key ~base_path ~keeper_name in
  Stdlib.Mutex.protect cells_mu (fun () ->
    let installed = Atomic.get owners in
    match Owner_map.find_opt key installed with
    | Some current when current == owner ->
        Atomic.set owners (Owner_map.remove key installed)
    | Some _ | None -> ())
;;

let lookup ~base_path ~keeper_name =
  let key = key ~base_path ~keeper_name in
  match Owner_map.find_opt key (Atomic.get owners) with
  | None -> Owner_absent
  | Some owner -> Owner_projection (Keeper_owner.projection owner)
;;

(* The projection is read before the flag. A write that ends unsettled between
   the two reads is then seen, and the reader goes to the file. *)
let meta_the_file_holds ~base_path ~keeper_name =
  let key = key ~base_path ~keeper_name in
  match Owner_map.find_opt key (Atomic.get owners) with
  | None -> None
  | Some owner ->
    let meta = (Keeper_owner.projection owner).Keeper_owner_reducer.meta in
    if Keeper_owner.meta_write_unsettled owner then None else meta
;;
