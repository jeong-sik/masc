open Alcotest

(* [shutdown] must close ALL THREE held pipe FDs (stdin_w, stdout_r, stderr_r),
   not just two. RFC-0261 / #21546: a missing [stderr_r] close leaks 1 FD per
   failed init, still climbing monotonically and tripping the FD admission gate.

   To prove a reader FD is *closed* (rather than merely hitting EOF because the
   killed child closed its write end), we keep the PARENT's write end of each
   reader pipe open. With a live writer the reader never reaches EOF, so it only
   becomes unreadable when [shutdown] closes it: if a close is missing the read
   blocks and the timeout fires the assertion. The extra write ends are released
   by the enclosing switch at end of test. *)
let test_shutdown_signals_child_and_closes_held_pipes () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let proc_mgr = Eio.Stdenv.process_mgr env in
  let clock = Eio.Stdenv.clock env in
  let stdin_r, stdin_w = Eio.Process.pipe ~sw proc_mgr in
  let stdout_r, stdout_w = Eio.Process.pipe ~sw proc_mgr in
  let stderr_r, stderr_w = Eio.Process.pipe ~sw proc_mgr in
  let proc =
    Eio.Process.spawn
      ~sw
      proc_mgr
      ~stdin:stdin_r
      ~stdout:stdout_w
      ~stderr:stderr_w
      [ "/bin/cat" ]
  in
  Eio.Flow.close stdin_r;
  (* Intentionally keep [stdout_w] and [stderr_w] open so the reader FDs stay
     readable until [shutdown] closes them (see header comment). *)
  let lsp_proc =
    { Lsp_process_manager.lang_id = "test"
    ; proc
    ; stdin_w
    ; stdout_r
    ; stderr_r
    ; next_id = 1
    }
  in
  Lsp_process_manager.shutdown lsp_proc;
  (* Idempotent: a second teardown (e.g. evict after a failed init) must not raise. *)
  Lsp_process_manager.shutdown lsp_proc;
  let reader_closed what read_thunk =
    try
      Eio.Time.with_timeout_exn clock 0.1 read_thunk;
      false
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | Eio.Time.Timeout -> fail (what ^ " did not close")
    | _ -> true
  in
  let write_failed =
    try
      Eio.Flow.copy_string "ignored" stdin_w;
      false
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | _ -> true
  in
  check bool "stdin writer closed" true write_failed;
  check
    bool
    "stdout reader closed"
    true
    (reader_closed "stdout reader" (fun () ->
       Eio.Flow.read_exact stdout_r (Cstruct.create 1)));
  check
    bool
    "stderr reader closed"
    true
    (reader_closed "stderr reader" (fun () ->
       Eio.Flow.read_exact stderr_r (Cstruct.create 1)));
  ignore (Eio.Time.with_timeout_exn clock 2.0 (fun () -> Eio.Process.await proc))
;;

let () =
  run
    "lsp_process_manager"
    [ ( "shutdown"
      , [ test_case
            "signals child and closes held pipes"
            `Quick
            test_shutdown_signals_child_and_closes_held_pipes
        ] )
    ]
;;
