(* Read image-backed Keeper volume superblocks on the maintenance pulse and
   report new damage. Volume names do not prove workspace ownership, so this
   observation does not authorize a repair or guest teardown. *)
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

let what_happens_next = function
  | Watch.Work ->
    "Files on this volume may be unreadable or lost, and the Keeper may continue to write. \
     This server does not start automatic filesystem repair because workspace ownership is \
     unverified; verify every owner, stop all usage, and verify a recoverable backup before repair."
  | Watch.Build ->
    "This server does not start automatic filesystem repair because workspace ownership is unverified. \
     A fresh guest boot may still recreate this build volume; verify every owner before proceeding."
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

(* The sweep is normally one fiber. The guard also makes a second sweep
   using this ledger yield its turn, so a notice is claimed before a Board
   write without holding a lock across I/O. It does not coordinate servers. *)
type notice =
  | Publishing
  | Recorded
  | Outcome_unknown of string

type notice_attempt =
  { keeper_name : string
  ; observed_at : float
  ; notice : notice
  }

type notice_entry =
  { current : notice_attempt option
  ; unresolved : notice_attempt list
  }

type notice_ledger =
  { busy : bool Atomic.t
  ; by_volume : (string, notice_entry) Hashtbl.t
  }

let create_notice_ledger () =
  { busy = Atomic.make false; by_volume = Hashtbl.create 16 }
;;

let post ~keeper_name:_ ~volume:_ ~content ~meta_json =
  Board_dispatch.create_post
    ~author:"system"
    ~content
    ~post_kind:Board.System_post
    ~meta_json
    ~visibility:Board.Internal
    ~hearth
    ()
  |> Result.map (fun _ -> ())
  |> Result.map_error Board_types.show_board_error
;;

let post_damage ~post ~keeper_name ~(volume : Watch.volume) ~state ~count ~first ~last =
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

let warn_uncertain ~keeper_name ~volume ~observed_at ~detail =
  Log.Server.error
    "keeper volume damage notice outcome unknown keeper=%s volume=%s observed_at=%.3f: %s; \
     do not assume the Board post was absent"
    keeper_name volume observed_at detail
;;

let report ~notices ~post ~keeper_name ~(volume : Watch.volume)
    ~previous (observation : Watch.observation) =
  let entry =
    match Hashtbl.find_opt notices.by_volume volume.name with
    | Some entry -> entry
    | None -> { current = None; unresolved = [] }
  in
  let remember notice =
    let current = Some { keeper_name; observed_at = observation.observed_at; notice } in
    Hashtbl.replace notices.by_volume volume.name { entry with current }
  in
  match observation.result with
  | Ok { state = Fs.Errors_recorded { count; first; last } as state; _ } ->
    (match entry.current with
     | Some { notice = Publishing | Recorded | Outcome_unknown _; _ } -> ()
     | None ->
       Log.Server.warn
         "keeper volume filesystem errors keeper=%s volume=%s count=%d"
         keeper_name volume.name count;
       (* Claim before entering Board: an exception after its durable write
          must never be read as proof that no post was created. *)
       remember Publishing;
       (match post_damage ~post ~keeper_name ~volume ~state ~count ~first ~last with
        | Ok () -> remember Recorded
        | Error detail -> remember (Outcome_unknown detail)
        | exception (Eio.Cancel.Cancelled _ as exn) ->
          remember (Outcome_unknown "Board publication was interrupted without a receipt");
          raise exn
        | exception exn ->
          remember (Outcome_unknown (Printexc.to_string exn));
          raise exn))
  | Ok { state = Fs.Clean; _ } ->
    (match entry.current with
     | Some { notice = Recorded; _ } ->
       if List.is_empty entry.unresolved
       then Hashtbl.remove notices.by_volume volume.name
       else Hashtbl.replace notices.by_volume volume.name { entry with current = None }
     | Some ({ notice = Outcome_unknown _; _ } as unknown) ->
       Hashtbl.replace notices.by_volume volume.name
         { current = None; unresolved = unknown :: entry.unresolved }
     | Some { notice = Publishing; _ } | None -> ());
    (match previous with
     | Some { Watch.result = Ok { state = Fs.Errors_recorded _; _ }; _ } ->
       Log.Server.info
         "keeper volume filesystem clean again keeper=%s volume=%s"
         keeper_name volume.name
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
         keeper_name volume.name (Watch.failure_to_string failure))
;;

let observe_volume ~notices ~now ~inspect ~read_image ~post
    ~keeper_name (volume : Watch.volume) =
  try
    let previous, observation = Watch.observe ~now:(now ()) ~inspect ~read_image ~volume:volume.name in
    report ~notices ~post ~keeper_name ~volume ~previous observation
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn ->
    Log.Server.warn
      "keeper volume filesystem sweep keeper=%s volume=%s: %s"
      keeper_name volume.name (Printexc.to_string exn)
;;

let workspace_volumes ~(config : Workspace.config) () =
  match Keeper_owner_registry.all_projections ~base_path:config.base_path with
  | Error _ -> []
  | Ok projections ->
    List.concat_map
      (fun (projection : Keeper_owner_reducer.projection) ->
         match projection.meta with
         | None -> []
         | Some meta ->
           (match Watch.volumes_of_durable_meta ~base_path:config.base_path meta with
            | Ok volumes -> List.map (fun volume -> meta.name, volume) volumes
            | Error detail ->
              Log.Server.debug "keeper volume filesystem sweep keeper=%s: %s" meta.name detail;
              []))
      projections
;;

let sweep ~notices ~now ~inspect ~read_image ~post ~warn_uncertain ~volumes =
  if Atomic.compare_and_set notices.busy false true
  then
    Fun.protect
      ~finally:(fun () -> Atomic.set notices.busy false)
      (fun () ->
         let warn_unknown () =
           Hashtbl.iter
             (fun volume { current; unresolved } ->
                let warn { keeper_name; observed_at; notice } =
                  match notice with
                  | Outcome_unknown detail ->
                    warn_uncertain ~keeper_name ~volume ~observed_at ~detail
                  | Publishing | Recorded -> ()
                in
                Option.iter warn current;
                List.iter warn unresolved)
             notices.by_volume
         in
         match
           List.iter
             (fun (keeper_name, volume) ->
                observe_volume ~notices ~now ~inspect ~read_image ~post ~keeper_name volume)
             (volumes ())
         with
         | () -> warn_unknown ()
         | exception (Eio.Cancel.Cancelled _ as exn) ->
           (* The warning is best effort under cancellation. Preserve the
              original cancellation even if its callback also fails. *)
           (match warn_unknown () with
            | () -> ()
            | exception _ -> ());
           raise exn
         | exception exn ->
           (match warn_unknown () with
            | () -> ()
            | exception (Eio.Cancel.Cancelled _ as cancelled) -> raise cancelled
            | exception warning_error ->
              Log.Server.error "keeper volume notice warning failed: %s"
                (Printexc.to_string warning_error));
           raise exn)
;;

let start ~sw ~clock ~config =
  let notices = create_notice_ledger () in
  Server_bootstrap_loops_fiber.fork_logged_fiber
    ~sw
    ~on_error:(Server_bootstrap_loops_fiber.log_server_fiber_crash "keeper_volume_filesystem")
    (fun () ->
       let rec tick () =
         sweep ~notices ~now:Time_compat.now ~inspect ~read_image ~post ~warn_uncertain
           ~volumes:(workspace_volumes ~config);
         Eio.Time.sleep clock Env_config_runtime_services.Timeouts.maintenance_pulse_interval_sec;
         tick ()
       in
       tick ())
;;
