open Masc_mcp

let with_temp_config f =
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = Filename.temp_file "task_dispatch_" "" in
  Unix.unlink dir;
  Unix.mkdir dir 0o755;
  let config = Coord.default_config dir in
  Fun.protect
    ~finally:(fun () ->
      let rec rm path =
        if Sys.file_exists path
        then
          if Sys.is_directory path
          then (
            Sys.readdir path |> Array.iter (fun name -> rm (Filename.concat path name));
            Unix.rmdir path)
          else Unix.unlink path
      in
      rm dir)
    (fun () -> f config)
;;

let test_default_backend_jsonl () =
  Task_dispatch.reset_for_test ();
  match Task_dispatch.backend () with
  | Task_dispatch.Jsonl -> ()
;;

let test_add_task_in_jsonl_mode () =
  with_temp_config (fun config ->
    ignore (Coord.init config ~agent_name:(Some "tester"));
    Task_dispatch.reset_for_test ();
    Task_dispatch.init_jsonl ();
    match
      Task_dispatch.add_task
        config
        ~title:"dispatch task"
        ~priority:3
        ~description:"from task dispatch test"
    with
    | Error e -> Alcotest.fail (Types.show_masc_error e)
    | Ok message ->
      Alcotest.(check bool) "returns success message" true (String.length message > 0))
;;

let test_reset_clears_pg_state_shape () =
  Task_dispatch.reset_for_test ();
  Task_dispatch.init_jsonl ();
  Task_dispatch.reset_for_test ();
  match Task_dispatch.backend () with
  | Task_dispatch.Jsonl -> ()
;;

let () =
  Alcotest.run
    "Task_dispatch"
    [ ( "backend"
      , [ Alcotest.test_case "default jsonl" `Quick test_default_backend_jsonl
        ; Alcotest.test_case "reset clears state" `Quick test_reset_clears_pg_state_shape
        ] )
    ; "jsonl", [ Alcotest.test_case "add task" `Quick test_add_task_in_jsonl_mode ]
    ]
;;
