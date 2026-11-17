open Alcotest
module P = Process_eio

let self = ref ""
exception Callback_failed

let rec write_fd fd text offset =
  if offset < String.length text then
    write_fd fd text (offset + Unix.write_substring fd text offset (String.length text - offset))

let child mode =
  Sys.set_signal Sys.sigterm Sys.Signal_ignore;
  let descendant = Unix.fork () in
  if descendant = 0 then (while true do Unix.pause () done);
  Printf.printf "%d %d\n%!" (Unix.getpid ()) descendant;
  (match mode with
   | "stderr" | "tail" ->
     ignore (input_char stdin);
     write_fd (if mode = "stderr" then Unix.stderr else Unix.stdout) "callback bytes" 0
   | "hold" -> ()
   | _ -> Unix._exit 90);
  while true do Unix.pause () done

let with_runtime f =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  P.init ~cwd_default:Eio.Path.(Eio.Stdenv.fs env / Sys.getcwd ())
    ~proc_mgr:Posix_spawn_process_mgr.mgr ~clock:(Eio.Stdenv.clock env);
  Fun.protect ~finally:P.reset_for_testing (fun () ->
    Eio.Time.with_timeout_exn (Eio.Stdenv.clock env) 20.0 (fun () ->
      f (Eio.Stdenv.clock env)))

let read_exact input count =
  let bytes = Cstruct.create count in
  Eio.Flow.read_exact input bytes;
  Cstruct.to_string bytes

let ready input =
  let line = Eio.Buf_read.line (Eio.Buf_read.of_flow input ~max_size:128) in
  match String.split_on_char ' ' line with
  | [child; descendant] -> [int_of_string child; int_of_string descendant]
  | [] | [_] | _ :: _ :: _ :: _ -> fail "invalid child readiness line"

let running pid =
  let path = Printf.sprintf "/proc/%d/stat" pid in
  match Unix.openfile path [Unix.O_RDONLY; Unix.O_CLOEXEC] 0 with
  | fd ->
    let channel = Unix.in_channel_of_descr fd in
    let text = Fun.protect ~finally:(fun () -> close_in channel)
        (fun () -> In_channel.input_all channel) in
    let state = text.[String.rindex text ')' + 2] in
    state <> 'Z'
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> false

let with_group f =
  let pids = ref [] in
  Fun.protect ~finally:(fun () ->
    match !pids with
    | [] -> ()
    | leader :: _ ->
      (try Unix.kill (-leader) Sys.sigkill with Unix.Unix_error (Unix.ESRCH, _, _) -> ()))
    (fun () -> f pids)

let assert_stopped pids =
  check int "the real child published its descendant" 2 (List.length !pids);
  let clock = match P.get_clock () with Ok clock -> clock | Error detail -> fail detail in
  (* A killed orphan may briefly remain runnable until the kernel schedules
     its pending signal; a zombie is stopped, but is not called reaped here. *)
  Eio.Time.with_timeout_exn clock 2.0 (fun () ->
    let rec wait () =
      if List.exists running !pids then (Eio.Time.sleep clock 0.01; wait ()) in
    wait ());
  List.iter (fun pid -> check bool "cleanup leaves no executing child or descendant"
    false (running pid)) !pids

let run ?(on_stderr_chunk = ignore) ?(on_stdout_tail = ignore) argv use =
  P.with_stdio ~on_stderr_chunk ~on_stdout_tail argv use

let test_refusal_before_spawn () =
  P.reset_for_testing ();
  check bool "empty argv is a typed refusal" true
    (run [] (fun ~input:_ ~output:_ -> fail "empty argv spawned")
     = Error (P.Spawn_refused P.Empty_argv));
  (match run ["/bin/true"] (fun ~input:_ ~output:_ -> fail "uninitialized runtime spawned") with
   | Error (P.Runtime_unavailable _) -> ()
   | Error (P.Spawn_refused _) | Ok _ -> fail "missing runtime was not refused");
  with_runtime @@ fun _clock ->
  let missing = Filename.concat (Filename.get_temp_dir_name ())
      (Printf.sprintf "missing-stdio-program-%d" (Unix.getpid ())) in
  check bool "fixture program really is absent" false (Sys.file_exists missing);
  match run [missing] (fun ~input:_ ~output:_ -> fail "absent executable reached callback") with
  | Error (P.Spawn_refused (P.Executable_not_found _
      | P.Spawn_failed _ | P.Child_setup_failed _)) -> ()
  | Error (P.Spawn_refused (P.Empty_argv | P.Cwd_unavailable _))
  | Error (P.Runtime_unavailable _) | Ok _ -> fail "missing executable lost its pre-spawn refusal"

let test_exact_streams_and_real_status () =
  with_runtime @@ fun _clock ->
  let payload = "a\000\255z" in
  let stderr = Buffer.create 32 and tail = Buffer.create 32 in
  let result = run ~on_stderr_chunk:(Buffer.add_string stderr)
      ~on_stdout_tail:(Buffer.add_string tail)
      ["/bin/sh"; "-c";
       "dd bs=1 count=4 2>/dev/null; printf 'err\\000raw' >&2; \
        dd bs=1 count=4 2>/dev/null; printf 'tail\\000raw'; exit 7"]
      (fun ~input ~output ->
        Eio.Flow.copy_string payload output;
        check string "first response before the second input" payload (read_exact input 4);
        Eio.Flow.copy_string payload output;
        check string "second response" payload (read_exact input 4);
        "callback-value") in
  (match result with
   | Ok (value, status) ->
     check string "callback value is separate" "callback-value" value;
     check bool "actual nonzero exit is preserved" true (status = Unix.WEXITED 7)
   | Error _ -> fail "real child refused");
  check string "stderr callback receives raw NUL bytes" "err\000raw" (Buffer.contents stderr);
  check string "unread stdout is delivered after callback return" "tail\000raw" (Buffer.contents tail)

let test_captured_runtime_keeps_its_cwd () =
  let first = Unix.realpath (Filename.temp_dir "stdio-first-cwd-" "") in
  let second = Unix.realpath (Filename.temp_dir "stdio-second-cwd-" "") in
  Fun.protect ~finally:(fun () -> Unix.rmdir second; Unix.rmdir first) (fun () ->
    Eio_main.run @@ fun env ->
    Fs_compat.set_fs (Eio.Stdenv.fs env);
    let initialize cwd =
      P.init ~cwd_default:Eio.Path.(Eio.Stdenv.fs env / cwd)
        ~proc_mgr:Posix_spawn_process_mgr.mgr ~clock:(Eio.Stdenv.clock env)
    in
    Fun.protect ~finally:P.reset_for_testing (fun () ->
      initialize first;
      let context = match P.capture_stdio_context () with
        | Ok context -> context | Error detail -> fail detail in
      initialize second;
      let pwd ?context () =
        match P.with_stdio ?context ~on_stderr_chunk:ignore ~on_stdout_tail:ignore
            ["/bin/pwd"; "-P"] (fun ~input ~output:_ ->
              Eio.Buf_read.line (Eio.Buf_read.of_flow input
                ~max_size:(1 + max (String.length first) (String.length second)))) with
        | Ok (cwd, Unix.WEXITED 0) -> cwd
        | Ok (_, (Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _))
        | Error _ -> fail "cwd fixture did not finish successfully"
      in
      Eio.Time.with_timeout_exn (Eio.Stdenv.clock env) 20.0 (fun () ->
        check string "captured runtime launches in its original directory" first
          (pwd ~context ());
        check string "ordinary callers use the current runtime directory" second
          (pwd ()))))

let test_captured_context_does_not_enable_non_eio_spawn () =
  let context = Eio_main.run (fun env ->
    P.init ~cwd_default:(Eio.Stdenv.fs env)
      ~proc_mgr:Posix_spawn_process_mgr.mgr ~clock:(Eio.Stdenv.clock env);
    Fun.protect ~finally:P.reset_for_testing (fun () ->
      match P.capture_stdio_context () with
      | Ok context -> context | Error detail -> fail detail)) in
  match P.with_stdio ~context ~on_stderr_chunk:ignore ~on_stdout_tail:ignore
      ["/bin/true"] (fun ~input:_ ~output:_ -> fail "closed runtime spawned outside Eio") with
  | Error (P.Runtime_unavailable _) -> ()
  | Error (P.Spawn_refused _) | Ok _ -> fail "captured context bypassed the Eio requirement"

let test_callback_exception_is_not_spawn_refusal () =
  List.iter (fun raised ->
    with_runtime @@ fun _clock -> with_group @@ fun pids ->
    (match run [!self; "--stdio-child"; "hold"] (fun ~input ~output:_ ->
       pids := ready input; raise raised) with
     | Ok _ | Error _ -> fail "post-spawn callback exception was converted into a result"
     | exception observed -> check bool "the original exception propagates" true (observed == raised));
    assert_stopped pids)
    [Failure "fixture setup-shaped error"; Unix.Unix_error (Unix.ENOENT, "fixture", "after-spawn")]

let test_stream_callback_failure_cleans_the_group mode () =
  with_runtime @@ fun _clock -> with_group @@ fun pids ->
  let reject _ = raise Callback_failed in
  let stderr = if mode = "stderr" then reject else ignore in
  let tail = if mode = "tail" then reject else ignore in
  (match run ~on_stderr_chunk:stderr ~on_stdout_tail:tail
      [!self; "--stdio-child"; mode] (fun ~input ~output ->
        pids := ready input;
        Eio.Flow.copy_string "!" output;
        if mode = "stderr" then Eio.Fiber.await_cancel ()) with
   | Ok _ | Error _ -> fail "mandatory stream callback failure was swallowed"
   | exception Callback_failed -> ());
  assert_stopped pids

let test_cancellation_cleans_the_group () =
  with_runtime @@ fun _clock -> with_group @@ fun pids ->
  let started, announce = Eio.Promise.create () in
  let cancelled = ref false in
  Eio.Fiber.first
    (fun () ->
      try ignore (run [!self; "--stdio-child"; "hold"] (fun ~input ~output:_ ->
        pids := ready input;
        Eio.Promise.resolve announce ();
        Eio.Fiber.await_cancel ())) with
      | Eio.Cancel.Cancelled _ as exn -> cancelled := true; raise exn)
    (fun () -> Eio.Promise.await started);
  check bool "the caller cancellation reached the session" true !cancelled;
  assert_stopped pids

let test_timeout_cleans_the_group () =
  with_runtime @@ fun clock -> with_group @@ fun pids ->
  (match run [!self; "--stdio-child"; "hold"] (fun ~input ~output:_ ->
     pids := ready input;
     Eio.Time.with_timeout_exn clock 0.05 (fun () -> Eio.Fiber.await_cancel ())) with
   | Ok _ | Error _ -> fail "caller timeout was converted into a process result"
   | exception Eio.Time.Timeout -> ());
  assert_stopped pids

let () =
  match Array.to_list Sys.argv with
  | [_; "--stdio-child"; mode] -> child mode
  | _ ->
    self := Unix.realpath Sys.executable_name;
    Alcotest.run "owned process stdio"
      ["lifecycle",
       [test_case "refusals precede spawn" `Quick test_refusal_before_spawn;
        test_case "exact duplex bytes tail and actual exit" `Quick test_exact_streams_and_real_status;
        test_case "captured runtime preserves actual child cwd" `Quick test_captured_runtime_keeps_its_cwd;
        test_case "captured runtime cannot spawn outside Eio" `Quick test_captured_context_does_not_enable_non_eio_spawn;
        test_case "post-spawn exceptions remain exceptions" `Quick test_callback_exception_is_not_spawn_refusal;
        test_case "stderr callback failure cleans blocked session" `Quick
          (test_stream_callback_failure_cleans_the_group "stderr");
        test_case "stdout tail callback failure cleans session" `Quick
          (test_stream_callback_failure_cleans_the_group "tail");
        test_case "caller cancellation cleans process group" `Quick test_cancellation_cleans_the_group;
        test_case "caller timeout cleans process group" `Quick test_timeout_cleans_the_group]]
