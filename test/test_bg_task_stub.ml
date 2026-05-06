(* Tick 6a: Bg_task pull-based implementation tests.

   File name still [test_bg_task_stub.ml] from Tick 4; behaviour is
   now integration coverage, not stub assertions.  A rename requires
   updating two sibling dune stanzas — left for a follow-up. *)

open Alcotest

let sidecar_observer_counts : (string, float) Hashtbl.t = Hashtbl.create 8

let () =
  Bg_task.set_sidecar_failure_observer (fun ~site _exn ->
      let current =
        Hashtbl.find_opt sidecar_observer_counts site
        |> Option.value ~default:0.0
      in
      Hashtbl.replace sidecar_observer_counts site (current +. 1.0))

let bg_sidecar_failure_count site =
  Hashtbl.find_opt sidecar_observer_counts site
  |> Option.value ~default:0.0

let wait_until ~timeout_s f =
  let deadline = Unix.gettimeofday () +. timeout_s in
  let rec loop () =
    if f () then true
    else if Unix.gettimeofday () >= deadline then false
    else (ignore (Unix.select [] [] [] 0.02); loop ())
  in
  loop ()

let env_of_current () = Unix.environment ()

let rec mkdir_p p =
  if Sys.file_exists p then ()
  else begin
    let parent = Filename.dirname p in
    if parent <> p then mkdir_p parent;
    try Unix.mkdir p 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ()
  end

let rec rm_tree path =
  if Sys.file_exists path then
    if Sys.is_directory path then begin
      Array.iter (fun e -> rm_tree (Filename.concat path e)) (Sys.readdir path);
      Unix.rmdir path
    end else
      Unix.unlink path

let with_temp_base prefix f =
  let base = Filename.temp_file prefix "" in
  Unix.unlink base;
  Unix.mkdir base 0o755;
  Fun.protect ~finally:(fun () -> try rm_tree base with _ -> ()) (fun () ->
      f base)

let bg_dir_for ~base ~keeper =
  Filename.concat base (Printf.sprintf ".masc/keeper/%s/bg" keeper)

let with_ring_line_limit raw f =
  let previous = Sys.getenv_opt "MASC_KEEPER_SHELL_RING_LINES" in
  Unix.putenv "MASC_KEEPER_SHELL_RING_LINES" raw;
  Fun.protect
    ~finally:(fun () ->
      match previous with
      | Some value -> Unix.putenv "MASC_KEEPER_SHELL_RING_LINES" value
      | None -> Unix.putenv "MASC_KEEPER_SHELL_RING_LINES" "")
    f

let sp
    ?(keeper = "test-keeper")
    ?(cwd = "")
    ?(timeout_sec = 0.0)
    argv =
  match
    Bg_task.spawn
      ~keeper ~argv ~cwd
      ~envp:(env_of_current ())
      ~timeout_sec
      ()
  with
  | Ok tid -> tid
  | Error _ -> failwith "spawn failed"

let poll_for_closed tid =
  wait_until ~timeout_s:3.0 (fun () ->
    match Bg_task.read tid ~since_stdout:0 ~since_stderr:0 with
    | Ok s -> s.closed
    | Error _ -> false)

let test_task_id_empty_rejected () =
  (match Bg_task.task_id_of_string "" with
   | Error "empty handle" -> ()
   | Error msg -> failf "unexpected error message: %s" msg
   | Ok _ -> fail "empty id must return Error");
  match Bg_task.task_id_of_string_exn "" with
  | exception Invalid_argument _ -> ()
  | _ -> fail "empty id must raise"

let test_list_empty_for_unknown_keeper () =
  let ids = Bg_task.list ~keeper:"no-such-keeper-xyz" in
  check int "empty list" 0 (List.length ids)

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

let test_since_offset_skips_prefix () =
  let tid = sp ~keeper:"kp2" [ "/bin/echo"; "abcdef" ] in
  let _ = poll_for_closed tid in
  match Bg_task.read tid ~since_stdout:3 ~since_stderr:0 with
  | Error _ -> fail "read failed"
  | Ok s -> check string "suffix only" "def\n" s.stdout_since

let test_line_ring_drops_old_stdout_lines () =
  with_ring_line_limit "2" (fun () ->
      let tid =
        sp ~keeper:"kp-ring"
          [ "/bin/sh"; "-c"; "printf 'one\\ntwo\\nthree\\n'" ]
      in
      let _ = poll_for_closed tid in
      match Bg_task.read tid ~since_stdout:0 ~since_stderr:0 with
      | Error _ -> fail "read failed"
      | Ok s ->
          check string "retains last two lines" "two\nthree\n" s.stdout_since;
          check bool "reports dropped bytes" true (s.bytes_dropped_stdout > 0))

let line_count s =
  let n = ref 0 in
  String.iter (fun ch -> if ch = '\n' then incr n) s;
  if String.length s > 0 && s.[String.length s - 1] <> '\n' then incr n;
  !n

let test_sixteen_keepers_keep_bounded_shell_rings () =
  with_ring_line_limit "3" (fun () ->
      let tasks =
        List.init 16 (fun i ->
          let keeper = Printf.sprintf "kp-sustained-%02d" i in
          let script =
            Printf.sprintf
              "i=0; while [ $i -lt 20 ]; do printf '%s-line-%%02d\\n' $i; i=$((i+1)); done"
              keeper
          in
          (keeper, sp ~keeper [ "/bin/sh"; "-c"; script ]))
      in
      List.iter
        (fun (_keeper, tid) ->
          check bool "sustained keeper task closed" true (poll_for_closed tid))
        tasks;
      List.iter
        (fun (keeper, tid) ->
          match Bg_task.read tid ~since_stdout:0 ~since_stderr:0 with
          | Error _ -> failf "read failed for %s" keeper
          | Ok s ->
              check bool
                (keeper ^ " retained at most 3 stdout lines")
                true (line_count s.stdout_since <= 3);
              check bool
                (keeper ^ " reports dropped bytes")
                true (s.bytes_dropped_stdout > 0))
        tasks)

let spawn_and_read_stdout_with_limit ~limit ~keeper =
  with_ring_line_limit limit (fun () ->
      let tid =
        sp ~keeper
          [ "/bin/sh"; "-c"; "printf 'one\\ntwo\\nthree\\n'" ]
      in
      check bool (keeper ^ " task closed") true (poll_for_closed tid);
      match Bg_task.read tid ~since_stdout:0 ~since_stderr:0 with
      | Error _ -> failf "read failed for %s" keeper
      | Ok s -> s)

let test_ring_line_limit_boundaries () =
  let zero =
    spawn_and_read_stdout_with_limit ~limit:"0" ~keeper:"kp-ring-zero"
  in
  check string "limit=0 retains no stdout" "" zero.stdout_since;
  check bool "limit=0 reports dropped bytes" true
    (zero.bytes_dropped_stdout > 0);
  let one =
    spawn_and_read_stdout_with_limit ~limit:"1" ~keeper:"kp-ring-one"
  in
  check string "limit=1 retains final line" "three\n" one.stdout_since;
  check bool "limit=1 reports dropped bytes" true
    (one.bytes_dropped_stdout > 0);
  let invalid =
    spawn_and_read_stdout_with_limit ~limit:"not-an-int"
      ~keeper:"kp-ring-invalid"
  in
  check string "invalid limit falls back to default" "one\ntwo\nthree\n"
    invalid.stdout_since;
  check int "invalid limit drops nothing" 0 invalid.bytes_dropped_stdout;
  let high =
    spawn_and_read_stdout_with_limit ~limit:"5001" ~keeper:"kp-ring-high"
  in
  check string "large limit keeps small output" "one\ntwo\nthree\n"
    high.stdout_since;
  check int "large limit drops nothing" 0 high.bytes_dropped_stdout

let test_kill_closes_task () =
  let tid = sp ~keeper:"kp3" [ "/bin/sleep"; "30" ] in
  (* let child actually establish its pgroup *)
  ignore (Unix.select [] [] [] 0.2);
  (match Bg_task.kill tid ~signal:Sys.sigterm ~grace_sec:1.0 with
   | Ok () -> ()
   | Error _ -> fail "kill failed");
  let closed = poll_for_closed tid in
  check bool "closed after kill" true closed

let test_list_tracks_keeper () =
  let k = "kp-list" in
  let t1 = sp ~keeper:k [ "/bin/sleep"; "2" ] in
  let t2 = sp ~keeper:k [ "/bin/sleep"; "2" ] in
  let ids = Bg_task.list ~keeper:k in
  check bool "contains t1"
    true (List.mem t1 ids);
  check bool "contains t2"
    true (List.mem t2 ids);
  ignore (Bg_task.kill t1 ~signal:Sys.sigterm ~grace_sec:1.0);
  ignore (Bg_task.kill t2 ~signal:Sys.sigterm ~grace_sec:1.0);
  ignore (poll_for_closed t1);
  ignore (poll_for_closed t2)

let test_unknown_task_errors () =
  let tid = Bg_task.task_id_of_string_exn "bogus-nonexistent" in
  (match Bg_task.read tid ~since_stdout:0 ~since_stderr:0 with
   | Error (Bg_task.Unknown_task _) -> ()
   | _ -> fail "read on bogus id must be Unknown_task");
  match Bg_task.kill tid ~signal:Sys.sigterm ~grace_sec:0.1 with
  | Error (Bg_task.Unknown_task_kill _) -> ()
  | _ -> fail "kill on bogus id must be Unknown_task_kill"

let test_timeout_enforced () =
  let tid = sp ~keeper:"kp4" ~timeout_sec:0.3 [ "/bin/sleep"; "10" ] in
  let closed = wait_until ~timeout_s:3.0 (fun () ->
    match Bg_task.read tid ~since_stdout:0 ~since_stderr:0 with
    | Ok s -> s.closed
    | Error _ -> false)
  in
  check bool "closed via timeout" true closed

let test_reap_orphans_returns_zero () =
  check int "no orphans at boot" 0
    (Bg_task.reap_orphans ~base_path:"/tmp/no-such-base")

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
        let keeper_dir = Filename.concat (Filename.concat base Common.masc_dirname) "keeper" in
        let rec rm path =
          if Sys.is_directory path then begin
            Array.iter (fun e -> rm (Filename.concat path e)) (Sys.readdir path);
            Unix.rmdir path
          end else Unix.unlink path
        in
        if Sys.file_exists keeper_dir then rm keeper_dir
      with _ -> ())
    (fun () ->
      let tid =
        match
          Bg_task.spawn ~base_path:base ~keeper:"kp-pid"
            ~argv:[ "/bin/sleep"; "5" ]
            ~cwd:"" ~envp:(env_of_current ()) ~timeout_sec:0.0 ()
        with
        | Ok t -> t
        | Error _ -> failwith "spawn failed"
      in
      ignore (Unix.select [] [] [] 0.1);
      let pid_path =
        Filename.concat base
          (Printf.sprintf ".masc/keeper/kp-pid/bg/%s.pid"
             (Bg_task.task_id_to_string tid))
      in
      check bool "pid file exists mid-run" true (Sys.file_exists pid_path);
      ignore (Bg_task.kill tid ~signal:Sys.sigterm ~grace_sec:1.0);
      ignore (poll_for_closed tid);
      check bool "pid file gone after close" false (Sys.file_exists pid_path))

(* reap_orphans removes a stale pid file whose pid is no longer live
   and whose task_id is absent from the registry. *)
let test_reap_orphans_removes_stale_file () =
  let base = Filename.temp_file "bg_task_reap" "" in
  Unix.unlink base;
  Unix.mkdir base 0o755;
  Fun.protect
    ~finally:(fun () ->
      try
        let keeper_dir = Filename.concat (Filename.concat base Common.masc_dirname) "keeper" in
        let rec rm path =
          if Sys.is_directory path then begin
            Array.iter (fun e -> rm (Filename.concat path e)) (Sys.readdir path);
            Unix.rmdir path
          end else Unix.unlink path
        in
        if Sys.file_exists keeper_dir then rm keeper_dir
      with _ -> ())
    (fun () ->
      let bg_dir =
        Filename.concat base ".masc/keeper/kp-reap/bg"
      in
      let rec mkp p =
        if Sys.file_exists p then ()
        else begin
          let parent = Filename.dirname p in
          if parent <> p then mkp parent;
          try Unix.mkdir p 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ()
        end
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

let test_pid_file_write_failure_observed () =
  let base_file = Filename.temp_file "bg_task_pid_write_fail" "" in
  Fun.protect
    ~finally:(fun () -> try Unix.unlink base_file with _ -> ())
    (fun () ->
      let before = bg_sidecar_failure_count "write" in
      let tid =
        match
          Bg_task.spawn ~base_path:base_file ~keeper:"kp-pid-write-fail"
            ~argv:[ "/bin/sleep"; "1" ]
            ~cwd:"" ~envp:(env_of_current ()) ~timeout_sec:0.0 ()
        with
        | Ok t -> t
        | Error _ -> failwith "spawn failed"
      in
      let after = bg_sidecar_failure_count "write" in
      check (float 0.0001) "write failure counted"
        (before +. 1.0) after;
      ignore (Bg_task.kill tid ~signal:Sys.sigterm ~grace_sec:0.2);
      ignore (poll_for_closed tid))

let test_reap_orphans_observes_malformed_pid_file () =
  with_temp_base "bg_task_reap_parse" (fun base ->
      let keeper = "kp-reap-parse" in
      let bg_dir = bg_dir_for ~base ~keeper in
      mkdir_p bg_dir;
      let stale = Filename.concat bg_dir "bad-pid.pid" in
      let oc = open_out stale in
      output_string oc "not-a-pid\nnot-a-pgid\n0.0\n";
      close_out oc;
      let before = bg_sidecar_failure_count "read_parse" in
      let n = Bg_task.reap_orphans ~base_path:base in
      let after = bg_sidecar_failure_count "read_parse" in
      check (float 0.0001) "read parse failure counted"
        (before +. 1.0) after;
      check int "malformed sidecar removed" 1 n;
      check bool "malformed pid file gone" false (Sys.file_exists stale))

let test_reap_orphans_observes_unlink_failure () =
  with_temp_base "bg_task_reap_unlink" (fun base ->
      let keeper = "kp-reap-unlink" in
      let bg_dir = bg_dir_for ~base ~keeper in
      mkdir_p bg_dir;
      let stale = Filename.concat bg_dir "stuck-pid.pid" in
      let oc = open_out stale in
      output_string oc "999999\n999999\n0.0\n";
      close_out oc;
      Fun.protect
        ~finally:(fun () -> try Unix.chmod bg_dir 0o755 with _ -> ())
        (fun () ->
          Unix.chmod bg_dir 0o555;
          let before = bg_sidecar_failure_count "unlink" in
          let n = Bg_task.reap_orphans ~base_path:base in
          let after = bg_sidecar_failure_count "unlink" in
          check (float 0.0001) "unlink failure counted"
            (before +. 1.0) after;
          check int "failed unlink not counted as removed" 0 n;
          check bool "pid file retained after failed unlink" true
            (Sys.file_exists stale)))

let () =
  run "bg_task"
    [
      ( "signatures",
        [
          test_case "empty task_id rejected" `Quick
            test_task_id_empty_rejected;
          test_case "list on unknown keeper is empty" `Quick
            test_list_empty_for_unknown_keeper;
          test_case "unknown id returns structured errors" `Quick
            test_unknown_task_errors;
          test_case "reap_orphans on missing base returns 0" `Quick
            test_reap_orphans_returns_zero;
          test_case "line ring drops old stdout lines" `Quick
            test_line_ring_drops_old_stdout_lines;
          test_case "16 keepers keep bounded shell rings" `Quick
            test_sixteen_keepers_keep_bounded_shell_rings;
          test_case "ring line limit boundaries" `Quick
            test_ring_line_limit_boundaries;
        ] );
      ( "persistence",
        [
          test_case "pid file created and cleaned on close" `Quick
            test_pid_file_created_and_cleaned;
          test_case "reap_orphans removes stale pid file" `Quick
            test_reap_orphans_removes_stale_file;
          test_case "pid file write failure is observed" `Quick
            test_pid_file_write_failure_observed;
          test_case "malformed pid sidecar is observed" `Quick
            test_reap_orphans_observes_malformed_pid_file;
          test_case "pid sidecar unlink failure is observed" `Quick
            test_reap_orphans_observes_unlink_failure;
        ] );
      ( "lifecycle",
        [
          test_case "echo roundtrip" `Quick test_echo_roundtrip;
          test_case "since offset skips prefix" `Quick
            test_since_offset_skips_prefix;
          test_case "kill closes task" `Quick test_kill_closes_task;
          test_case "list tracks keeper's tasks" `Quick
            test_list_tracks_keeper;
          test_case "timeout enforcement fires tree_kill" `Quick
            test_timeout_enforced;
        ] );
    ]
