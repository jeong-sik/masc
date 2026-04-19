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
}

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
      (try Unix.close st.handle.stderr_fd with _ -> ())
    end
  end

let spawn ~keeper ~argv ~cwd ~envp ~timeout_sec =
  match Process_eio.spawn_detached ~argv ~env:envp ~cwd with
  | Error e -> Error (Spawn_failed e)
  | Ok handle ->
      try_set_nonblock handle.stdout_fd;
      try_set_nonblock handle.stderr_fd;
      let tid = fresh_id () in
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
         Ok ()
       with e -> Error (Kill_failed (Printexc.to_string e)))

let list ~keeper =
  with_reg (fun () ->
    Hashtbl.fold
      (fun tid st acc -> if st.keeper = keeper then tid :: acc else acc)
      registry [])

let reap_orphans ~base_path:_ = 0
