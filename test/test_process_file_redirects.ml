(* A redirect is only real when the bytes land in the file. Every case here
   runs a genuine process and then reads the file back from disk. *)

let temp_dir = Filename.concat (Filename.get_temp_dir_name ()) "masc-process-file-redirects"

let path name = Filename.concat temp_dir name

let read_file p =
  let ic = open_in_bin p in
  Fun.protect
    ~finally:(fun () -> close_in ic)
    (fun () -> really_input_string ic (in_channel_length ic))
;;

let write_file p contents =
  let oc = open_out_bin p in
  Fun.protect ~finally:(fun () -> close_out oc) (fun () -> output_string oc contents)
;;

let remove_if_present p = if Sys.file_exists p then Sys.remove p

let with_runtime f =
  Eio_main.run @@ fun env ->
  Process_eio.init
    ~cwd_default:(Eio.Stdenv.fs env)
    ~proc_mgr:(Eio.Stdenv.process_mgr env)
    ~clock:(Eio.Stdenv.clock env);
  f ()
;;

let run ?(stdin = Process_eio.Inherited) ?(stdout = Process_eio.Captured)
      ?(stderr = Process_eio.Captured) argv =
  Process_eio.run_argv_with_redirects ~stdin ~stdout ~stderr argv
;;

let exited_zero = function
  | Unix.WEXITED 0 -> true
  | _ -> false
;;

let test_stdout_reaches_the_file () =
  with_runtime (fun () ->
    let target = path "truncate.txt" in
    remove_if_present target;
    match run ~stdout:(Process_eio.Written_to { path = target; append = false })
            [ "printf"; "hello" ]
    with
    | Error message -> Alcotest.failf "redirect failed: %s" message
    | Ok (status, captured, _) ->
      Alcotest.(check bool) "the process ran" true (exited_zero status);
      Alcotest.(check string) "the bytes did not come back here" "" captured;
      Alcotest.(check string) "the bytes are in the file" "hello" (read_file target))
;;

let test_truncate_replaces_what_was_there () =
  with_runtime (fun () ->
    let target = path "replace.txt" in
    write_file target "stale contents that must not survive";
    match run ~stdout:(Process_eio.Written_to { path = target; append = false })
            [ "printf"; "fresh" ]
    with
    | Error message -> Alcotest.failf "redirect failed: %s" message
    | Ok _ -> Alcotest.(check string) "truncate replaced the file" "fresh" (read_file target))
;;

let test_append_keeps_what_was_there () =
  with_runtime (fun () ->
    let target = path "append.txt" in
    write_file target "first ";
    match run ~stdout:(Process_eio.Written_to { path = target; append = true })
            [ "printf"; "second" ]
    with
    | Error message -> Alcotest.failf "redirect failed: %s" message
    | Ok _ -> Alcotest.(check string) "append added to the file" "first second" (read_file target))
;;

(* The two streams are chosen independently, which a single flag could not
   express: stderr goes to a file while stdout still comes back. *)
let test_streams_are_chosen_independently () =
  with_runtime (fun () ->
    let target = path "stderr-only.txt" in
    remove_if_present target;
    match run ~stderr:(Process_eio.Written_to { path = target; append = false })
            [ "sh"; "-c"; "printf out; printf err >&2" ]
    with
    | Error message -> Alcotest.failf "redirect failed: %s" message
    | Ok (_, captured_stdout, captured_stderr) ->
      Alcotest.(check string) "stdout still comes back" "out" captured_stdout;
      Alcotest.(check string) "stderr did not" "" captured_stderr;
      Alcotest.(check string) "stderr is in the file" "err" (read_file target))
;;

let test_stdin_reads_the_file () =
  with_runtime (fun () ->
    let source = path "input.txt" in
    write_file source "from a file\n";
    match run ~stdin:(Process_eio.Read_from { path = source }) [ "cat" ] with
    | Error message -> Alcotest.failf "redirect failed: %s" message
    | Ok (status, captured, _) ->
      Alcotest.(check bool) "the process ran" true (exited_zero status);
      Alcotest.(check string) "the child read the file" "from a file\n" captured)
;;

(* A path that cannot be opened stops the command. Reporting it as an exit
   status would claim a process ran, which is the shape this surface exists to
   avoid. *)
let test_unopenable_target_is_an_error_not_an_exit_status () =
  with_runtime (fun () ->
    let target = Filename.concat (path "no-such-directory") "out.txt" in
    match run ~stdout:(Process_eio.Written_to { path = target; append = false })
            [ "printf"; "hello" ]
    with
    | Ok (status, _, _) ->
      Alcotest.failf
        "an unopenable target must not report an exit status, got %s"
        (match status with
         | Unix.WEXITED code -> Printf.sprintf "WEXITED %d" code
         | Unix.WSIGNALED code -> Printf.sprintf "WSIGNALED %d" code
         | Unix.WSTOPPED code -> Printf.sprintf "WSTOPPED %d" code)
    | Error message ->
      Alcotest.(check bool)
        "the message names the path"
        true
        (Astring.String.is_infix ~affix:"out.txt" message))
;;

let () =
  (try Sys.mkdir temp_dir 0o700 with Sys_error _ -> ());
  Alcotest.run
    "process file redirects"
    [ ( "redirects"
      , [ Alcotest.test_case "stdout_reaches_the_file" `Quick test_stdout_reaches_the_file
        ; Alcotest.test_case
            "truncate_replaces_what_was_there"
            `Quick
            test_truncate_replaces_what_was_there
        ; Alcotest.test_case
            "append_keeps_what_was_there"
            `Quick
            test_append_keeps_what_was_there
        ; Alcotest.test_case
            "streams_are_chosen_independently"
            `Quick
            test_streams_are_chosen_independently
        ; Alcotest.test_case "stdin_reads_the_file" `Quick test_stdin_reads_the_file
        ; Alcotest.test_case
            "unopenable_target_is_an_error_not_an_exit_status"
            `Quick
            test_unopenable_target_is_an_error_not_an_exit_status
        ] )
    ]
;;
