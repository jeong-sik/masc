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

let task_id_of_string s =
  if s = "" then Error "empty handle" else Ok s

let task_id_of_string_exn s =
  match task_id_of_string s with
  | Ok task_id -> task_id
  | Error msg -> invalid_arg ("Bg_task.task_id_of_string_exn: " ^ msg)

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
  mutable stdout_base_offset : int;
  mutable stderr_base_offset : int;
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
  Filename.concat
    (Filename.concat
       (Common.masc_dir_from_base_path ~base_path)
       (Filename.concat "keeper" keeper))
    "bg"

let pid_file_of ~base_path ~keeper ~task_id =
  Filename.concat (bg_dir_of ~base_path ~keeper) (task_id ^ ".pid")

let sidecar_failure_observer :
    ((site:string -> exn -> unit) option) Atomic.t =
  Atomic.make None

let set_sidecar_failure_observer f =
  Atomic.set sidecar_failure_observer (Some f)

let observe_sidecar_failure ~site exn =
  match exn with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
      Log.Misc.warn "bg_task PID sidecar %s failed: %s"
        site (Printexc.to_string exn);
      (match Atomic.get sidecar_failure_observer with
       | None -> ()
       | Some observe ->
           (try observe ~site exn with
            | Eio.Cancel.Cancelled _ as e -> raise e
            | observer_exn ->
                Log.Misc.warn "bg_task PID sidecar observer failed: %s"
                  (Printexc.to_string observer_exn)))

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
    Fun.protect
      ~finally:(fun () -> close_out_noerr oc)
      (fun () ->
        Printf.fprintf oc "%d\n%d\n%f\n" pid pgid started_at;
        flush oc)
  with exn -> observe_sidecar_failure ~site:"write" exn

let delete_pid_file path =
  try
    Unix.unlink path;
    true
  with
  | Unix.Unix_error (Unix.ENOENT, _, _) -> false
  | exn ->
      observe_sidecar_failure ~site:"unlink" exn;
      false

let try_delete_pid_file = function
  | None -> ()
  | Some path -> ignore (delete_pid_file path : bool)

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

let try_set_nonblock fd = Safe_ops.protect ~default:() (fun () -> Unix.set_nonblock fd)

let shell_ring_line_limit () =
  match Sys.getenv_opt "MASC_KEEPER_SHELL_RING_LINES" with
  | Some raw -> (
      match int_of_string_opt (String.trim raw) with
      | Some n when n >= 0 -> n
      | _ -> 5000)
  | None -> 5000

let retained_start_for_last_lines s ~limit =
  if limit <= 0 then String.length s
  else
    let line_count = ref 0 in
    String.iter (fun ch -> if ch = '\n' then incr line_count) s;
    if String.length s > 0 && s.[String.length s - 1] <> '\n' then
      incr line_count;
    if !line_count <= limit then
      0
    else
      let drop_newlines = !line_count - limit in
      let seen = ref 0 in
      let start = ref 0 in
      let i = ref 0 in
      while !i < String.length s && !seen < drop_newlines do
        if s.[!i] = '\n' then begin
          incr seen;
          start := !i + 1
        end;
        incr i
      done;
      !start

let trim_buffer_to_ring buf base_offset =
  let limit = shell_ring_line_limit () in
  let contents = Buffer.contents buf in
  let drop_len = retained_start_for_last_lines contents ~limit in
  if drop_len <= 0 then base_offset
  else begin
    Buffer.clear buf;
    if drop_len < String.length contents then
      Buffer.add_substring buf contents drop_len (String.length contents - drop_len);
    base_offset + drop_len
  end

(* [drain_fd_to_buf buf fd] reads every byte currently available on
   [fd] without blocking. Returns [true] if EOF was observed. *)
let drain_fd_to_buf buf fd =
  let chunk = Bytes.create 4096 in
  let rec loop () =
    let readable =
      Safe_ops.protect ~default:[] (fun () ->
        let r, _, _ = Unix.select [ fd ] [] [] 0.0 in
        r)
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
      st.stdout_base_offset <-
        trim_buffer_to_ring st.stdout_buf st.stdout_base_offset;
      st.stdout_eof <- eof
    end;
    if not st.stderr_eof then begin
      let eof = drain_fd_to_buf st.stderr_buf st.handle.stderr_fd in
      st.stderr_base_offset <-
        trim_buffer_to_ring st.stderr_buf st.stderr_base_offset;
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
      Safe_ops.protect ~default:() (fun () -> Unix.close st.handle.stdout_fd);
      Safe_ops.protect ~default:() (fun () -> Unix.close st.handle.stderr_fd);
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
          stdout_base_offset = 0;
          stderr_base_offset = 0;
          status = None;
          closed = false;
          stdout_eof = false;
          stderr_eof = false;
          pid_file;
        }
      in
      with_reg (fun () -> Hashtbl.replace registry tid st);
      Ok tid

let bufsub buf ~base_offset since =
  let len = Buffer.length buf in
  if since < base_offset then
    Buffer.contents buf
  else
    let local_since = since - base_offset in
    if local_since < 0 || local_since >= len then ""
    else Buffer.sub buf local_since (len - local_since)

let bytes_dropped_since ~base_offset since =
  if since < base_offset then base_offset - since else 0

let read tid ~since_stdout ~since_stderr =
  let st_opt = with_reg (fun () -> Hashtbl.find_opt registry tid) in
  match st_opt with
  | None -> Error (Unknown_task tid)
  | Some st ->
      (try
         with_reg (fun () -> poll_state st);
         Ok
           {
             stdout_since =
               bufsub st.stdout_buf ~base_offset:st.stdout_base_offset
                 since_stdout;
             stderr_since =
               bufsub st.stderr_buf ~base_offset:st.stderr_base_offset
                 since_stderr;
             closed = st.closed;
             status = st.status;
             bytes_dropped_stdout =
               bytes_dropped_since ~base_offset:st.stdout_base_offset
                 since_stdout;
             bytes_dropped_stderr =
               bytes_dropped_since ~base_offset:st.stderr_base_offset
                 since_stderr;
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

let list_with_started_at ~keeper =
  with_reg (fun () ->
    Hashtbl.fold
      (fun tid st acc ->
        if st.keeper = keeper then (tid, st.handle.started_at) :: acc
        else acc)
      registry [])

(* Directory walk helpers — avoid Filename.Infix / extra deps. *)

let safe_readdir dir =
  try Array.to_list (Sys.readdir dir) with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
      if Sys.file_exists dir then
        observe_sidecar_failure ~site:"readdir" exn;
      []

let is_dir p =
  try (Unix.stat p).Unix.st_kind = Unix.S_DIR with
  | Unix.Unix_error (Unix.ENOENT, _, _) -> false
  | exn ->
      observe_sidecar_failure ~site:"is_dir" exn;
      false

let read_pid_file path =
  try
    let ic = open_in path in
    Fun.protect ~finally:(fun () -> close_in_noerr ic) (fun () ->
      let input_line_opt ic =
        try Some (input_line ic) with End_of_file -> None
      in
      let pid_line = input_line_opt ic in
      let pgid_line = input_line_opt ic in
      let parse_int line =
        Option.bind (Option.map String.trim line) Stdlib.int_of_string_opt
      in
      match parse_int pid_line, parse_int pgid_line with
      | Some pid, Some pgid -> Some (pid, pgid)
      | _ ->
          observe_sidecar_failure ~site:"read_parse"
            (Failure (Printf.sprintf "invalid PID sidecar: %s" path));
          None)
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
      if Sys.file_exists path then
        observe_sidecar_failure ~site:"read"
          (Failure
             (Printf.sprintf "read PID sidecar %s: %s" path
                (Printexc.to_string exn)));
      None

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
      Filename.concat
        (Common.masc_dir_from_base_path ~base_path)
        "keeper"
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
                 | None | Some (_, _) -> ());
                if delete_pid_file path then
                  incr reaped
              end
            end)
            (safe_readdir bg_dir))
        (safe_readdir keeper_root);
      !reaped
