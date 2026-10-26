(* Root-switch-owned maintenance. The Owner mailbox, not a process snapshot,
   admits each attempt. The guest payload supplies the separate build locks.
   Scheduling is isolated across Keepers; an admitted cleanup still owns its
   Keeper's atomic Maintenance slot until it returns. Host CLI cancellation
   alone does not prove that a guest payload has terminated. *)
let read_cleanup_meta ~(config : Workspace.config) ~keeper_name =
  match Keeper_meta_store.read_effective_meta_resolved config keeper_name with
  | Error _ as error -> error
  | Ok None -> Ok None
  | Ok (Some (resolved_name, meta)) ->
    if String.equal resolved_name keeper_name && String.equal meta.name keeper_name
    then Ok (Some meta)
    else Error (Printf.sprintf
      "Keeper cleanup identity mismatch: owner=%s resolved=%s payload=%s"
      keeper_name resolved_name meta.name)

module Keeper_set = Set.Make (String)

type running = Keeper_set.t Atomic.t

let create_running () : running = Atomic.make Keeper_set.empty

let rec reserve running keeper_name =
  let current = Atomic.get running in
  if Keeper_set.mem keeper_name current then false
  else if Atomic.compare_and_set running current (Keeper_set.add keeper_name current)
  then true
  else reserve running keeper_name

let rec release running keeper_name =
  let current = Atomic.get running in
  if not (Atomic.compare_and_set running current (Keeper_set.remove keeper_name current))
  then release running keeper_name

(* Reserve before forking so a second pulse cannot schedule the same Keeper.
   Both cancellation paths release the pure reservation: a refused fork, or
   an entered child whose callback must finish teardown before it leaves. *)
let schedule ~sw ~running ~keeper_name run =
  Eio.Switch.check sw;
  if reserve running keeper_name then (
    try
      Eio.Switch.check sw;
      Eio.Fiber.fork ~sw (fun () ->
        Fun.protect
          ~finally:(fun () -> release running keeper_name)
          (fun () -> Eio.Fiber.yield (); run ()))
    with exn ->
      release running keeper_name;
      raise exn)

let sweep ~sw ~running ~(config : Workspace.config) () =
  match Keeper_owner_registry.all_projections ~base_path:config.base_path with
  | Error _ -> ()
  | Ok projections ->
    List.iter
      (fun (projection : Keeper_owner_reducer.projection) ->
        match projection.meta with
        | None -> ()
        | Some meta -> schedule ~sw ~running ~keeper_name:meta.name (fun () ->
          let run () =
            match read_cleanup_meta ~config ~keeper_name:meta.name with
            | Error detail -> Error detail
            | Ok None -> Ok None
            | Ok (Some current) ->
              Keeper_turn_sandbox_runtime.cleanup_attached_builds ~config ~meta:current
                ~retention_sec:(Runtime_params.get Runtime_settings.keeper_build_cleanup_retention_sec) ()
          in
          try match Keeper_owner_registry.run_maintenance_if_idle ~defer_to_chat:true
                  ~base_path:config.base_path ~keeper_name:meta.name run with
          | Ok (`Ran (Error detail)) ->
            Log.Server.warn "Keeper build cleanup keeper=%s: %s" meta.name detail
          | Ok (`Ran (Ok (Some report))) ->
            let cleaned = report.Keeper_turn_sandbox_runtime.cleaned
            and failed = report.failed in
            if cleaned > 0 || failed > 0 then
              Log.Server.info "Keeper build cleanup keeper=%s cleaned=%d failed=%d"
                meta.name cleaned failed
          | Error _ | Ok (`Busy _) | Ok (`Ran (Ok None)) -> ()
          with
          | Eio.Cancel.Cancelled _ as exn -> raise exn
          | exn -> Log.Server.warn "Keeper build cleanup keeper=%s: %s"
                     meta.name (Printexc.to_string exn)))
      projections

let start ~sw ~clock ~config =
  let running = create_running () in
  Server_bootstrap_loops_fiber.fork_logged_fiber ~sw
    ~on_error:(Server_bootstrap_loops_fiber.log_server_fiber_crash "keeper_build_cleanup")
    (fun () ->
      let rec tick () =
        Eio.Time.sleep clock (Runtime_params.get Runtime_settings.keeper_build_cleanup_interval_sec);
        if Runtime_params.get Runtime_settings.keeper_build_cleanup_enabled
        then sweep ~sw ~running ~config ();
        tick ()
      in
      tick ())
