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
type access = Metadata_only | Readable_directory | Access_denied of Unix.error
type path_binding =
  | Absent
  | Symbolic_link of (int * int) * int * string
  | Bound of (int * int) * Unix.file_kind * int * access
(* Spec directories discover names; result log paths already come from the
   inventory. Ancestors retain coverage for rebinding, not roster discovery. *)
type directory_role = Path_guard | Spec_roster
type binding = {
  target : Native.target;
  topics : topic list;
  role : directory_role;
  guards : (string * path_binding) list;
}
type plan = binding list

let both : topic list = [ `Verification_specs; `Tlc_results ]

let path_binding path =
  match Unix.lstat path with
  | status when status.Unix.st_kind = Unix.S_LNK ->
    Symbolic_link ((status.st_dev, status.st_ino), status.st_perm, Unix.readlink path)
  | status ->
    let access =
      if status.Unix.st_kind <> Unix.S_DIR then Metadata_only
      else match Unix.access path [Unix.R_OK; Unix.X_OK] with
        | () -> Readable_directory
        | exception Unix.Unix_error (error, _, _) -> Access_denied error in
    Bound ((status.st_dev, status.st_ino), status.st_kind, status.st_perm, access)
  | exception Unix.Unix_error ((Unix.ENOENT | Unix.ENOTDIR), _, _) -> Absent
;;

let guards_changed bindings =
  match List.exists (fun binding ->
    List.exists (fun (path, before) -> path_binding path <> before) binding.guards) bindings with
  | changed -> Ok changed
  | exception Unix.Unix_error (error, _, _) -> Error (Filesystem error)
  | exception Sys_error _ -> Error (Filesystem Unix.EIO)
;;

let build_plan
    (inventory : unit -> (Dashboard_tla_specs.source_inventory, Dashboard_tla_specs.scan_error) result)
    : (plan, error) result =
  match inventory () with
  | Error error -> Error (Inventory error)
  | Ok inventory ->
    match
      let bindings = Hashtbl.create 32 in
      let stat path =
        match Unix.stat path with
        | status -> Some status
        | exception Unix.Unix_error ((Unix.ENOENT | Unix.ENOTDIR), _, _) -> None
      in
      let add ?(role = Path_guard) ?(guards = []) ~kind ~topics path =
        match stat path with
        | None -> ()
        | Some status when kind = Native.Directory && status.Unix.st_kind <> Unix.S_DIR -> ()
        | Some _ ->
          let guards = if kind = Native.Directory
            then (path, path_binding path) :: guards else guards in
          let path = Unix.realpath path in
          let status = Unix.stat path in
          let identity = status.st_dev, status.st_ino in
          let target = { Native.path; kind; device = status.st_dev; inode = status.st_ino } in
          (match Hashtbl.find_opt bindings identity with
           | None -> Hashtbl.add bindings identity
               { target; topics; role; guards = List.sort_uniq Stdlib.compare guards }
           | Some previous ->
             let target =
               if kind = Native.Directory then { target with kind = Native.Directory }
               else previous.target in
             let role = match role, previous.role with
               | Spec_roster, (Path_guard | Spec_roster)
               | Path_guard, Spec_roster -> Spec_roster
               | Path_guard, Path_guard -> Path_guard in
             Hashtbl.replace bindings identity
               { target; topics = List.sort_uniq Stdlib.compare (previous.topics @ topics);
                 role;
                 guards = List.sort_uniq Stdlib.compare (previous.guards @ guards) })
      in
      let rec guard seen_links path =
        let parent = Filename.dirname path in
        if not (String.equal parent path) then begin
          guard seen_links parent;
          add ~kind:Native.Directory ~topics:[]
            ~guards:[path, path_binding path] parent
        end;
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
      add ~kind:Native.Directory ~topics:[] ~role:Spec_roster inventory.specs_directory;
      List.iter root (inventory.spec_directories @ inventory.spec_files
                      @ inventory.cfg_files @ inventory.expected_log_files);
      List.iter (add ~kind:Native.Directory ~topics:[] ~role:Spec_roster) inventory.spec_directories;
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

let start_with_inventory ~inventory ~after_directory_batch ~sw ~mono_clock ~report =
  let update next =
    let previous = Atomic.exchange state next in
    if previous <> next then report next
  in
  update Starting;
  Eio.Fiber.fork_daemon ~sw (fun () ->
    let current = ref None in
    let scan () = Eio_unix.run_in_systhread (fun () -> build_plan inventory) in
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
        let directories = List.filter (fun binding ->
          binding.target.Native.kind = Native.Directory
          && List.mem binding.target targets) plan in
        let directory_batch () =
          after_directory_batch (List.map (fun binding -> binding.target) directories) in
        let needs_inventory binding = match binding.role with
          | Spec_roster -> true
          | Path_guard -> false in
        if List.exists needs_inventory directories then
          (match scan () with
           | Error error -> directory_batch (); failed retry_initial_s error
           | Ok after ->
             directory_batch ();
             if after <> plan then establish retry_initial_s else observe watcher plan)
        else if directories <> [] then
          (match Eio_unix.run_in_systhread (fun () -> guards_changed directories) with
           | Error error -> directory_batch (); failed retry_initial_s error
           | Ok changed ->
             directory_batch ();
             if changed then establish retry_initial_s else observe watcher plan)
        else observe watcher plan
    in
    Fun.protect ~finally:(fun () -> close_current (); Atomic.set state Stopped)
      (fun () -> establish retry_initial_s))
;;

let start ~sw ~mono_clock ~report =
  start_with_inventory ~inventory:Dashboard_tla_specs.observation_source_inventory
    ~after_directory_batch:(fun _ -> ()) ~sw ~mono_clock ~report
;;

module For_testing = struct
  let start ~inventory ~after_directory_batch ~sw ~mono_clock ~report =
    start_with_inventory ~inventory ~after_directory_batch ~sw ~mono_clock ~report
end
