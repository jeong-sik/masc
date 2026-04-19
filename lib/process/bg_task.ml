(* Tick 6a: pull-based implementation.

   Design choice: the first pass stays free of Eio fibers / threads.
   Instead of push-based drainers, [read] pulls whatever is pending on
   the child's stdout/stderr pipes via non-blocking [Unix.read] each
   time it is called.  Rationale:
   - Simpler lifecycle: no long-lived switch to manage, no fiber
     leakage surface.
   - Matches the MCP request/response cadence — the LLM polls by
     calling [keeper_bash_output], so there is always a natural
     trigger for draining.
   - Back-pressure: the OS pipe buffer (~64 KB on Linux, larger on
     macOS) absorbs short silences; long silences block the child on
     write until the next pull.  Acceptable for Tick 6a; Tick 7 will
     layer on a push-based ring-buffer + backing file so slow
     readers don't stall producers.

   The [~sw] and [~env] parameters of {!spawn} are accepted for API
   stability but ignored today; they return when Tick 7 introduces
   the daemon switch. *)

type task_id = string

let task_id_to_string t = t

let task_id_of_string_exn s =
  if s = "" then invalid_arg "Bg_task.task_id_of_string_exn: empty handle";
  s

type snapshot = {
  stdout_since : string;
  stderr_since : string;
  closed : bool;
  status : Unix.process_status option;
  bytes_dropped_stdout : int;
  bytes_dropped_stderr : int;
}

type spawn_error =
  | Spawn_failed of string
  | Too_many_tasks of { keeper : string; limit : int }
  | Invalid_cwd of string

type read_error =
  | Unknown_task of task_id
  | Read_failed of string

type kill_error =
  | Unknown_task_kill of task_id
  | Kill_failed of string

type state = {
  handle : Process_eio.detached_handle;
  keeper : string;
  timeout_sec : float;
  stdout_buf : Buffer.t;
  stderr_buf : Buffer.t;
  mutable status : Unix.process_status option;
  mutable closed : bool;
  mutable stdout_eof : bool;
  mutable stderr_eof : bool;
  pid_file : string option;
      (** Full path to the persistence sidecar when
          [~base_path] was supplied at spawn. Deleted on close/kill. *)
}

(* Tick 7: PID-file helpers. Path convention:
     <base_path>/.masc/keeper/<keeper>/bg/<task_id>.pid
   Contents: three lines — pid, pgid, started_at (unix seconds).
   Written best-effort; failures are logged but do not abort spawn. *)

let bg_dir_of ~base_path ~keeper =
  Filename.concat (Filename.concat (Filename.concat base_path ".masc")
    (Filename.concat "keeper" keeper)) "bg"

let pid_file_of ~base_path ~keeper ~task_id =
  Filename.concat (bg_dir_of ~base_path ~keeper) (task_id ^ ".pid")

let rec ensure_dir path =
  if Sys.file_exists path then ()
  else begin
    let parent = Filename.dirname path in
    if parent <> path then ensure_dir parent;
    (try Unix.mkdir path 0o755
     with Unix.Unix_error (Unix.EEXIST, _, _) -> ())
  end

let try_write_pid_file path ~pid ~pgid ~started_at =
  try
    ensure_dir (Filename.dirname path);
    let oc = open_out_gen [ Open_wronly; Open_creat; Open_trunc ] 0o644 path in
    Printf.fprintf oc "%d\n%d\n%f\n" pid pgid started_at;
    close_out oc
  with _ -> ()

let try_delete_pid_file = function
  | None -> ()
  | Some path -> (try Unix.unlink path with _ -> ())

let registry : (string, state) Hashtbl.t = Hashtbl.create 16
let registry_mu = Mutex.create ()
let id_counter = ref 0

let with_reg f =
  Mutex.lock registry_mu;
  match f () with
  | v -> Mutex.unlock registry_mu; v
  | exception e -> Mutex.unlock registry_mu; raise e

let fresh_id () =
  with_reg (fun () ->
    incr id_counter;
    Printf.sprintf "bgt-%d-%06d-%d"
      (int_of_float (Unix.gettimeofday ()))
      !id_counter
      (Unix.getpid ()))

let try_set_nonblock fd = try Unix.set_nonblock fd with _ -> ()

(* [drain_fd_to_buf buf fd] reads every byte currently available on
   [fd] without blocking. Returns [true] if EOF was observed. *)
let drain_fd_to_buf buf fd =
  let chunk = Bytes.create 4096 in
  let rec loop () =
    let readable =
      try
        let r, _, _ = Unix.select [ fd ] [] [] 0.0 in
        r
      with _ -> []
    in
    if readable = [] then false
    else
      match Unix.read fd chunk 0 (Bytes.length chunk) with
      | 0 -> true
      | n -> Buffer.add_subbytes buf chunk 0 n; loop ()
      | exception Unix.Unix_error ((Unix.EAGAIN | Unix.EWOULDBLOCK), _, _) -> false
      | exception Unix.Unix_error (Unix.EINTR, _, _) -> loop ()
      | exception _ -> true
  in
  loop ()

(* Called under [registry_mu]. Drains pipes, reaps if exited, kills
   on timeout. *)
let poll_state st =
  if st.closed then ()
  else begin
    if not st.stdout_eof then begin
      let eof = drain_fd_to_buf st.stdout_buf st.handle.stdout_fd in
      st.stdout_eof <- eof
    end;
    if not st.stderr_eof then begin
      let eof = drain_fd_to_buf st.stderr_buf st.handle.stderr_fd in
      st.stderr_eof <- eof
    end;
    (match st.status with
     | Some _ -> ()
     | None ->
         (match Unix.waitpid [ Unix.WNOHANG ] st.handle.pid with
          | 0, _ -> ()
          | _, s -> st.status <- Some s
          | exception Unix.Unix_error (Unix.ECHILD, _, _) ->
              st.status <- Some (Unix.WEXITED 0)
          | exception _ -> ()));
    if st.status = None
       && st.timeout_sec > 0.0
       && Unix.gettimeofday () -. st.handle.started_at > st.timeout_sec
    then begin
      Process_eio.tree_kill ~pgid:st.handle.pgid
        ~signal:Sys.sigterm ~grace_sec:2.0;
      (match Unix.waitpid [ Unix.WNOHANG ] st.handle.pid with
       | 0, _ -> ()
       | _, s -> st.status <- Some s
       | exception _ -> ())
    end;
    if st.status <> None && st.stdout_eof && st.stderr_eof then begin
      st.closed <- true;
      (try Unix.close st.handle.stdout_fd with _ -> ());
      (try Unix.close st.handle.stderr_fd with _ -> ());
      try_delete_pid_file st.pid_file
    end
  end

let spawn ?base_path ~keeper ~argv ~cwd ~envp ~timeout_sec () =
  match Process_eio.spawn_detached ~argv ~env:envp ~cwd with
  | Error e -> Error (Spawn_failed e)
  | Ok handle ->
      try_set_nonblock handle.stdout_fd;
      try_set_nonblock handle.stderr_fd;
      let tid = fresh_id () in
      let pid_file =
        match base_path with
        | None | Some "" -> None
        | Some bp ->
            let path = pid_file_of ~base_path:bp ~keeper ~task_id:tid in
            try_write_pid_file path
              ~pid:handle.pid
              ~pgid:handle.pgid
              ~started_at:handle.started_at;
            Some path
      in
      let st =
        {
          handle;
          keeper;
          timeout_sec;
          stdout_buf = Buffer.create 4096;
          stderr_buf = Buffer.create 4096;
          status = None;
          closed = false;
          stdout_eof = false;
          stderr_eof = false;
          pid_file;
        }
      in
      with_reg (fun () -> Hashtbl.replace registry tid st);
      Ok tid

let bufsub buf since =
  let len = Buffer.length buf in
  if since < 0 || since >= len then ""
  else Buffer.sub buf since (len - since)

let read tid ~since_stdout ~since_stderr =
  let st_opt = with_reg (fun () -> Hashtbl.find_opt registry tid) in
  match st_opt with
  | None -> Error (Unknown_task tid)
  | Some st ->
      (try
         with_reg (fun () -> poll_state st);
         Ok
           {
             stdout_since = bufsub st.stdout_buf since_stdout;
             stderr_since = bufsub st.stderr_buf since_stderr;
             closed = st.closed;
             status = st.status;
             bytes_dropped_stdout = 0;
             bytes_dropped_stderr = 0;
           }
       with e -> Error (Read_failed (Printexc.to_string e)))

let kill tid ~signal ~grace_sec =
  let st_opt = with_reg (fun () -> Hashtbl.find_opt registry tid) in
  match st_opt with
  | None -> Error (Unknown_task_kill tid)
  | Some st ->
      (try
         Process_eio.tree_kill ~pgid:st.handle.pgid ~signal ~grace_sec;
         with_reg (fun () -> poll_state st);
         (* Best-effort PID file cleanup: if poll_state did not
            observe EOF yet (slow-closing FDs), at least unlink the
            sidecar so the next reap cycle does not flag a live
            task as orphan. *)
         if st.closed then try_delete_pid_file st.pid_file;
         Ok ()
       with e -> Error (Kill_failed (Printexc.to_string e)))

let list ~keeper =
  with_reg (fun () ->
    Hashtbl.fold
      (fun tid st acc -> if st.keeper = keeper then tid :: acc else acc)
      registry [])

(* Directory walk helpers — avoid Filename.Infix / extra deps. *)

let safe_readdir dir =
  try Array.to_list (Sys.readdir dir) with _ -> []

let is_dir p = try Sys.is_directory p with _ -> false

let read_pid_file path =
  try
    let ic = open_in path in
    Fun.protect ~finally:(fun () -> close_in_noerr ic) (fun () ->
      let pid = int_of_string (String.trim (input_line ic)) in
      let pgid = int_of_string (String.trim (input_line ic)) in
      Some (pid, pgid))
  with _ -> None

let pid_is_live pid =
  try Unix.kill pid 0; true
  with
  | Unix.Unix_error (Unix.ESRCH, _, _) -> false
  (* EPERM means pid exists but we lack permission — still considered
     live for orphan detection. *)
  | Unix.Unix_error (Unix.EPERM, _, _) -> true
  | _ -> false

let live_task_ids () =
  with_reg (fun () ->
    Hashtbl.fold (fun tid _ acc -> tid :: acc) registry [])

(* Scan <base_path>/.masc/keeper/*/bg/*.pid, SIGKILL any pgroup whose
   task_id is absent from the live registry, and delete the sidecar.
   Stale files whose leader pid no longer exists are also removed.
   Returns the count of files removed. *)
let reap_orphans ~base_path =
  if base_path = "" then 0
  else
    let keeper_root =
      Filename.concat (Filename.concat base_path ".masc") "keeper"
    in
    if not (is_dir keeper_root) then 0
    else
      let live = live_task_ids () in
      let reaped = ref 0 in
      List.iter (fun keeper ->
        let bg_dir = Filename.concat (Filename.concat keeper_root keeper) "bg" in
        if is_dir bg_dir then
          List.iter (fun entry ->
            if Filename.check_suffix entry ".pid" then begin
              let task_id = Filename.chop_suffix entry ".pid" in
              let path = Filename.concat bg_dir entry in
              let live_here = List.mem task_id live in
              if live_here then ()
              else begin
                (match read_pid_file path with
                 | Some (pid, pgid) when pid_is_live pid ->
                     (* Orphan: live pgroup, no registry entry. *)
                     Process_eio.tree_kill ~pgid
                       ~signal:Sys.sigterm ~grace_sec:1.0
                 | _ -> ());
                (try Unix.unlink path with _ -> ());
                incr reaped
              end
            end)
            (safe_readdir bg_dir))
        (safe_readdir keeper_root);
      !reaped
