(* Production spawn wrappers around [Process_eio].  The actor/source/summary
   fields are observability context; they do not authorize or classify the
   command. *)

let run_argv ~actor:_ ~raw_source:_ ~summary:_
    ?timeout_sec ?env argv =
  Process_eio.run_argv ?timeout_sec ?env argv

let run_argv_with_status ~actor:_ ~raw_source:_ ~summary:_
    ?timeout_sec ?env ?cwd argv =
  Process_eio.run_argv_with_status ?timeout_sec ?env ?cwd argv

let run_argv_with_status_split ~actor:_ ~raw_source:_ ~summary:_
    ?timeout_sec ?env ?cwd argv =
  Process_eio.run_argv_with_status_split ?timeout_sec ?env ?cwd argv

let run_argv_with_status_split_streaming ~actor:_ ~raw_source:_ ~summary:_
    ?timeout_sec ?env ?cwd
    ~on_stdout_chunk ~on_stderr_chunk argv =
  Process_eio.run_argv_with_status_split_streaming
    ?timeout_sec
    ?env
    ?cwd
    ~on_stdout_chunk
    ~on_stderr_chunk
    argv

let run_argv_with_stdin_and_status ~actor:_ ~raw_source:_ ~summary:_
    ?timeout_sec ?env ?cwd ~stdin_content argv =
  Process_eio.run_argv_with_stdin_and_status ?timeout_sec ?env ?cwd
    ~stdin_content argv

let run_argv_with_stdin_and_status_split ~actor:_ ~raw_source:_ ~summary:_
    ?timeout_sec ?env ?cwd ?on_stdout_chunk
    ?on_stderr_chunk ~stdin_content argv =
  Process_eio.run_argv_with_stdin_and_status_split ?timeout_sec ?env ?cwd
    ?on_stdout_chunk ?on_stderr_chunk ~stdin_content argv

let run_argv_pipeline_with_status_split ~actor:_ ~raw_source:_ ~summary:_
    ?timeout_sec ?on_stdout_chunk
    ?on_stderr_chunk stages =
  Process_eio.run_argv_pipeline_with_status_split ?timeout_sec
    ?on_stdout_chunk ?on_stderr_chunk stages
