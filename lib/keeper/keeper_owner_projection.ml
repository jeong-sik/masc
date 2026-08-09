type lookup =
  | Owner_absent
  | Owner_projection of Keeper_owner_reducer.projection

let owners : (string * Keeper_owner.t) list Atomic.t = Atomic.make []

let cells_mu = Stdlib.Mutex.create ()

let key ~base_path ~keeper_name =
  Keeper_registry_types.canonical_base_path_exn base_path ^ "\000" ^ keeper_name
;;

let install ~base_path ~keeper_name owner =
  let key = key ~base_path ~keeper_name in
  Stdlib.Mutex.protect cells_mu (fun () ->
    let without_key =
      List.filter (fun (candidate, _) -> not (String.equal candidate key)) (Atomic.get owners)
    in
    Atomic.set owners ((key, owner) :: without_key))
;;

let remove ~base_path ~keeper_name owner =
  let key = key ~base_path ~keeper_name in
  Stdlib.Mutex.protect cells_mu (fun () ->
    Atomic.set
      owners
      (List.filter
         (fun (candidate, current) ->
            not (String.equal candidate key && current == owner))
         (Atomic.get owners)))
;;

let lookup ~base_path ~keeper_name =
  let key = key ~base_path ~keeper_name in
  match List.assoc_opt key (Atomic.get owners) with
  | None -> Owner_absent
  | Some owner -> Owner_projection (Keeper_owner.projection owner)
;;
