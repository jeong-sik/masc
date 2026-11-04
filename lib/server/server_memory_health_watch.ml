module String_map = Map.Make (String)

let compare_interval_s = Server_dashboard_http_core_cache.standard_cache_ttl_s

type kept =
  { health : Yojson.Safe.t
  ; execution : Yojson.Safe.t
  ; keepers : Yojson.Safe.t String_map.t
  }

let last : (string, kept) Hashtbl.t = Hashtbl.create 1
let last_mu = Stdlib.Mutex.create ()

let field name = function
  | `Assoc fields -> Option.value ~default:`Null (List.assoc_opt name fields)
  | _ -> `Null
;;

let keepers_of health =
  match field "keepers" health with
  | `List rows ->
    List.fold_left
      (fun keepers row ->
        match field "keeper_id" row with
        | `String keeper_id -> String_map.add keeper_id row keepers
        | _ -> keepers)
      String_map.empty rows
  | _ -> String_map.empty
;;

let moved_keepers previous current =
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

let observe ~base_path health =
  let current = { health; execution = field "execution" health; keepers = keepers_of health } in
  let previous =
    Stdlib.Mutex.protect last_mu (fun () ->
      let previous = Hashtbl.find_opt last base_path in
      Hashtbl.replace last base_path current;
      previous)
  in
  let execution_moved, keepers_moved =
    match previous with
    | None -> true, List.map fst (String_map.bindings current.keepers)
    | Some previous ->
      ( not (Yojson.Safe.equal previous.execution current.execution)
      , moved_keepers previous.keepers current.keepers )
  in
  if execution_moved
  then Workspace_dataset_event.announce ~base_path Workspace_dataset_event.Memory_execution;
  List.iter
    (fun keeper ->
      Workspace_dataset_event.announce ~base_path (Workspace_dataset_event.Memory_health { keeper }))
    keepers_moved
;;

let latest ~base_path =
  Stdlib.Mutex.protect last_mu (fun () ->
    Option.map (fun kept -> kept.health) (Hashtbl.find_opt last base_path))
;;

let compute ~base_path =
  let health =
    Pool_work.submit
      (Pool_work.cpu ~name:__FUNCTION__ (fun () ->
         Server_dashboard_http_keeper_memory_health.keeper_memory_health_http_json ~base_path))
  in
  observe ~base_path health;
  health
;;

let start ~sw ~clock ~base_path =
  Eio.Fiber.fork_daemon ~sw (fun () ->
    let rec compare_loop () =
      (match compute ~base_path with
       | _ -> ()
       | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
       | exception exn ->
         Log.Dashboard.warn "keeper memory health compare failed: %s" (Printexc.to_string exn));
      Eio.Time.sleep clock compare_interval_s;
      compare_loop ()
    in
    compare_loop ())
;;
