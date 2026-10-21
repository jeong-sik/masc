let initialize ~base_path =
  let started_ns=Mtime_clock.elapsed_ns () in
  let outcome=match
    let root=Filename.concat
      (Filename.concat (Common.masc_dir_from_base_path ~base_path) "logs") "tui" in
    Fs_compat.mkdir_p root;
    (* A fresh directory prevents PID reuse, another TUI, or server logs from
       being imported into this process's ring. Filename owns uniqueness and
       private directory permissions; no path is derived from event contents. *)
    let directory=Filename.temp_dir ~temp_dir:root
      (Printf.sprintf "session-%d-" (Unix.getpid ())) "" in
    Log.Ring.init_file_sink directory;
    directory
  with
  | directory -> Ok directory
  | exception (Unix.Unix_error _ | Sys_error _ as exn) ->
    Error (Printexc.to_string exn) in
  let observed_ns=Mtime_clock.elapsed_ns () in
  let level,phase,directory=match outcome with
    | Ok directory -> Log.Info,"initialized",Some directory
    | Error _ -> Log.Warn,"unavailable",None in
  (* Emission is outside filesystem error conversion: a logging failure must
     not become a second initialization attempt or a different I/O outcome. *)
  Log.Startup.emit_lazy level (fun () ->
    let message=match outcome with
      | Ok path -> "Structured TUI logs initialized: " ^ path
      | Error detail ->
        "Structured TUI log storage unavailable; retaining ring and stderr mirror: " ^ detail in
    message,`Assoc [
      "event",`String "tui_observation_store";
      "phase",`String phase;
      "pid",`Int (Unix.getpid ());
      "directory",(match directory with Some path -> `String path | None -> `Null);
      "initialization_started_ns",`Intlit (Int64.to_string started_ns);
      "observed_ns",`Intlit (Int64.to_string observed_ns)]);
  outcome
