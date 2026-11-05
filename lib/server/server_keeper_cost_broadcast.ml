(* The Keeper cost window's answer also changes with no write, when a kept
   row or a kept day file leaves it. This fiber sleeps until the earliest such
   instant and announces it. A read that kept rows wakes it to look again: a
   file read for the first time can hold rows that leave sooner. *)
let install ~sw ~clock ~(config : Workspace.config) =
  let wake = Eio.Stream.create 1 in
  let wake_mu = Stdlib.Mutex.create () in
  Dashboard_http_keeper_feeds.install_keeper_costs_kept_observer (fun ~base_path ->
    if String.equal base_path config.base_path then
      Stdlib.Mutex.protect wake_mu (fun () ->
        if Eio.Stream.is_empty wake then Eio.Stream.add wake ()));
  Eio.Fiber.fork_daemon ~sw (fun () ->
    let rec watch () =
      let next =
        Dashboard_http_keeper_feeds.keeper_costs_next_change ~base_path:config.base_path
          ~now:(Eio.Time.now clock)
      in
      (match next with
       | None -> Eio.Stream.take wake
       | Some at ->
         (match
            Eio.Fiber.first
              (fun () ->
                Eio.Stream.take wake;
                `Kept_rows_changed)
              (fun () ->
                Eio.Time.sleep_until clock at;
                `Left_window)
          with
          | `Kept_rows_changed -> ()
          | `Left_window ->
            Workspace_dataset_event.announce ~base_path:config.base_path
              Workspace_dataset_event.Keeper_costs));
      watch ()
    in
    watch ())
;;
