let read_available fd buffer eof =
  let chunk = Bytes.create 4096 in
  let rec drain () =
    try
      let length = Unix.read fd chunk 0 (Bytes.length chunk) in
      if length = 0
      then eof := true
      else begin
        Buffer.add_subbytes buffer chunk 0 length;
        drain ()
      end
    with
    | Unix.Unix_error ((Unix.EAGAIN | Unix.EWOULDBLOCK), _, _) -> ()
    | Unix.Unix_error (Unix.EINTR, _, _) -> drain ()
  in
  if not !eof then drain ()
;;

let run_argv_with_status_split ?timeout_sec ~env = function
  | [] -> Unix.WEXITED 127, "", "argv must not be empty"
  | command :: _ as argv ->
    let stdout_r, stdout_w = Unix.pipe () in
    let stderr_r, stderr_w = Unix.pipe () in
    let pid =
      Unix.create_process_env
        command
        (Array.of_list argv)
        env
        Unix.stdin
        stdout_w
        stderr_w
    in
    Unix.close stdout_w;
    Unix.close stderr_w;
    Unix.set_nonblock stdout_r;
    Unix.set_nonblock stderr_r;
    let stdout = Buffer.create 128 in
    let stderr = Buffer.create 128 in
    let stdout_eof = ref false in
    let stderr_eof = ref false in
    let status = ref None in
    let started_at = Unix.gettimeofday () in
    let deadline = Option.map (fun seconds -> started_at +. seconds) timeout_sec in
    let poll_status () =
      match Unix.waitpid [ Unix.WNOHANG ] pid with
      | 0, _ -> ()
      | _, value -> status := Some value
      | exception Unix.Unix_error (Unix.EINTR, _, _) -> ()
      | exception Unix.Unix_error (Unix.ECHILD, _, _) ->
        status := Some (Unix.WEXITED 127)
    in
    let kill_and_reap () =
      (try Unix.kill pid Sys.sigkill with Unix.Unix_error _ -> ());
      let rec reap () =
        try snd (Unix.waitpid [] pid) with
        | Unix.Unix_error (Unix.EINTR, _, _) -> reap ()
        | Unix.Unix_error (Unix.ECHILD, _, _) -> Unix.WEXITED 127
      in
      reap ()
    in
    let timed_out () =
      match deadline with
      | Some deadline -> Unix.gettimeofday () >= deadline
      | None -> false
    in
    let rec loop () =
      read_available stdout_r stdout stdout_eof;
      read_available stderr_r stderr stderr_eof;
      poll_status ();
      if Option.is_some !status && !stdout_eof && !stderr_eof
      then ()
      else if Option.is_none !status && timed_out ()
      then begin
        status := Some (Unix.WEXITED 124);
        ignore (kill_and_reap ())
      end
      else begin
        let readable =
          (if !stdout_eof then [] else [ stdout_r ])
          @ (if !stderr_eof then [] else [ stderr_r ])
        in
        let delay =
          match deadline with
          | None -> 0.01
          | Some deadline -> min 0.01 (max 0.0 (deadline -. Unix.gettimeofday ()))
        in
        ignore (Unix.select readable [] [] delay);
        loop ()
      end
    in
    (try
       loop ();
       Unix.close stdout_r;
       Unix.close stderr_r;
       Option.value ~default:(Unix.WEXITED 127) !status,
       Buffer.contents stdout,
       Buffer.contents stderr
     with
     | exn ->
       (try Unix.close stdout_r with Unix.Unix_error _ -> ());
       (try Unix.close stderr_r with Unix.Unix_error _ -> ());
       (try ignore (kill_and_reap ()) with Unix.Unix_error _ -> ());
       raise exn)
;;

let run_argv_with_status_split_streaming
    ?timeout_sec
    ~env
    ~on_stdout_chunk
    ~on_stderr_chunk
    argv
  =
  let status, stdout, stderr =
    run_argv_with_status_split ?timeout_sec ~env argv
  in
  if not (String.equal stdout "") then on_stdout_chunk stdout;
  if not (String.equal stderr "") then on_stderr_chunk stderr;
  status, stdout, stderr
;;
