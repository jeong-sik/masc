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

let start ~sw ~clock ~(config : Workspace.config) =
  let base_path = config.base_path in
  Eio.Fiber.fork_daemon ~sw (fun () ->
    let rec compare () =
      (match Server_lane_inventory.drawn_json (Server_lane_inventory.snapshot ~config) with
       | drawn -> observe ~base_path drawn
       | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
       | exception exn ->
         Log.Dashboard.warn "lane inventory compare failed: %s" (Printexc.to_string exn));
      Eio.Time.sleep clock compare_interval_s;
      compare ()
    in
    compare ())
;;
