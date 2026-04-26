(* Tick 6a: Bg_task pull-based implementation tests.

   File name still [test_bg_task_stub.ml] from Tick 4; behaviour is
   now integration coverage, not stub assertions.  A rename requires
   updating two sibling dune stanzas — left for a follow-up. *)

open Alcotest

let wait_until ~timeout_s f =
  let deadline = Unix.gettimeofday () +. timeout_s in
  let rec loop () =
    if f ()
    then true
    else if Unix.gettimeofday () >= deadline
    then false
    else (
      ignore (Unix.select [] [] [] 0.02);
      loop ())
  in
  loop ()
;;

let env_of_current () = Unix.environment ()

let sp ?(keeper = "test-keeper") ?(cwd = "") ?(timeout_sec = 0.0) argv =
  match Bg_task.spawn ~keeper ~argv ~cwd ~envp:(env_of_current ()) ~timeout_sec () with
  | Ok tid -> tid
  | Error _ -> failwith "spawn failed"
;;

let poll_for_closed tid =
  wait_until ~timeout_s:3.0 (fun () ->
    match Bg_task.read tid ~since_stdout:0 ~since_stderr:0 with
    | Ok s -> s.closed
    | Error _ -> false)
;;

let test_task_id_empty_rejected () =
  (match Bg_task.task_id_of_string "" with
   | Error "empty handle" -> ()
   | Error msg -> failf "unexpected error message: %s" msg
   | Ok _ -> fail "empty id must return Error");
  match Bg_task.task_id_of_string_exn "" with
  | exception Invalid_argument _ -> ()
  | _ -> fail "empty id must raise"
;;

let test_list_empty_for_unknown_keeper () =
  let ids = Bg_task.list ~keeper:"no-such-keeper-xyz" in
  check int "empty list" 0 (List.length ids)
;;

let test_echo_roundtrip () =
  let tid = sp ~keeper:"kp1" [ "/bin/echo"; "hello" ] in
  let closed = poll_for_closed tid in
  check bool "child closed" true closed;
  match Bg_task.read tid ~since_stdout:0 ~since_stderr:0 with
  | Error _ -> fail "read after close failed"
  | Ok s ->
    check string "stdout captured" "hello\n" s.stdout_since;
    check string "stderr empty" "" s.stderr_since;
    (match s.status with
     | Some (Unix.WEXITED 0) -> ()
     | _ -> fail "echo must exit 0")
;;

let test_since_offset_skips_prefix () =
  let tid = sp ~keeper:"kp2" [ "/bin/echo"; "abcdef" ] in
  let _ = poll_for_closed tid in
  match Bg_task.read tid ~since_stdout:3 ~since_stderr:0 with
  | Error _ -> fail "read failed"
  | Ok s -> check string "suffix only" "def\n" s.stdout_since
;;

let test_kill_closes_task () =
  let tid = sp ~keeper:"kp3" [ "/bin/sleep"; "30" ] in
  (* let child actually establish its pgroup *)
  ignore (Unix.select [] [] [] 0.2);
  (match Bg_task.kill tid ~signal:Sys.sigterm ~grace_sec:1.0 with
   | Ok () -> ()
   | Error _ -> fail "kill failed");
  let closed = poll_for_closed tid in
  check bool "closed after kill" true closed
;;

let test_list_tracks_keeper () =
  let k = "kp-list" in
  let t1 = sp ~keeper:k [ "/bin/sleep"; "2" ] in
  let t2 = sp ~keeper:k [ "/bin/sleep"; "2" ] in
  let ids = Bg_task.list ~keeper:k in
  check bool "contains t1" true (List.mem t1 ids);
  check bool "contains t2" true (List.mem t2 ids);
  ignore (Bg_task.kill t1 ~signal:Sys.sigterm ~grace_sec:1.0);
  ignore (Bg_task.kill t2 ~signal:Sys.sigterm ~grace_sec:1.0);
  ignore (poll_for_closed t1);
  ignore (poll_for_closed t2)
;;

let test_unknown_task_errors () =
  let tid = Bg_task.task_id_of_string_exn "bogus-nonexistent" in
  (match Bg_task.read tid ~since_stdout:0 ~since_stderr:0 with
   | Error (Bg_task.Unknown_task _) -> ()
   | _ -> fail "read on bogus id must be Unknown_task");
  match Bg_task.kill tid ~signal:Sys.sigterm ~grace_sec:0.1 with
  | Error (Bg_task.Unknown_task_kill _) -> ()
  | _ -> fail "kill on bogus id must be Unknown_task_kill"
;;

let test_timeout_enforced () =
  let tid = sp ~keeper:"kp4" ~timeout_sec:0.3 [ "/bin/sleep"; "10" ] in
  let closed =
    wait_until ~timeout_s:3.0 (fun () ->
      match Bg_task.read tid ~since_stdout:0 ~since_stderr:0 with
      | Ok s -> s.closed
      | Error _ -> false)
  in
  check bool "closed via timeout" true closed
;;

let test_reap_orphans_returns_zero () =
  check int "no orphans at boot" 0 (Bg_task.reap_orphans ~base_path:"/tmp/no-such-base")
;;

(* Tick 7 integration: when spawn is given ~base_path, a PID file
   appears at <base>/.masc/keeper/<k>/bg/<tid>.pid. After kill and
   close, the file is unlinked. *)
let test_pid_file_created_and_cleaned () =
  let base = Filename.temp_file "bg_task_tick7" "" in
  Unix.unlink base;
  Unix.mkdir base 0o755;
  Fun.protect
    ~finally:(fun () ->
      try
        let keeper_dir =
          Filename.concat (Filename.concat base Common.masc_dirname) "keeper"
        in
        let rec rm path =
          if Sys.is_directory path
          then (
            Array.iter (fun e -> rm (Filename.concat path e)) (Sys.readdir path);
            Unix.rmdir path)
          else Unix.unlink path
        in
        if Sys.file_exists keeper_dir then rm keeper_dir
      with
      | _ -> ())
    (fun () ->
       let tid =
         match
           Bg_task.spawn
             ~base_path:base
             ~keeper:"kp-pid"
             ~argv:[ "/bin/sleep"; "5" ]
             ~cwd:""
             ~envp:(env_of_current ())
             ~timeout_sec:0.0
             ()
         with
         | Ok t -> t
         | Error _ -> failwith "spawn failed"
       in
       ignore (Unix.select [] [] [] 0.1);
       let pid_path =
         Filename.concat
           base
           (Printf.sprintf
              ".masc/keeper/kp-pid/bg/%s.pid"
              (Bg_task.task_id_to_string tid))
       in
       check bool "pid file exists mid-run" true (Sys.file_exists pid_path);
       ignore (Bg_task.kill tid ~signal:Sys.sigterm ~grace_sec:1.0);
       ignore (poll_for_closed tid);
       check bool "pid file gone after close" false (Sys.file_exists pid_path))
;;

(* reap_orphans removes a stale pid file whose pid is no longer live
   and whose task_id is absent from the registry. *)
let test_reap_orphans_removes_stale_file () =
  let base = Filename.temp_file "bg_task_reap" "" in
  Unix.unlink base;
  Unix.mkdir base 0o755;
  Fun.protect
    ~finally:(fun () ->
      try
        let keeper_dir =
          Filename.concat (Filename.concat base Common.masc_dirname) "keeper"
        in
        let rec rm path =
          if Sys.is_directory path
          then (
            Array.iter (fun e -> rm (Filename.concat path e)) (Sys.readdir path);
            Unix.rmdir path)
          else Unix.unlink path
        in
        if Sys.file_exists keeper_dir then rm keeper_dir
      with
      | _ -> ())
    (fun () ->
       let bg_dir = Filename.concat base ".masc/keeper/kp-reap/bg" in
       let rec mkp p =
         if Sys.file_exists p
         then ()
         else (
           let parent = Filename.dirname p in
           if parent <> p then mkp parent;
           try Unix.mkdir p 0o755 with
           | Unix.Unix_error (Unix.EEXIST, _, _) -> ())
       in
       mkp bg_dir;
       let stale = Filename.concat bg_dir "ghost-tid.pid" in
       let oc = open_out stale in
       (* PID 999999 assumed dead on any reasonable test host *)
       output_string oc "999999\n999999\n0.0\n";
       close_out oc;
       let n = Bg_task.reap_orphans ~base_path:base in
       check bool "reaped at least one" true (n >= 1);
       check bool "stale file removed" false (Sys.file_exists stale))
;;

let () =
  run
    "bg_task"
    [ ( "signatures"
      , [ test_case "empty task_id rejected" `Quick test_task_id_empty_rejected
        ; test_case
            "list on unknown keeper is empty"
            `Quick
            test_list_empty_for_unknown_keeper
        ; test_case "unknown id returns structured errors" `Quick test_unknown_task_errors
        ; test_case
            "reap_orphans on missing base returns 0"
            `Quick
            test_reap_orphans_returns_zero
        ] )
    ; ( "persistence"
      , [ test_case
            "pid file created and cleaned on close"
            `Quick
            test_pid_file_created_and_cleaned
        ; test_case
            "reap_orphans removes stale pid file"
            `Quick
            test_reap_orphans_removes_stale_file
        ] )
    ; ( "lifecycle"
      , [ test_case "echo roundtrip" `Quick test_echo_roundtrip
        ; test_case "since offset skips prefix" `Quick test_since_offset_skips_prefix
        ; test_case "kill closes task" `Quick test_kill_closes_task
        ; test_case "list tracks keeper's tasks" `Quick test_list_tracks_keeper
        ; test_case "timeout enforcement fires tree_kill" `Quick test_timeout_enforced
        ] )
    ]
;;
