type routes =
  { assignments : (string * string) list
  ; default_route : string
  }

type announcement =
  | Every_row
  | Rows of string list

let current_routes () =
  { assignments = Runtime.keeper_assignments ()
  ; default_route = Runtime.get_default_route ()
  }
;;

let announcement ~before ~after =
  if not (String.equal before.default_route after.default_route)
  then Every_row
  else
    List.map fst before.assignments @ List.map fst after.assignments
    |> List.sort_uniq String.compare
    |> List.filter (fun keeper ->
      not
        (Option.equal String.equal
           (List.assoc_opt keeper before.assignments)
           (List.assoc_opt keeper after.assignments)))
    |> fun keepers -> Rows keepers
;;

let announce ~base_path = function
  | Every_row -> Keeper_row_broadcast.roster_changed ~base_path
  | Rows keepers ->
    List.iter (fun keeper_name -> Keeper_row_broadcast.changed ~base_path ~keeper_name) keepers
;;

let install ~sw ~base_path =
  (* The revision is read before the routes, so a publication between the two
     reads is compared on the first wake instead of being missed. *)
  let revision = Runtime.catalogue_revision () in
  let routes = current_routes () in
  Eio.Fiber.fork_daemon ~sw (fun () ->
    let rec watch ~after ~before =
      let revision = Runtime.await_catalogue_change ~after in
      let routes = current_routes () in
      announce ~base_path (announcement ~before ~after:routes);
      watch ~after:revision ~before:routes
    in
    watch ~after:revision ~before:routes)
;;
