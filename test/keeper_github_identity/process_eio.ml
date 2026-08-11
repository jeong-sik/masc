let read_all channel =
  let buffer = Buffer.create 256 in
  (try
     while true do
       Buffer.add_channel buffer channel 4096
     done
   with
   | End_of_file -> ());
  Buffer.contents buffer
;;

let run_argv_with_status_split ?timeout_sec:_ ~env = function
  | [] -> Unix.WEXITED 127, "", "argv must not be empty"
  | command :: _ as argv ->
    let stdout_channel, stdin_channel, stderr_channel =
      Unix.open_process_args_full command (Array.of_list argv) env
    in
    let stdout = read_all stdout_channel in
    let stderr = read_all stderr_channel in
    let status =
      Unix.close_process_full (stdout_channel, stdin_channel, stderr_channel)
    in
    status, stdout, stderr
;;

let run_argv_with_status_split_streaming
    ?timeout_sec
    ~env
    ~on_stdout_chunk
    ~on_stderr_chunk
    argv
  =
  let status, stdout, stderr = run_argv_with_status_split ?timeout_sec ~env argv in
  if not (String.equal stdout "") then on_stdout_chunk stdout;
  if not (String.equal stderr "") then on_stderr_chunk stderr;
  status, stdout, stderr
;;
