let lit s = Masc_exec.Shell_ir.Lit (s, Masc_exec.Shell_ir.default_meta)

let fail msg = raise (Failure msg)

let sleep seconds =
  Eio_main.run @@ fun env -> Eio.Time.sleep (Eio.Stdenv.clock env) seconds

let bin s =
  match Masc_exec.Exec_program.of_string s with
  | Ok bin -> bin
  | Error (`Unknown name) -> fail ("unknown exec program: " ^ s)

let simple ?sandbox ?(redirects = []) executable args =
  let open Masc_exec.Shell_ir in
  { bin = bin executable
  ; args = List.map lit args
  ; env = []
  ; cwd = None
  ; redirects
  (* DET-OK: test helper default keeps sandbox choice explicit at call sites. *)
  ; sandbox = Option.value sandbox ~default:(Masc_exec.Sandbox_target.host ())
  }

let assert_live_first_callback ~label ~first_stdout_at ~elapsed =
  match !first_stdout_at with
  | None -> fail (label ^ ": expected live stdout callback")
  | Some t ->
      if not (t < elapsed -. 0.12) then
        fail
          (Printf.sprintf
             "%s: expected first stdout callback before dispatch completion \
              (first=%.3fs elapsed=%.3fs)"
             label t elapsed)

let test_docker_simple_runner_callback_is_live () =
  (* NDT-OK: this regression asserts callback ordering across dispatch. *)
  let start = Unix.gettimeofday () in
  let first_stdout_at = ref None in
  let stdout_chunks = ref [] in
  let stderr_chunks = ref [] in
  let on_output_chunk = function
    | `Stdout chunk ->
        if Option.is_none !first_stdout_at then
          (* NDT-OK: record callback arrival time relative to dispatch start. *)
          first_stdout_at := Some (Unix.gettimeofday () -. start);
        stdout_chunks := chunk :: !stdout_chunks
    | `Stderr chunk -> stderr_chunks := chunk :: !stderr_chunks
  in
  let runner ~on_stdout_chunk ~on_stderr_chunk ~stdin_content ~argv ~env:_ ~cwd:_ =
    assert (stdin_content = None);
    assert (argv = [ "printf"; "ignored" ]);
    Option.iter (fun f -> f "first") on_stdout_chunk;
    sleep 0.30;
    Option.iter (fun f -> f "second") on_stdout_chunk;
    Option.iter (fun f -> f "err") on_stderr_chunk;
    Unix.WEXITED 0, "firstsecond", "err"
  in
  let docker_sandbox =
    Masc_exec.Sandbox_target.docker ~image:"fake-docker" ~runner ()
  in
  let result =
    Masc_exec.Exec_dispatch.dispatch_simple
      ~on_output_chunk
      (simple ~sandbox:docker_sandbox "printf" [ "ignored" ])
  in
  (* NDT-OK: compare dispatch completion time to first callback arrival. *)
  let elapsed = Unix.gettimeofday () -. start in
  assert (result.status = Unix.WEXITED 0);
  assert (result.stdout = "firstsecond");
  assert (result.stderr = "err");
  assert (String.concat "" (List.rev !stdout_chunks) = "firstsecond");
  assert (String.concat "" (List.rev !stderr_chunks) = "err");
  assert_live_first_callback ~label:"docker simple" ~first_stdout_at ~elapsed

let test_docker_pipeline_runner_callback_is_live () =
  (* NDT-OK: this regression asserts callback ordering across dispatch. *)
  let start = Unix.gettimeofday () in
  let first_stdout_at = ref None in
  let stdout_chunks = ref [] in
  let on_output_chunk = function
    | `Stdout chunk ->
        if Option.is_none !first_stdout_at then
          (* NDT-OK: record callback arrival time relative to dispatch start. *)
          first_stdout_at := Some (Unix.gettimeofday () -. start);
        stdout_chunks := chunk :: !stdout_chunks
    | `Stderr _ -> ()
  in
  let runner ~on_stdout_chunk:_ ~on_stderr_chunk:_ ~stdin_content:_ ~argv:_ ~env:_ ~cwd:_ =
    Unix.WEXITED 9, "", "simple runner should not be used"
  in
  let pipeline_runner ~on_stdout_chunk ~on_stderr_chunk:_ ~stages =
    assert (List.length stages = 2);
    Option.iter (fun f -> f "pipe-first") on_stdout_chunk;
    sleep 0.30;
    Option.iter (fun f -> f "pipe-second") on_stdout_chunk;
    Unix.WEXITED 0, "pipe-firstpipe-second", ""
  in
  let docker_sandbox =
    Masc_exec.Sandbox_target.docker
      ~image:"fake-docker"
      ~runner
      ~pipeline_runner
      ()
  in
  let result =
    Masc_exec.Exec_dispatch.dispatch_pipeline
      ~on_output_chunk
      [ Masc_exec.Shell_ir.Simple (simple ~sandbox:docker_sandbox "printf" [ "x" ])
      ; Masc_exec.Shell_ir.Simple (simple ~sandbox:docker_sandbox "wc" [ "-c" ])
      ]
  in
  (* NDT-OK: compare dispatch completion time to first callback arrival. *)
  let elapsed = Unix.gettimeofday () -. start in
  assert (result.status = Unix.WEXITED 0);
  assert (result.stdout = "pipe-firstpipe-second");
  assert (String.concat "" (List.rev !stdout_chunks) = "pipe-firstpipe-second");
  assert_live_first_callback ~label:"docker pipeline" ~first_stdout_at ~elapsed

let test_docker_decomposed_fallback_callback_is_live () =
  (* NDT-OK: this regression asserts callback ordering across dispatch. *)
  let start = Unix.gettimeofday () in
  let first_stdout_at = ref None in
  let stdout_chunks = ref [] in
  let stderr_chunks = ref [] in
  let on_output_chunk = function
    | `Stdout chunk ->
        if Option.is_none !first_stdout_at then
          (* NDT-OK: record callback arrival time relative to dispatch start. *)
          first_stdout_at := Some (Unix.gettimeofday () -. start);
        stdout_chunks := chunk :: !stdout_chunks
    | `Stderr chunk -> stderr_chunks := chunk :: !stderr_chunks
  in
  let runner ~on_stdout_chunk ~on_stderr_chunk ~stdin_content ~argv ~env:_ ~cwd:_ =
    match argv, stdin_content with
    | [ "printf"; "mid" ], None ->
        Option.iter (fun f -> f "mid") on_stdout_chunk;
        Option.iter (fun f -> f "stage1-err") on_stderr_chunk;
        Unix.WEXITED 0, "mid", "stage1-err"
    | [ "cat" ], Some "mid" ->
        Option.iter (fun f -> f "final-first") on_stdout_chunk;
        sleep 0.30;
        Option.iter (fun f -> f "final-second") on_stdout_chunk;
        Option.iter (fun f -> f "stage2-err") on_stderr_chunk;
        Unix.WEXITED 0, "final-firstfinal-second", "stage2-err"
    | _ -> fail "unexpected decomposed fallback stage"
  in
  let docker_sandbox =
    Masc_exec.Sandbox_target.docker ~image:"fake-docker" ~runner ()
  in
  let result =
    Masc_exec.Exec_dispatch.dispatch_pipeline
      ~on_output_chunk
      [ Masc_exec.Shell_ir.Simple
          (simple ~sandbox:docker_sandbox "printf" [ "mid" ])
      ; Masc_exec.Shell_ir.Simple (simple ~sandbox:docker_sandbox "cat" [])
      ]
  in
  (* NDT-OK: compare dispatch completion time to first callback arrival. *)
  let elapsed = Unix.gettimeofday () -. start in
  assert (result.status = Unix.WEXITED 0);
  assert (result.stdout = "final-firstfinal-second");
  assert (result.stderr = "stage1-errstage2-err");
  assert (String.concat "" (List.rev !stdout_chunks) = "final-firstfinal-second");
  assert (String.concat "" (List.rev !stderr_chunks) = "stage1-errstage2-err");
  assert_live_first_callback
    ~label:"docker decomposed fallback"
    ~first_stdout_at
    ~elapsed

let test_docker_decomposed_final_redirect_does_not_stream_dropped_stdout () =
  let stdout_chunks = ref [] in
  let stderr_chunks = ref [] in
  let on_output_chunk = function
    | `Stdout chunk -> stdout_chunks := chunk :: !stdout_chunks
    | `Stderr chunk -> stderr_chunks := chunk :: !stderr_chunks
  in
  let dev_null =
    Masc_exec.Path_scope.classify ~raw:"/dev/null" ~cwd:"/tmp"
  in
  let drop_stdout =
    Masc_exec.Redirect_scope.File
      { fd = 1; target = dev_null; mode = Masc_exec.Redirect_scope.Write }
  in
  let runner ~on_stdout_chunk ~on_stderr_chunk ~stdin_content ~argv ~env:_ ~cwd:_ =
    match argv, stdin_content with
    | [ "printf"; "mid" ], None ->
        Option.iter (fun f -> f "mid") on_stdout_chunk;
        Option.iter (fun f -> f "stage1-err") on_stderr_chunk;
        Unix.WEXITED 0, "mid", "stage1-err"
    | [ "cat" ], Some "mid" ->
        (match on_stdout_chunk with
         | None -> ()
         | Some _ -> fail "redirected final stage received live stdout callback");
        Option.iter (fun f -> f "final-err") on_stderr_chunk;
        Unix.WEXITED 0, "dropped-final-stdout", "final-err"
    | _ -> fail "unexpected redirected decomposed fallback stage"
  in
  let docker_sandbox =
    Masc_exec.Sandbox_target.docker ~image:"fake-docker" ~runner ()
  in
  let result =
    Masc_exec.Exec_dispatch.dispatch_pipeline
      ~on_output_chunk
      [ Masc_exec.Shell_ir.Simple
          (simple ~sandbox:docker_sandbox "printf" [ "mid" ])
      ; Masc_exec.Shell_ir.Simple
          (simple ~sandbox:docker_sandbox ~redirects:[ drop_stdout ] "cat" [])
      ]
  in
  assert (result.status = Unix.WEXITED 0);
  assert (result.stdout = "");
  assert (result.stderr = "stage1-errfinal-err");
  assert (String.concat "" (List.rev !stdout_chunks) = "");
  assert (String.concat "" (List.rev !stderr_chunks) = "stage1-errfinal-err")

let test_docker_simple_redirect_does_not_stream_dropped_stdout () =
  let stdout_chunks = ref [] in
  let stderr_chunks = ref [] in
  let on_output_chunk = function
    | `Stdout chunk -> stdout_chunks := chunk :: !stdout_chunks
    | `Stderr chunk -> stderr_chunks := chunk :: !stderr_chunks
  in
  let dev_null =
    Masc_exec.Path_scope.classify ~raw:"/dev/null" ~cwd:"/tmp"
  in
  let drop_stdout =
    Masc_exec.Redirect_scope.File
      { fd = 1; target = dev_null; mode = Masc_exec.Redirect_scope.Write }
  in
  let runner ~on_stdout_chunk ~on_stderr_chunk ~stdin_content:_ ~argv:_ ~env:_ ~cwd:_ =
    (match on_stdout_chunk with
     | None -> ()
     | Some _ -> fail "simple redirected command received live stdout callback");
    (match on_stderr_chunk with
     | None -> ()
     | Some _ -> fail "simple redirected command received live stderr callback");
    Unix.WEXITED 0, "dropped-simple-stdout", "simple-err"
  in
  let docker_sandbox =
    Masc_exec.Sandbox_target.docker ~image:"fake-docker" ~runner ()
  in
  let result =
    Masc_exec.Exec_dispatch.dispatch_simple
      ~on_output_chunk
      (simple ~sandbox:docker_sandbox ~redirects:[ drop_stdout ] "printf" [ "ignored" ])
  in
  assert (result.status = Unix.WEXITED 0);
  assert (result.stdout = "");
  assert (result.stderr = "simple-err");
  assert (String.concat "" (List.rev !stdout_chunks) = "");
  assert (String.concat "" (List.rev !stderr_chunks) = "simple-err")

let test_docker_simple_fd_redirect_replays_stderr_as_stdout () =
  let stdout_chunks = ref [] in
  let stderr_chunks = ref [] in
  let on_output_chunk = function
    | `Stdout chunk -> stdout_chunks := chunk :: !stdout_chunks
    | `Stderr chunk -> stderr_chunks := chunk :: !stderr_chunks
  in
  let stderr_to_stdout = Masc_exec.Redirect_scope.Fd_to_fd { src = 2; dst = 1 } in
  let runner ~on_stdout_chunk ~on_stderr_chunk ~stdin_content:_ ~argv:_ ~env:_ ~cwd:_ =
    (match on_stdout_chunk with
     | None -> ()
     | Some _ -> fail "simple fd redirect received live stdout callback");
    (match on_stderr_chunk with
     | None -> ()
     | Some _ -> fail "simple fd redirect received live stderr callback");
    Unix.WEXITED 0, "", "redirected-simple-err"
  in
  let docker_sandbox =
    Masc_exec.Sandbox_target.docker ~image:"fake-docker" ~runner ()
  in
  let result =
    Masc_exec.Exec_dispatch.dispatch_simple
      ~on_output_chunk
      (simple
         ~sandbox:docker_sandbox
         ~redirects:[ stderr_to_stdout ]
         "printf"
         [ "ignored" ])
  in
  assert (result.status = Unix.WEXITED 0);
  assert (result.stdout = "redirected-simple-err");
  assert (result.stderr = "");
  assert (String.concat "" (List.rev !stdout_chunks) = "redirected-simple-err");
  assert (String.concat "" (List.rev !stderr_chunks) = "")

let test_docker_simple_runner_captured_error_is_streamed () =
  let stderr_chunks = ref [] in
  let on_output_chunk = function
    | `Stdout _ -> ()
    | `Stderr chunk -> stderr_chunks := chunk :: !stderr_chunks
  in
  let runner ~on_stdout_chunk:_ ~on_stderr_chunk:_ ~stdin_content:_ ~argv:_ ~env:_ ~cwd:_ =
    Unix.WEXITED 1, "", "setup-error"
  in
  let docker_sandbox =
    Masc_exec.Sandbox_target.docker ~image:"fake-docker" ~runner ()
  in
  let result =
    Masc_exec.Exec_dispatch.dispatch_simple
      ~on_output_chunk
      (simple ~sandbox:docker_sandbox "printf" [ "ignored" ])
  in
  assert (result.status = Unix.WEXITED 1);
  assert (result.stderr = "setup-error");
  assert (String.concat "" (List.rev !stderr_chunks) = "setup-error")

let test_docker_simple_runner_replays_unstreamed_stderr () =
  let stdout_chunks = ref [] in
  let stderr_chunks = ref [] in
  let on_output_chunk = function
    | `Stdout chunk -> stdout_chunks := chunk :: !stdout_chunks
    | `Stderr chunk -> stderr_chunks := chunk :: !stderr_chunks
  in
  let runner ~on_stdout_chunk ~on_stderr_chunk:_ ~stdin_content:_ ~argv:_ ~env:_ ~cwd:_ =
    Option.iter (fun f -> f "live-out") on_stdout_chunk;
    Unix.WEXITED 1, "live-out", "buffered-err"
  in
  let docker_sandbox =
    Masc_exec.Sandbox_target.docker ~image:"fake-docker" ~runner ()
  in
  let result =
    Masc_exec.Exec_dispatch.dispatch_simple
      ~on_output_chunk
      (simple ~sandbox:docker_sandbox "printf" [ "ignored" ])
  in
  assert (result.status = Unix.WEXITED 1);
  assert (result.stdout = "live-out");
  assert (result.stderr = "buffered-err");
  assert (String.concat "" (List.rev !stdout_chunks) = "live-out");
  assert (String.concat "" (List.rev !stderr_chunks) = "buffered-err")

let test_docker_simple_runner_callback_exception_is_not_replayed () =
  let stdout_calls = ref 0 in
  let on_output_chunk = function
    | `Stdout chunk ->
        assert (chunk = "live-out");
        incr stdout_calls;
        raise (Failure "callback boom")
    | `Stderr _ -> fail "unexpected stderr callback"
  in
  let runner ~on_stdout_chunk ~on_stderr_chunk:_ ~stdin_content:_ ~argv:_ ~env:_ ~cwd:_ =
    (match on_stdout_chunk with
     | None -> fail "expected stdout callback"
     | Some f -> (
       try f "live-out" with
       | Failure _ -> ()
       | exn -> raise exn));
    Unix.WEXITED 0, "live-out", ""
  in
  let docker_sandbox =
    Masc_exec.Sandbox_target.docker ~image:"fake-docker" ~runner ()
  in
  let result =
    Masc_exec.Exec_dispatch.dispatch_simple
      ~on_output_chunk
      (simple ~sandbox:docker_sandbox "printf" [ "ignored" ])
  in
  assert (result.status = Unix.WEXITED 0);
  assert (result.stdout = "live-out");
  assert (result.stderr = "");
  assert (!stdout_calls = 1)

let test_docker_pipeline_runner_captured_output_is_streamed () =
  let stdout_chunks = ref [] in
  let stderr_chunks = ref [] in
  let on_output_chunk = function
    | `Stdout chunk -> stdout_chunks := chunk :: !stdout_chunks
    | `Stderr chunk -> stderr_chunks := chunk :: !stderr_chunks
  in
  let runner ~on_stdout_chunk:_ ~on_stderr_chunk:_ ~stdin_content:_ ~argv:_ ~env:_ ~cwd:_ =
    Unix.WEXITED 9, "", "simple runner should not be used"
  in
  let pipeline_runner ~on_stdout_chunk:_ ~on_stderr_chunk:_ ~stages:_ =
    Unix.WEXITED 0, "buffered-out", "buffered-err"
  in
  let docker_sandbox =
    Masc_exec.Sandbox_target.docker
      ~image:"fake-docker"
      ~runner
      ~pipeline_runner
      ()
  in
  let result =
    Masc_exec.Exec_dispatch.dispatch_pipeline
      ~on_output_chunk
      [ Masc_exec.Shell_ir.Simple (simple ~sandbox:docker_sandbox "printf" [ "x" ])
      ; Masc_exec.Shell_ir.Simple (simple ~sandbox:docker_sandbox "wc" [ "-c" ])
      ]
  in
  assert (result.status = Unix.WEXITED 0);
  assert (result.stdout = "buffered-out");
  assert (result.stderr = "buffered-err");
  assert (String.concat "" (List.rev !stdout_chunks) = "buffered-out");
  assert (String.concat "" (List.rev !stderr_chunks) = "buffered-err")

let test_docker_decomposed_timeout_stdout_is_streamed () =
  let stdout_chunks = ref [] in
  let on_output_chunk = function
    | `Stdout chunk -> stdout_chunks := chunk :: !stdout_chunks
    | `Stderr _ -> ()
  in
  let runner ~on_stdout_chunk ~on_stderr_chunk:_ ~stdin_content ~argv ~env:_ ~cwd:_ =
    match argv, stdin_content with
    | [ "printf"; "slow" ], None ->
        Option.iter (fun f -> f "partial") on_stdout_chunk;
        Unix.WEXITED 124, "partial", "timeout"
    | _ -> fail "unexpected stage after timeout"
  in
  let docker_sandbox =
    Masc_exec.Sandbox_target.docker ~image:"fake-docker" ~runner ()
  in
  let result =
    Masc_exec.Exec_dispatch.dispatch_pipeline
      ~on_output_chunk
      [ Masc_exec.Shell_ir.Simple
          (simple ~sandbox:docker_sandbox "printf" [ "slow" ])
      ; Masc_exec.Shell_ir.Simple (simple ~sandbox:docker_sandbox "cat" [])
      ]
  in
  assert (result.status = Unix.WEXITED 124);
  assert (result.stdout = "partial");
  assert (result.stderr = "timeout");
  assert (String.concat "" (List.rev !stdout_chunks) = "partial")

let () =
  test_docker_simple_runner_callback_is_live ();
  test_docker_pipeline_runner_callback_is_live ();
  test_docker_decomposed_fallback_callback_is_live ();
  test_docker_decomposed_final_redirect_does_not_stream_dropped_stdout ();
  test_docker_simple_redirect_does_not_stream_dropped_stdout ();
  test_docker_simple_fd_redirect_replays_stderr_as_stdout ();
  test_docker_simple_runner_captured_error_is_streamed ();
  test_docker_simple_runner_replays_unstreamed_stderr ();
  test_docker_simple_runner_callback_exception_is_not_replayed ();
  test_docker_pipeline_runner_captured_output_is_streamed ();
  test_docker_decomposed_timeout_stdout_is_streamed ();
  print_endline "exec_dispatch_docker_streaming: ok"
