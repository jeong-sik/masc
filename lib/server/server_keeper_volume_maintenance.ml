(* RFC keeper-volume-filesystem-repair §3.2: on the maintenance pulse, read
   the superblock of every image-backed Keeper volume, keep the latest read
   for Keeper status, and tell the operator once when a volume starts
   recording errors. The read is the host image; nothing runs in the guest. *)
module Fs = Keeper_volume_filesystem
module Watch = Keeper_volume_filesystem_watch

let hearth = "sandbox"
let notice_kind = "keeper_volume_filesystem_damage"

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

let damage_content ~keeper_name ~volume ~count ~first ~last =
  String.concat
    "\n"
    [ Printf.sprintf
        "Keeper %s: volume %s has ext4 errors recorded by the guest kernel (%d errors)."
        keeper_name
        volume
        count
    ; site_line "First" first
    ; site_line "Last" last
    ; "Files on this volume may be unreadable or lost until e2fsck repairs it."
    ]
;;

let post_damage ~keeper_name (observation : Watch.observation) ~state ~count ~first ~last =
  match
    Board_dispatch.create_post
      ~author:"system"
      ~content:(damage_content ~keeper_name ~volume:observation.volume ~count ~first ~last)
      ~post_kind:Board.System_post
      ~meta_json:
        (`Assoc
            [ "kind", `String notice_kind
            ; "keeper", `String keeper_name
            ; "volume", `String observation.volume
            ; "filesystem", Fs.state_to_yojson state
            ])
      ~visibility:Board.Internal
      ~hearth
      ()
  with
  | Ok _ -> ()
  | Error error ->
    Log.Server.error
      "keeper volume damage post failed keeper=%s volume=%s: %s"
      keeper_name
      observation.volume
      (Board_types.show_board_error error)
;;

let report ~keeper_name ~previous (observation : Watch.observation) =
  match observation.result with
  | Ok (Fs.Errors_recorded { count; first; last } as state) ->
    if Watch.damage_appeared ~previous observation
    then (
      Log.Server.warn
        "keeper volume filesystem errors keeper=%s volume=%s count=%d"
        keeper_name
        observation.volume
        count;
      post_damage ~keeper_name observation ~state ~count ~first ~last)
  | Ok Fs.Clean ->
    (match previous with
     | Some { Watch.result = Ok (Fs.Errors_recorded _); _ } ->
       Log.Server.info
         "keeper volume filesystem clean again keeper=%s volume=%s"
         keeper_name
         observation.volume
     | Some
         { Watch.result =
             ( Ok Fs.Clean
             | Error (Watch.Inspect_refused _ | Watch.Inspect_unparsed _ | Watch.Image_unreadable _) )
         ; _
         }
     | None -> ())
  | Error failure ->
    (match previous with
     | Some { Watch.result = Error previous_failure; _ } when previous_failure = failure -> ()
     | Some
         { Watch.result =
             ( Ok (Fs.Clean | Fs.Errors_recorded _)
             | Error (Watch.Inspect_refused _ | Watch.Inspect_unparsed _ | Watch.Image_unreadable _) )
         ; _
         }
     | None ->
       Log.Server.warn
         "keeper volume filesystem unread keeper=%s volume=%s: %s"
         keeper_name
         observation.volume
         (Watch.failure_to_string failure))
;;

let observe_volume ~keeper_name volume =
  try
    let previous, observation =
      Watch.observe ~now:(Time_compat.now ()) ~inspect ~read_image ~volume
    in
    report ~keeper_name ~previous observation
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn ->
    Log.Server.warn
      "keeper volume filesystem sweep keeper=%s volume=%s: %s"
      keeper_name
      volume
      (Printexc.to_string exn)
;;

let sweep ~(config : Workspace.config) () =
  match Keeper_owner_registry.all_projections ~base_path:config.base_path with
  | Error _ -> ()
  | Ok projections ->
    List.iter
      (fun (projection : Keeper_owner_reducer.projection) ->
         match projection.meta with
         | None -> ()
         | Some meta ->
           (match Watch.volumes_of_durable_meta ~base_path:config.base_path meta with
            | Ok volumes -> List.iter (observe_volume ~keeper_name:meta.name) volumes
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
         sweep ~config ();
         Eio.Time.sleep clock Env_config_runtime_services.Timeouts.maintenance_pulse_interval_sec;
         tick ()
       in
       tick ())
;;
