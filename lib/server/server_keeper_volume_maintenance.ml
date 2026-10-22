(* RFC keeper-volume-filesystem-repair §3.2-3.3: on the maintenance pulse,
   read the superblock of every image-backed Keeper volume, keep the latest
   read for Keeper status, tell the operator once when a volume starts
   recording errors, and repair it the next time its Keeper is idle. *)
module Fs = Keeper_volume_filesystem
module Watch = Keeper_volume_filesystem_watch
module Repair = Keeper_volume_repair
module Volume_map = Map.Make (String)

let hearth = "sandbox"
let notice_kind = "keeper_volume_filesystem_damage"
let repair_started_kind = "keeper_volume_repair_started"
let repair_finished_kind = "keeper_volume_repair"

let inspect ~volume =
  let timeout_sec = Env_config_sandbox.Shell_timeout.timeout_sec ~bucket:Io () in
  match
    Process_eio.run_argv_with_status_split
      ~timeout_sec
      (Keeper_sandbox_microvm.apple_volume_inspect_argv ~volume_name:volume)
  with
  | Unix.WEXITED 0, stdout, _ ->
    (match Yojson.Safe.from_string stdout with
     | json -> Ok json
     | exception Yojson.Json_error detail -> Error ("volume inspect printed invalid JSON: " ^ detail))
  | ((Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _) as status), _, stderr ->
    Error
      (Printf.sprintf
         "%s: %s"
         (Keeper_sandbox_exec_failure.status_label status)
         (String.trim stderr))
;;

let read_image ~path = Eio_unix.run_in_systhread (fun () -> Fs.read_image ~path)

let site_line label = function
  | None -> Printf.sprintf "%s error: not recorded." label
  | Some (site : Fs.error_site) ->
    Printf.sprintf
      "%s error: %s in %s:%d (%s, inode %d)."
      label
      (Masc_domain.iso8601_of_unix_seconds site.at)
      site.func
      site.line
      (Fs.error_code_to_string site.code)
      site.inode
;;

let what_happens_next = function
  | Watch.Work ->
    "Files on this volume may be unreadable or lost until e2fsck repairs it; the server repairs \
     it the next time the Keeper is idle."
  | Watch.Build ->
    "The next fresh boot recreates this build volume; the server removes the Keeper's guests the \
     next time it is idle."
;;

let damage_content ~keeper_name ~(volume : Watch.volume) ~count ~first ~last =
  String.concat
    "\n"
    [ Printf.sprintf
        "Keeper %s: volume %s has ext4 errors recorded by the guest kernel (%d errors)."
        keeper_name
        volume.name
        count
    ; site_line "First" first
    ; site_line "Last" last
    ; what_happens_next volume.kind
    ]
;;

let post ~keeper_name ~volume ~content ~meta_json =
  match
    Board_dispatch.create_post
      ~author:"system"
      ~content
      ~post_kind:Board.System_post
      ~meta_json
      ~visibility:Board.Internal
      ~hearth
      ()
  with
  | Ok _ -> ()
  | Error error ->
    Log.Server.error
      "keeper volume post failed keeper=%s volume=%s: %s"
      keeper_name
      volume
      (Board_types.show_board_error error)
;;

let post_damage ~keeper_name ~(volume : Watch.volume) ~state ~count ~first ~last =
  post
    ~keeper_name
    ~volume:volume.name
    ~content:(damage_content ~keeper_name ~volume ~count ~first ~last)
    ~meta_json:
      (`Assoc
          [ "kind", `String notice_kind
          ; "keeper", `String keeper_name
          ; "volume", `String volume.name
          ; "filesystem", Fs.state_to_yojson state
          ])
;;

let report ~keeper_name ~(volume : Watch.volume) ~previous (observation : Watch.observation) =
  match observation.result with
  | Ok { state = Fs.Errors_recorded { count; first; last } as state; _ } ->
    if Watch.damage_appeared ~previous observation
    then (
      Log.Server.warn
        "keeper volume filesystem errors keeper=%s volume=%s count=%d"
        keeper_name
        volume.name
        count;
      post_damage ~keeper_name ~volume ~state ~count ~first ~last)
  | Ok { state = Fs.Clean; _ } ->
    (match previous with
     | Some { Watch.result = Ok { state = Fs.Errors_recorded _; _ }; _ } ->
       Log.Server.info
         "keeper volume filesystem clean again keeper=%s volume=%s"
         keeper_name
         volume.name
     | Some
         { Watch.result =
             ( Ok { state = Fs.Clean; _ }
             | Error (Watch.Inspect_refused _ | Watch.Inspect_unparsed _ | Watch.Image_unreadable _) )
         ; _
         }
     | None -> ())
  | Error failure ->
    (match previous with
     | Some { Watch.result = Error previous_failure; _ } when previous_failure = failure -> ()
     | Some
         { Watch.result =
             ( Ok { state = Fs.Clean | Fs.Errors_recorded _; _ }
             | Error (Watch.Inspect_refused _ | Watch.Inspect_unparsed _ | Watch.Image_unreadable _) )
         ; _
         }
     | None ->
       Log.Server.warn
         "keeper volume filesystem unread keeper=%s volume=%s: %s"
         keeper_name
         volume.name
         (Watch.failure_to_string failure))
;;

(* §3.3: one repair per error episode. [Running] while its fiber holds or
   waits for the lane; [Attempted] once a repair ran, until a clean read ends
   the episode. No mark means the volume may be repaired. *)
type repair_mark =
  | Running
  | Attempted

let repair_marks : repair_mark Volume_map.t Atomic.t = Atomic.make Volume_map.empty

let rec update_marks change =
  let current = Atomic.get repair_marks in
  if not (Atomic.compare_and_set repair_marks current (change current)) then update_marks change
;;

let rec claim_repair volume =
  let current = Atomic.get repair_marks in
  match Volume_map.find_opt volume current with
  | Some (Running | Attempted) -> false
  | None ->
    Atomic.compare_and_set repair_marks current (Volume_map.add volume Running current)
    || claim_repair volume
;;

let end_episode volume =
  update_marks (fun marks ->
    match Volume_map.find_opt volume marks with
    | Some Attempted -> Volume_map.remove volume marks
    | Some Running | None -> marks)
;;

(* The effects are arguments so the marks can be checked without a lane: a
   repair that ran ends the episode's attempts, and a Keeper that was busy,
   or a lane that refused, leaves the volume to the next pulse. *)
let schedule_repair ~fork ~run_in_lane ~on_finished ~on_lane_error ~volume =
  if claim_repair volume
  then
    fork
      ~on_error:(fun () -> update_marks (Volume_map.remove volume))
      (fun () ->
         match run_in_lane () with
         | Ok (`Ran receipt) ->
           update_marks (Volume_map.add volume Attempted);
           on_finished receipt
         | Ok (`Busy _) -> update_marks (Volume_map.remove volume)
         | Error error ->
           update_marks (Volume_map.remove volume);
           on_lane_error error)
;;

let helper_cleanup_failed ~keeper_name ~volume detail =
  Log.Server.warn
    "keeper volume repair helper cleanup keeper=%s volume=%s: %s"
    keeper_name
    volume
    detail
;;

let remove_stale_repair_helper ~keeper_name =
  Keeper_sandbox_microvm.remove_apple_volume_repair
    ~run:(fun ~timeout_sec argv -> Process_eio.run_argv_with_status_split ~timeout_sec argv)
    ~timeout_sec:(Env_config_sandbox.Shell_timeout.timeout_sec ~bucket:Io ())
    ~remove_timeout_sec:(Env_config_sandbox.Runtime.microvm_remove_timeout_sec ())
    ~keeper_name
;;

(* A helper a dead server left can still hold the volume, so it goes with the
   guests, before the read that decides whether to repair. *)
let teardown ~config ~meta ~keeper_name () =
  Result.bind (Keeper_turn_sandbox_runtime.teardown_keeper_sandbox ~config ~meta ()) (fun () ->
    remove_stale_repair_helper ~keeper_name)
;;

let repair_started_content ~keeper_name ~volume ~helper ~backup =
  String.concat
    "\n"
    [ Printf.sprintf "Keeper %s: e2fsck is repairing volume %s while the Keeper is idle." keeper_name volume
    ; Printf.sprintf "The image was cloned to %s first." backup
    ; Printf.sprintf "Follow it with `container logs %s`; `container stop %s` ends it." helper helper
    ; "The Keeper runs no turn until the repair ends."
    ]
;;

let post_repair_started ~keeper_name ~volume ~image () =
  let helper = Keeper_sandbox_microvm.volume_repair_name ~keeper_name in
  let backup = Repair.backup_path ~image in
  post
    ~keeper_name
    ~volume
    ~content:(repair_started_content ~keeper_name ~volume ~helper ~backup)
    ~meta_json:
      (`Assoc
          [ "kind", `String repair_started_kind
          ; "keeper", `String keeper_name
          ; "volume", `String volume
          ; "helper", `String helper
          ; "backup", `String backup
          ])
;;

let helper_run ~(config : Workspace.config) ~meta ~keeper_name ~volume ~image =
  match Keeper_sandbox_image_resolver.for_keeper ~base_path:config.base_path meta with
  | Error error -> Error (Keeper_sandbox_image_resolver.error_to_string error)
  | Ok pinned ->
    Ok
      (fun () ->
         Keeper_sandbox_microvm.repair_apple_volume
           ~run:(fun ~timeout_sec argv -> Process_eio.run_argv_with_status_split ~timeout_sec argv)
           ~run_helper:(fun argv -> Process_eio.run_argv_with_status_split argv)
           ~on_start:(post_repair_started ~keeper_name ~volume ~image)
           ~on_cleanup_error:(helper_cleanup_failed ~keeper_name ~volume)
           ~timeout_sec:(Env_config_sandbox.Shell_timeout.timeout_sec ~bucket:Io ())
           ~remove_timeout_sec:(Env_config_sandbox.Runtime.microvm_remove_timeout_sec ())
           ~keeper_name
           ~volume_name:volume
           ~image:pinned.reference
         |> Result.map (fun (run : Keeper_sandbox_microvm.volume_repair_run) ->
           { Repair.status = run.status
           ; stdout = run.stdout
           ; stderr = run.stderr
           ; cleanup = run.cleanup
           }))
;;

let clone ~source ~target = Eio_unix.run_in_systhread (fun () -> Repair.clone_image ~source ~target)

(* Runs inside the Keeper's maintenance lane. The meta is read here, once, so
   the teardown and the helper image both follow the Keeper's TOML as it is
   now. *)
let repair_volume ~(config : Workspace.config) ~keeper_name ~(volume : Watch.volume) ~image () =
  let meta =
    match Keeper_meta_store.read_effective_meta config keeper_name with
    | Ok (Some meta) -> Ok meta
    | Ok None -> Error "the Keeper has no meta"
    | Error detail -> Error detail
  in
  Repair.repair
    ~now:Time_compat.now
    ~repair_id:(Random_id.uuid_v7 ())
    ~helper:(Result.bind meta (fun meta -> helper_run ~config ~meta ~keeper_name ~volume:volume.name ~image))
    ~backup_exists:(fun ~path -> Sys.file_exists path)
    ~teardown:(fun () -> Result.bind meta (fun meta -> teardown ~config ~meta ~keeper_name ()))
    ~read_image
    ~clone
    ~keeper:keeper_name
    ~volume
    ~image
;;

let rollback_lines (receipt : Repair.receipt) =
  match receipt.backup with
  | None -> []
  | Some backup ->
    [ Printf.sprintf
        "To roll back, stop the Keeper's guest and move %s back to %s."
        backup
        receipt.image
    ; "The next automatic repair of this volume waits until that backup is removed."
    ]
;;

let follow_up_lines (receipt : Repair.receipt) =
  match receipt.outcome with
  | Repair.Backup_present ->
    [ Printf.sprintf
        "Check %s and remove it once it is no longer needed; the next automatic repair waits for that."
        (Repair.backup_path ~image:receipt.image)
    ]
  | Repair.Helper_unavailable _ | Repair.Teardown_refused _ | Repair.Not_needed
  | Repair.Unreadable_before _ | Repair.Backup_unavailable _ | Repair.Helper_refused _
  | Repair.Repaired | Repair.Repair_incomplete _ | Repair.Unreadable_after _
  | Repair.Recreated_at_next_boot -> []
;;

let cleanup_lines (receipt : Repair.receipt) =
  match receipt.helper_cleanup with
  | None -> []
  | Some detail -> [ "The helper was not removed after it ran: " ^ detail ]
;;

let post_repair_finished ~(receipt : Repair.receipt) ~receipt_path =
  let receipt_line =
    match receipt_path with
    | Ok path -> "Receipt: " ^ path
    | Error detail -> "The receipt was not written: " ^ detail
  in
  post
    ~keeper_name:receipt.keeper
    ~volume:receipt.volume
    ~content:
      (String.concat
         "\n"
         ([ Printf.sprintf
              "Keeper %s: volume %s %s."
              receipt.keeper
              receipt.volume
              (Repair.outcome_to_string receipt.outcome)
          ]
          @ follow_up_lines receipt
          @ rollback_lines receipt
          @ cleanup_lines receipt
          @ [ receipt_line ]))
    ~meta_json:
      (`Assoc
          [ "kind", `String repair_finished_kind
          ; "keeper", `String receipt.keeper
          ; "volume", `String receipt.volume
          ; "repair_id", `String receipt.repair_id
          ; "outcome", Repair.outcome_to_yojson receipt.outcome
          ; "backup", Json_util.string_opt_to_json receipt.backup
          ; "receipt", Json_util.string_opt_to_json (Result.to_option receipt_path)
          ])
;;

let finish_repair ~(config : Workspace.config) (receipt : Repair.receipt) =
  let receipt_path = Repair.write_receipt ~masc_dir:(Workspace.masc_dir config) receipt in
  (match receipt_path with
   | Ok _ -> ()
   | Error detail ->
     Log.Server.error
       "keeper volume repair receipt keeper=%s volume=%s: %s"
       receipt.keeper
       receipt.volume
       detail);
  (match receipt.outcome with
   | Repair.Repaired | Repair.Not_needed | Repair.Recreated_at_next_boot ->
     Log.Server.info
       "keeper volume repair keeper=%s volume=%s: %s"
       receipt.keeper
       receipt.volume
       (Repair.outcome_to_string receipt.outcome)
   | Repair.Helper_unavailable _ | Repair.Backup_present | Repair.Teardown_refused _
   | Repair.Unreadable_before _ | Repair.Backup_unavailable _ | Repair.Helper_refused _
   | Repair.Repair_incomplete _ | Repair.Unreadable_after _ ->
     Log.Server.warn
       "keeper volume repair keeper=%s volume=%s: %s"
       receipt.keeper
       receipt.volume
       (Repair.outcome_to_string receipt.outcome));
  post_repair_finished ~receipt ~receipt_path
;;

(* A repair can wait on e2fsck for as long as it takes, so it runs on its own
   fiber and the sweep goes on reading every other volume. *)
let start_repair ~sw ~(config : Workspace.config) ~keeper_name ~(volume : Watch.volume) ~image =
  schedule_repair
    ~fork:(fun ~on_error run ->
      Server_bootstrap_loops_fiber.fork_logged_fiber
        ~sw
        ~on_error:(fun exn ->
          on_error ();
          Server_bootstrap_loops_fiber.log_server_fiber_crash "keeper_volume_repair" exn)
        run)
    ~run_in_lane:(fun () ->
      Keeper_owner_registry.run_maintenance_if_idle
        ~defer_to_chat:true
        ~base_path:config.base_path
        ~keeper_name
        (repair_volume ~config ~keeper_name ~volume ~image))
    ~on_finished:(finish_repair ~config)
    ~on_lane_error:(fun error ->
      Log.Server.warn
        "keeper volume repair keeper=%s volume=%s: %s"
        keeper_name
        volume.name
        (Keeper_owner_registry.command_error_to_string error))
    ~volume:volume.name
;;

let act_on ~schedule ~(volume : Watch.volume) (observation : Watch.observation) =
  match observation.result with
  | Ok { state = Fs.Errors_recorded _; source } -> schedule ~volume ~image:source
  | Ok { state = Fs.Clean; _ } -> end_episode volume.name
  | Error (Watch.Inspect_refused _ | Watch.Inspect_unparsed _ | Watch.Image_unreadable _) -> ()
;;

let observe_volume ~sw ~config ~keeper_name (volume : Watch.volume) =
  try
    let previous, observation =
      Watch.observe ~now:(Time_compat.now ()) ~inspect ~read_image ~volume:volume.name
    in
    report ~keeper_name ~volume ~previous observation;
    act_on ~schedule:(start_repair ~sw ~config ~keeper_name) ~volume observation
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn ->
    Log.Server.warn
      "keeper volume filesystem sweep keeper=%s volume=%s: %s"
      keeper_name
      volume.name
      (Printexc.to_string exn)
;;

let sweep ~sw ~(config : Workspace.config) () =
  match Keeper_owner_registry.all_projections ~base_path:config.base_path with
  | Error _ -> ()
  | Ok projections ->
    List.iter
      (fun (projection : Keeper_owner_reducer.projection) ->
         match projection.meta with
         | None -> ()
         | Some meta ->
           (match Watch.volumes_of_durable_meta ~base_path:config.base_path meta with
            | Ok volumes -> List.iter (observe_volume ~sw ~config ~keeper_name:meta.name) volumes
            | Error detail ->
              (* Keeper status reports the invalid profile; until it loads
                 there is no volume to name. *)
              Log.Server.debug "keeper volume filesystem sweep keeper=%s: %s" meta.name detail))
      projections
;;

let start ~sw ~clock ~config =
  Server_bootstrap_loops_fiber.fork_logged_fiber
    ~sw
    ~on_error:(Server_bootstrap_loops_fiber.log_server_fiber_crash "keeper_volume_filesystem")
    (fun () ->
       let rec tick () =
         sweep ~sw ~config ();
         Eio.Time.sleep clock Env_config_runtime_services.Timeouts.maintenance_pulse_interval_sec;
         tick ()
       in
       tick ())
;;
