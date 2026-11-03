let install ~sw ~base_path =
  let revision = Runtime.catalogue_revision () in
  Eio.Fiber.fork_daemon ~sw (fun () ->
    let rec watch ~after =
      let revision = Runtime.await_catalogue_change ~after in
      Keeper_row_broadcast.roster_changed ~base_path;
      watch ~after:revision
    in
    watch ~after:revision)
;;
