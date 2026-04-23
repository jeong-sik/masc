type acquire_result =
  | Acquired
  | Already_running of { pid : int }

let pid_lock_path port = Printf.sprintf "/tmp/masc-%d.pid" port

let base_path_lock_path base_path =
  Filename.concat (Filename.concat base_path Common.masc_dirname) "server-owner.pid"

let close_quietly fd =
  try Unix.close fd with
  | Unix.Unix_error _ -> ()

let pid_exists pid =
  try
    Unix.kill pid 0;
    true
  with
  | Unix.Unix_error (Unix.ESRCH, _, _) -> false
  | Unix.Unix_error (Unix.EPERM, _, _) -> true

let sleep_poll seconds =
  if seconds > 0.0 then
    ignore (Unix.select [] [] [] seconds)

let wait_for_pid_exit ?(poll_interval_sec = 0.1) ~timeout_sec pid =
  let deadline = Unix.gettimeofday () +. max 0.0 timeout_sec in
  let rec loop () =
    if not (pid_exists pid) then
      true
    else
      let remaining = deadline -. Unix.gettimeofday () in
      if remaining <= 0.0 then
        false
      else begin
        sleep_poll (Float.min poll_interval_sec remaining);
        loop ()
      end
  in
  loop ()

let rec write_all fd payload off len =
  if len > 0 then
    let written = Unix.write_substring fd payload off len in
    if written = 0 then
      raise End_of_file
    else
      write_all fd payload (off + written) (len - written)

let status_line_from_buffer buf =
  let contents = Buffer.contents buf in
  match String.index_opt contents '\n' with
  | None -> None
  | Some idx ->
      Some (String.sub contents 0 idx |> String.trim)

let status_line_is_healthy line =
  let parts =
    String.split_on_char ' ' line
    |> List.filter (fun value -> String.trim value <> "")
  in
  match parts with
  | version :: code :: _ ->
      (String.equal version "HTTP/1.1" || String.equal version "HTTP/1.0")
      && String.equal code "200"
  | _ -> false

let contains_substring ~needle haystack =
  String_util.contains_substring haystack needle

let looks_like_server_command command =
  List.exists
    (fun marker -> contains_substring ~needle:marker command)
    [ "main_eio"; "masc-mcp" ]

let process_command pid =
  match
    Masc_exec.Exec_gate.run_argv_with_status
      ~actor:"system/startup_takeover"
      ~raw_source:(Printf.sprintf "ps -p %d -o command=" pid)
      ~summary:"startup takeover ps probe"
      ~timeout_sec:1.0
      [ "ps"; "-p"; string_of_int pid; "-o"; "command=" ]
  with
  | Unix.WEXITED 0, output -> (
      let trimmed = String.trim output in
      if trimmed = "" then None else Some trimmed)
  | _ -> None

let read_status_line fd ~timeout_sec =
  let deadline = Unix.gettimeofday () +. max 0.0 timeout_sec in
  let scratch = Bytes.create 256 in
  let buf = Buffer.create 128 in
  let rec loop () =
    match status_line_from_buffer buf with
    | Some line -> Some line
    | None ->
        let remaining = deadline -. Unix.gettimeofday () in
        if remaining <= 0.0 then
          None
        else
          let readable, _, _ = Unix.select [ fd ] [] [] remaining in
          if readable = [] then
            None
          else
            match Unix.read fd scratch 0 (Bytes.length scratch) with
            | 0 -> status_line_from_buffer buf
            | count ->
                Buffer.add_subbytes buf scratch 0 count;
                loop ()
  in
  loop ()

let probe_liveness ?(timeout_sec = 3.0) ?(path = Server_health_paths.liveness) port =
  Safe_ops.protect ~default:false (fun () ->
    let socket = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
    Fun.protect
      ~finally:(fun () -> close_quietly socket)
      (fun () ->
        (* Keep the startup probe in-process so takeover logic does not depend on
           shelling out to curl before the Eio runtime is initialized. *)
        Unix.connect socket (Unix.ADDR_INET (Unix.inet_addr_loopback, port));
        let request =
          Printf.sprintf
            "GET %s HTTP/1.1\r\nHost: 127.0.0.1:%d\r\nConnection: close\r\n\r\n"
            path port
        in
        write_all socket request 0 (String.length request);
        match read_status_line socket ~timeout_sec with
        | Some line -> status_line_is_healthy line
        | None -> false))

let read_pid_file path =
  Safe_ops.protect ~default:None (fun () ->
    let ic = open_in path in
    Fun.protect
      ~finally:(fun () -> close_in_noerr ic)
      (fun () -> Some (In_channel.input_all ic)))

let parsed_pid path =
  match read_pid_file path with
  | Some data -> (
      match String.trim data |> int_of_string_opt with
      | Some pid when pid > 0 -> Some pid
      | _ -> None)
  | None -> None

let register_pid_cleanup ~path ~pid =
  at_exit (fun () ->
      match parsed_pid path with
      | Some current when current = pid ->
          Safe_ops.protect ~default:() (fun () -> Sys.remove path)
      | Some _ -> ()
      | None -> ())

let write_pid_file path pid =
  let oc = open_out path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr oc)
    (fun () -> Printf.fprintf oc "%d\n" pid)

let claim_pid_file path =
  Fs_compat.mkdir_p (Filename.dirname path);
  let pid = Unix.getpid () in
  write_pid_file path pid;
  register_pid_cleanup ~path ~pid;
  Acquired

let acquire_pid_lock
    ?lock_path
    ?(probe_timeout_sec = 3.0)
    ?(term_timeout_sec = 1.0)
    ?(kill_wait_sec = 0.5)
    ?(poll_interval_sec = 0.1)
    port =
  let path =
    match lock_path with
    | Some value -> value
    | None -> pid_lock_path port
  in
  (match read_pid_file path with
  | Some data -> (
      match String.trim data |> int_of_string_opt with
      | Some pid when pid > 0 ->
          if pid_exists pid then
            if probe_liveness ~timeout_sec:probe_timeout_sec port then
              Already_running { pid }
            else if (
              match process_command pid with
              | Some command -> not (looks_like_server_command command)
              | None -> true)
            then begin
              Log.legacy_stderr ~level:Log.Error ~module_name:"Server"
                (Printf.sprintf
                   "[FATAL] PID %d is alive but does not look like a masc-mcp server; refusing takeover"
                   pid);
              Already_running { pid }
            end
            else begin
              Log.legacy_stderr ~level:Log.Warn ~module_name:"Server"
                (Printf.sprintf
                   "[WARN] PID %d alive but unresponsive on port %d; sending SIGTERM to reclaim"
                   pid port);
              Safe_ops.protect ~default:() (fun () ->
                Unix.kill pid Sys.sigterm);
              if not (wait_for_pid_exit ~poll_interval_sec
                        ~timeout_sec:term_timeout_sec pid)
              then begin
                Log.legacy_stderr ~level:Log.Warn ~module_name:"Server"
                  (Printf.sprintf
                     "[WARN] PID %d did not exit; sending SIGKILL" pid);
                Safe_ops.protect ~default:() (fun () ->
                  Unix.kill pid Sys.sigkill);
                if not (wait_for_pid_exit ~poll_interval_sec
                          ~timeout_sec:kill_wait_sec pid)
                then
                  Log.legacy_stderr ~level:Log.Warn ~module_name:"Server"
                    (Printf.sprintf
                       "[WARN] PID %d still appears alive after SIGKILL escalation"
                       pid)
              end;
              Acquired
            end
          else begin
            Log.legacy_stderr ~level:Log.Warn ~module_name:"Server"
              (Printf.sprintf
                 "[WARN] Removing stale PID file (PID %d no longer running)"
                 pid);
            Acquired
          end
      | _ ->
          Log.legacy_stderr ~level:Log.Warn ~module_name:"Server"
            "[WARN] Invalid PID file contents, overwriting";
          Acquired)
  | None -> Acquired)
  |> function
  | Already_running _ as result -> result
  | Acquired -> claim_pid_file path

let acquire_base_path_lock ?lock_path base_path =
  let path =
    match lock_path with
    | Some value -> value
    | None -> base_path_lock_path base_path
  in
  (match read_pid_file path with
  | Some data -> (
      match String.trim data |> int_of_string_opt with
      | Some pid when pid > 0 ->
          if pid_exists pid then
            match process_command pid with
            | Some command when looks_like_server_command command ->
                Already_running { pid }
            | Some _ | None ->
                Log.legacy_stderr ~level:Log.Error ~module_name:"Server"
                  (Printf.sprintf
                     "[FATAL] PID %d owns %s but does not look like a masc-mcp server; refusing takeover"
                     pid path);
                Already_running { pid }
          else begin
            Log.legacy_stderr ~level:Log.Warn ~module_name:"Server"
              (Printf.sprintf
                 "[WARN] Removing stale base-path owner file (PID %d no longer running)"
                 pid);
            Acquired
          end
      | _ ->
          Log.legacy_stderr ~level:Log.Warn ~module_name:"Server"
            "[WARN] Invalid base-path owner file contents, overwriting";
          Acquired)
  | None -> Acquired)
  |> function
  | Already_running _ as result -> result
  | Acquired -> claim_pid_file path
