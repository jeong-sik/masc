(* Root-switch-owned maintenance. The Owner mailbox, not a process snapshot,
   admits each attempt. The guest payload supplies the separate build locks. *)
let sweep ~(config : Workspace.config) () =
  match Keeper_owner_registry.all_projections ~base_path:config.base_path with
  | Error _ -> ()
  | Ok projections ->
    List.iter
      (fun (projection : Keeper_owner_reducer.projection) ->
        match projection.meta with
        | None -> ()
        | Some meta ->
          let run () =
            match Keeper_meta_store.read_meta config meta.name with
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
                     meta.name (Printexc.to_string exn))
      projections

let start ~sw ~clock ~config =
  Server_bootstrap_loops_fiber.fork_logged_fiber ~sw
    ~on_error:(Server_bootstrap_loops_fiber.log_server_fiber_crash "keeper_build_cleanup")
    (fun () ->
      let rec tick () =
        Eio.Time.sleep clock (Runtime_params.get Runtime_settings.keeper_build_cleanup_interval_sec);
        if Runtime_params.get Runtime_settings.keeper_build_cleanup_enabled then sweep ~config ();
        tick ()
      in
      tick ())
