type t = { directory : string; admissions : string }
let directory t = t.directory
let admissions_path t = t.admissions

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
    let admissions_directory=Filename.concat directory "admissions" in
    Fs_compat.mkdir_p admissions_directory;
    let admissions=Filename.concat admissions_directory "ask-followup.jsonl" in
    Out_channel.with_open_gen [Open_wronly;Open_creat;Open_excl;Open_binary]
      0o600 admissions (fun _ -> ());
    Log.Ring.init_file_sink directory;
    {directory;admissions}
  with
  | store -> Ok store
  | exception (Unix.Unix_error _ | Sys_error _ as exn) ->
    Error (Printexc.to_string exn) in
  let observed_ns=Mtime_clock.elapsed_ns () in
  let level,phase,directory=match outcome with
    | Ok store -> Log.Info,"initialized",Some store.directory
    | Error _ -> Log.Warn,"unavailable",None in
  (* Emission is outside filesystem error conversion: a logging failure must
     not become a second initialization attempt or a different I/O outcome. *)
  Log.Startup.emit_lazy level (fun () ->
    let message=match outcome with
      | Ok store -> "Structured TUI logs initialized: " ^ store.directory
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

let record_admission store ~origin ~request ~admission_started_ns =
  let capture_started_ns=Mtime_clock.elapsed_ns () in
  let result=match Fs_compat.append_jsonl store.admissions (`Assoc [
    "schema_version",`Int 1;
    "event",`String "tui_ask_followup_admission";
    "instance_id",`String (Masc_tui_observation_origin.instance_id origin);
    "request",`Int request;
    "read_admission_started_ns",`Intlit (Int64.to_string admission_started_ns)]) with
    | () -> Ok ()
    | exception (Unix.Unix_error _ | Sys_error _ as exn) -> Error (Printexc.to_string exn) in
  (match result with
   | Ok () -> ()
   | Error detail ->
     let observed_ns=Mtime_clock.elapsed_ns () in
     Log.Startup.emit_lazy Log.Warn ~category:Log.Boundary (fun () ->
       Printf.sprintf "Ask follow-up admission capture unavailable: request=%d: %s" request detail,
       `Assoc [
         "event",`String "tui_ask_followup_admission_failed";
         "schema_version",`Int 1;
         "origin",Masc_tui_observation_origin.to_json origin;
         "request",`Int request;
         "read_admission_started_ns",`Intlit (Int64.to_string admission_started_ns);
         "capture_started_ns",`Intlit (Int64.to_string capture_started_ns);
         "observed_ns",`Intlit (Int64.to_string observed_ns);
         "error",`String detail]));
  result
