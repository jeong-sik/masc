module String_map = Map.Make (String)

let compare_interval_s = Server_dashboard_http_core_cache.standard_cache_ttl_s

type answer =
  | Computed of Yojson.Safe.t
  | Failed of string

(* What a joined computation ended with. [Abandoned] is an owner that was
   cancelled, so whoever joined it computes again instead of taking another
   reader's cancellation as its own answer. *)
type run =
  | Finished of answer
  | Abandoned

type workspace =
  { mutable answer : answer option
  ; mutable keepers : Yojson.Safe.t String_map.t option
  ; mutable computing : run Eio.Promise.t option
  }

let workspaces : (string, workspace) Hashtbl.t = Hashtbl.create 1
let workspaces_mu = Stdlib.Mutex.create ()

(* Called with [workspaces_mu] held. *)
let workspace_locked base_path =
  match Hashtbl.find_opt workspaces base_path with
  | Some workspace -> workspace
  | None ->
    let workspace = { answer = None; keepers = None; computing = None } in
    Hashtbl.replace workspaces base_path workspace;
    workspace
;;

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
  let current = keepers_of health in
  let previous =
    Stdlib.Mutex.protect workspaces_mu (fun () ->
      let workspace = workspace_locked base_path in
      let previous = workspace.keepers in
      workspace.keepers <- Some current;
      workspace.answer <- Some (Computed health);
      previous)
  in
  let moved =
    match previous with
    | None -> List.map fst (String_map.bindings current)
    | Some previous -> moved_keepers previous current
  in
  List.iter
    (fun keeper ->
      Workspace_dataset_event.announce ~base_path (Workspace_dataset_event.Memory_health { keeper }))
    moved
;;

let record_failure ~base_path detail =
  Stdlib.Mutex.protect workspaces_mu (fun () ->
    (workspace_locked base_path).answer <- Some (Failed detail))
;;

let latest ~base_path =
  Stdlib.Mutex.protect workspaces_mu (fun () ->
    Option.bind (Hashtbl.find_opt workspaces base_path) (fun workspace -> workspace.answer))
;;

let rec compute ~base_path =
  let role =
    Stdlib.Mutex.protect workspaces_mu (fun () ->
      let workspace = workspace_locked base_path in
      match workspace.computing with
      | Some running -> `Join running
      | None ->
        let running, resolver = Eio.Promise.create () in
        workspace.computing <- Some running;
        `Own resolver)
  in
  match role with
  | `Join running ->
    (match Eio.Promise.await running with
     | Finished answer -> answer
     | Abandoned -> compute ~base_path)
  | `Own resolver ->
    let settle run =
      Stdlib.Mutex.protect workspaces_mu (fun () -> (workspace_locked base_path).computing <- None);
      Eio.Promise.resolve resolver run
    in
    (match
       Pool_work.submit
         (Pool_work.cpu ~name:__FUNCTION__ (fun () ->
            Server_dashboard_http_keeper_memory_health.keeper_memory_health_http_json ~base_path))
     with
     | exception (Eio.Cancel.Cancelled _ as exn) ->
       settle Abandoned;
       raise exn
     | exception exn ->
       let detail = Printexc.to_string exn in
       record_failure ~base_path detail;
       settle (Finished (Failed detail));
       Failed detail
     | health ->
       (match observe ~base_path health with
        | () ->
          settle (Finished (Computed health));
          Computed health
        | exception exn ->
          settle Abandoned;
          raise exn))
;;

let compute_window_key ~base_path = "keeper_memory_health:" ^ base_path

let start ~sw ~clock ~base_path =
  Eio.Fiber.fork_daemon ~sw (fun () ->
    let rec compare_loop () =
      (match
         Dashboard_cache.within_default_compute_window ~key:(compute_window_key ~base_path)
           (fun () -> compute ~base_path)
       with
       | Ok (Computed _) -> ()
       | Ok (Failed detail) -> Log.Dashboard.warn "keeper memory health compare failed: %s" detail
       | Error _ ->
         let detail = "keeper memory health computation timed out" in
         record_failure ~base_path detail;
         Log.Dashboard.warn "%s" detail
       | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
       | exception exn ->
         Log.Dashboard.warn "keeper memory health compare failed: %s" (Printexc.to_string exn));
      Eio.Time.sleep clock compare_interval_s;
      compare_loop ()
    in
    compare_loop ())
;;
