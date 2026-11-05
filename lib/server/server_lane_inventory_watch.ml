let compare_interval_s = 2.0

let last : (string, Yojson.Safe.t) Hashtbl.t = Hashtbl.create 1
let last_mu = Stdlib.Mutex.create ()

let observe ~base_path drawn =
  let moved =
    Stdlib.Mutex.protect last_mu (fun () ->
      match Hashtbl.find_opt last base_path with
      | Some previous when Yojson.Safe.equal previous drawn -> false
      | Some _ | None ->
        Hashtbl.replace last base_path drawn;
        true)
  in
  if moved then Workspace_dataset_event.announce ~base_path Workspace_dataset_event.Lanes
;;

let failed_retry_max_s = 30.0

let start ~sw ~clock ~(config : Workspace.config) =
  let base_path = config.base_path in
  Eio.Fiber.fork_daemon ~sw (fun () ->
    (* A snapshot that fails waits twice as long before the next one, up to
       [failed_retry_max_s]; one that succeeds goes back to the interval. *)
    let rec compare ~wait_s =
      let wait_s =
        match Server_lane_inventory.drawn_json (Server_lane_inventory.snapshot ~config) with
        | drawn ->
          observe ~base_path drawn;
          compare_interval_s
        | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
        | exception exn ->
          let next = Float.min failed_retry_max_s (wait_s *. 2.0) in
          Log.Dashboard.warn "lane inventory compare failed, next in %.0fs: %s" next
            (Printexc.to_string exn);
          next
      in
      Eio.Time.sleep clock wait_s;
      compare ~wait_s
    in
    compare ~wait_s:compare_interval_s)
;;
