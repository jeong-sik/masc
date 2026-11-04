module String_map = Map.Make (String)

type kept = { configuration : Yojson.Safe.t; instances : Yojson.Safe.t String_map.t }

let last : (string, kept) Hashtbl.t = Hashtbl.create 1
let last_mu = Stdlib.Mutex.create ()

let moved_instances previous current =
  String_map.merge
    (fun _ before now ->
      match before, now with
      | Some before, Some now when Yojson.Safe.equal before now -> None
      | Some _, Some _ | Some _, None | None, Some _ -> Some ()
      | None, None -> None)
    previous current
  |> String_map.bindings
  |> List.map fst
;;

let observe ~base_path (reading : Lane_addon_runtime.inspect_reading) =
  let current =
    { configuration = reading.configuration; instances = String_map.of_list reading.instances }
  in
  let previous =
    Stdlib.Mutex.protect last_mu (fun () ->
      let previous = Hashtbl.find_opt last base_path in
      Hashtbl.replace last base_path current;
      previous)
  in
  let configuration_moved, instances_moved =
    match previous with
    | None -> true, List.map fst (String_map.bindings current.instances)
    | Some previous ->
      ( not (Yojson.Safe.equal previous.configuration current.configuration)
      , moved_instances previous.instances current.instances )
  in
  if configuration_moved
  then Workspace_dataset_event.announce ~base_path Workspace_dataset_event.Lane_addon_configuration;
  List.iter
    (fun instance_id ->
      Workspace_dataset_event.announce ~base_path
        (Workspace_dataset_event.Lane_addon_instance { instance_id }))
    instances_moved
;;

let failed_retry_max_s = 30.0

let start ~sw ~clock ~(config : Workspace.config) =
  let base_path = config.base_path in
  let interval_s = Server_lane_inventory_watch.compare_interval_s in
  Eio.Fiber.fork_daemon ~sw (fun () ->
    let failed ~wait_s detail =
      let next = Float.min failed_retry_max_s (wait_s *. 2.0) in
      Log.Dashboard.warn "lane add-on inspect compare failed, next in %.0fs: %s" next detail;
      next
    in
    let rec compare ~wait_s =
      let wait_s =
        match Lane_addon_runtime.inspect_reading ~config with
        | Ok (Some reading) ->
          observe ~base_path reading;
          interval_s
        | Ok None -> interval_s
        | Error detail -> failed ~wait_s detail
        | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
        | exception exn -> failed ~wait_s (Printexc.to_string exn)
      in
      Eio.Time.sleep clock wait_s;
      compare ~wait_s
    in
    compare ~wait_s:interval_s)
;;
