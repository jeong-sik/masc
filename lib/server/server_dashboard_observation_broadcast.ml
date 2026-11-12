module Commit = Dashboard_observation_commit

module Changes = Server_workspace_invalidation.Make (struct
  type t = Commit.change
  let compare = Stdlib.compare
end)

let install ~state ~sw ~mono_clock =
  Server_observation_refresh.install_scoped ~state ~sw
    ~install:(fun ~scope ~sw ~is_current ->
      let base_path = scope.Mcp_server.config.base_path in
      let publish payload =
        if is_current () then (
          (* The series REST cache and native query reader share this exact
             family. Drop all filtered windows before either consumer wakes. *)
          if payload.Sse_event.Types.topic = `Tool_metrics
          then Server_dashboard_http_core_cache.invalidate_tool_metrics_series ~base_path;
          if is_current () then
            Workspace_dataset_event.announce_dashboard_observation
              ~base_path ~scope:payload.scope payload.topic)
      in
      let enqueue = Changes.start ~sw ~mono_clock ~publish:(function
        | Commit.Process topic -> publish { Sse_event.Types.topic; scope = `Workspace }
        | Commit.Workspace { base_path = written_owner; payload } ->
            (* A writer may use a symlink or a relative spelling. Resolving
               that owner is deferred until this switch-owned publication;
               it must not suspend an already-committed store mutation. *)
            if is_current ()
               && String.equal (Fs_compat.realpath_lenient written_owner)
                    (Fs_compat.realpath_lenient base_path)
            then publish payload)
      in
      let unsubscribe_commits = Commit.subscribe enqueue in
      let unsubscribe_metrics = Tool_metrics.subscribe_written
          (fun () -> enqueue (Commit.Process `Tool_metrics)) in
      Eio.Switch.on_release sw (fun () ->
        unsubscribe_commits ();
        unsubscribe_metrics ()))
;;
