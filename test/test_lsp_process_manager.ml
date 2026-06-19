open Alcotest

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
  Eio.Flow.close stdout_w;
  Eio.Flow.close stderr_w;
  Eio.Flow.close stderr_r;
  let lsp_proc =
    { Lsp_process_manager.lang_id = "test"
    ; proc
    ; stdin_w
    ; stdout_r
    ; next_id = 1
    }
  in
  Lsp_process_manager.shutdown lsp_proc;
  Lsp_process_manager.shutdown lsp_proc;
  let write_failed =
    try
      Eio.Flow.copy_string "ignored" stdin_w;
      false
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | _ -> true
  in
  check bool "stdin writer closed" true write_failed;
  let read_failed =
    try
      Eio.Time.with_timeout_exn clock 0.1 (fun () ->
        let buf = Cstruct.create 1 in
        Eio.Flow.read_exact stdout_r buf);
      false
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | Eio.Time.Timeout -> fail "stdout reader did not close"
    | _ -> true
  in
  check bool "stdout reader closed" true read_failed;
  ignore
    (Eio.Time.with_timeout_exn clock 2.0 (fun () -> Eio.Process.await proc))
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
