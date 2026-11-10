module Native = Native_file_change
type error =
  | Native of Native.error
  | Inventory of Dashboard_tla_specs.scan_error
  | Filesystem of Unix.error
type state = Starting | Available | Unavailable of error | Stopped

let state = Atomic.make Starting

let error_detail = function
  | Native error -> Native.error_to_string error
  | Inventory { error; path = _ } -> "source inventory: " ^ Unix.error_message error
  | Filesystem error -> "source watch topology: " ^ Unix.error_message error
;;

let health_json () =
  let status, action, reasons = match Atomic.get state with
    | Starting -> "unavailable", false, [ "kernel file observation is starting" ]
    | Available -> "ok", false, []
    | Unavailable error -> "unavailable", true, [ error_detail error ]
    | Stopped -> "unavailable", false, [ "kernel file observation is stopped" ]
  in
  `Assoc [ "status", `String status; "operator_action_required", `Bool action;
    "status_reasons", `List (List.map (fun reason -> `String reason) reasons) ]
;;

type topic = Sse_event.Types.dashboard_observation_topic
type binding = { target : Native.target; topics : topic list }
type plan = binding list

let both : topic list = [ `Verification_specs; `Tlc_results ]

let build_plan () : (plan, error) result =
  match Dashboard_tla_specs.observation_source_inventory () with
  | Error error -> Error (Inventory error)
  | Ok inventory ->
    match
      let bindings = Hashtbl.create 32 in
      let stat path =
        match Unix.stat path with
        | status -> Some status
        | exception Unix.Unix_error ((Unix.ENOENT | Unix.ENOTDIR), _, _) -> None
      in
      let add ~kind ~topics path =
        match stat path with
        | None -> ()
        | Some status when kind = Native.Directory && status.Unix.st_kind <> Unix.S_DIR -> ()
        | Some _ ->
          let path = Unix.realpath path in
          let status = Unix.stat path in
          let identity = status.st_dev, status.st_ino in
          let target = { Native.path; kind; device = status.st_dev; inode = status.st_ino } in
          (match Hashtbl.find_opt bindings identity with
           | None -> Hashtbl.add bindings identity { target; topics }
           | Some previous ->
             let target =
               if kind = Native.Directory then { target with kind = Native.Directory }
               else previous.target in
             Hashtbl.replace bindings identity
               { target; topics = List.sort_uniq Stdlib.compare (previous.topics @ topics) })
      in
      let rec guard seen_links path =
        let parent = Filename.dirname path in
        if not (String.equal parent path) then guard seen_links parent;
        match Unix.lstat path with
        | status when status.st_kind = Unix.S_LNK ->
          let identity = status.st_dev, status.st_ino in
          if List.mem identity seen_links then raise (Unix.Unix_error (Unix.ELOOP, "watch path", path));
          let destination = Unix.readlink path in
          let destination = if Filename.is_relative destination then Filename.concat parent destination else destination in
          guard (identity :: seen_links) destination
        | status when status.st_kind = Unix.S_DIR -> add ~kind:Native.Directory ~topics:[] path
        | _ -> ()
        | exception Unix.Unix_error ((Unix.ENOENT | Unix.ENOTDIR), _, _) -> ()
      in
      let root path =
        let path = if Filename.is_relative path then Filename.concat (Sys.getcwd ()) path else path in
        guard [] path
      in
      root inventory.specs_directory;
      root inventory.results_directory;
      List.iter root (inventory.spec_directories @ inventory.spec_files
                      @ inventory.cfg_files @ inventory.expected_log_files);
      List.iter (add ~kind:Native.Directory ~topics:[]) inventory.spec_directories;
      List.iter (add ~kind:Native.File ~topics:both) (inventory.spec_files @ inventory.cfg_files);
      List.iter (add ~kind:Native.File ~topics:[ `Tlc_results ]) inventory.expected_log_files;
      Ok (Hashtbl.fold (fun _ binding acc -> binding :: acc) bindings []
          |> List.sort (fun left right -> String.compare left.target.path right.target.path))
    with
    | result -> result
    | exception Unix.Unix_error (error, _, _) -> Error (Filesystem error)
    | exception Sys_error _ -> Error (Filesystem Unix.EIO)
;;

let announce topics = List.iter Dashboard_observation_commit.process_written topics

let start ~sw ~mono_clock ~report =
  let update next =
    let previous = Atomic.exchange state next in
    if previous <> next then report next
  in
  update Starting;
  Eio.Fiber.fork_daemon ~sw (fun () ->
    let current = ref None in
    let scan () = Eio_unix.run_in_systhread build_plan in
    let close_current () = Option.iter Native.close !current; current := None in
    (* Failure-only policy is shared with the server invalidation worker.
       There is no success-path sleep or new runtime configuration knob. *)
    let retry_initial_s = Server_observation_retry.initial_delay_s in
    let rec failed delay error =
      update (Unavailable error);
      Eio.Time.Mono.sleep mono_clock delay;
      establish (Server_observation_retry.next_delay_s delay)
    and establish delay =
      match scan () with
      | Error error -> failed delay error
      | Ok plan ->
        (match Native.create ~sw ~targets:(List.map (fun binding -> binding.target) plan) with
         | Error error -> failed delay (Native error)
         | Ok fresh ->
           (* Fresh coverage is armed before old native IDs can be retired.
              Post-arm inventory carries any topology debt across this swap. *)
           let after = scan () in
           close_current ();
           current := Some fresh;
           (match after with
            | Error error -> failed delay error
            | Ok after ->
              update Available;
              announce both;
              if plan = after then observe fresh plan
              else begin Eio.Fiber.yield (); establish retry_initial_s end))
    and observe watcher plan =
      match Native.await watcher with
      | Error error -> failed retry_initial_s (Native error)
      | Ok (Native.Coverage_lost _) -> update Starting; establish retry_initial_s
      | Ok (Native.Changed targets) ->
        let topics = targets |> List.concat_map (fun target ->
          match List.find_opt (fun binding -> binding.target = target) plan with
          | Some binding -> binding.topics
          | None -> []) |> List.sort_uniq Stdlib.compare in
        announce topics;
        Eio.Fiber.yield ();
        if List.exists (fun target -> target.Native.kind = Native.Directory) targets then
          (match scan () with
           | Error error -> failed retry_initial_s error
           | Ok after when after <> plan -> establish retry_initial_s
           | Ok _ -> observe watcher plan)
        else observe watcher plan
    in
    Fun.protect ~finally:(fun () -> close_current (); Atomic.set state Stopped)
      (fun () -> establish retry_initial_s))
;;
