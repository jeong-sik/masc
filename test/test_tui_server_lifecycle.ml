(* Unit tests for Masc_tui_server_lifecycle (RFC tui-server-lifecycle).
   The pure discovery/argv/health-wait logic is exercised deterministically
   with injected effects; start/stop spawns a real sleeper and reaps it so
   the alive/dead assertions do not race a zombie. *)

module L = Masc_tui_server_lifecycle

let discovery_testable =
  Alcotest.testable
    (fun ppf (d : L.discovery) ->
      match d with
      | L.Sibling p -> Format.fprintf ppf "Sibling %s" p
      | L.On_path p -> Format.fprintf ppf "On_path %s" p
      | L.Not_found { manual_command } ->
          Format.fprintf ppf "Not_found %s" manual_command)
    ( = )

let test_discover_prefers_sibling () =
  let d =
    L.discover_server_binary ~tui_exe:"/opt/masc/bin/masc-tui"
      ~file_exists:(fun p -> String.equal p "/opt/masc/bin/masc")
      ~path_lookup:(fun _ -> Some "/usr/local/bin/masc")
      ~base_path:"/ws" ~host:"127.0.0.1" ~port:8935
  in
  Alcotest.check discovery_testable "sibling wins over PATH"
    (L.Sibling "/opt/masc/bin/masc") d

let test_discover_falls_back_to_path () =
  let d =
    L.discover_server_binary ~tui_exe:"/opt/masc/bin/masc-tui"
      ~file_exists:(fun _ -> false)
      ~path_lookup:(fun name ->
        if String.equal name "masc" then Some "/usr/local/bin/masc" else None)
      ~base_path:"/ws" ~host:"127.0.0.1" ~port:8935
  in
  Alcotest.check discovery_testable "PATH used when no sibling"
    (L.On_path "/usr/local/bin/masc") d

let test_discover_not_found_carries_command () =
  let d =
    L.discover_server_binary ~tui_exe:"/opt/masc/bin/masc-tui"
      ~file_exists:(fun _ -> false)
      ~path_lookup:(fun _ -> None)
      ~base_path:"/ws" ~host:"0.0.0.0" ~port:9001
  in
  Alcotest.check discovery_testable "not found returns the manual command"
    (L.Not_found
       { manual_command = "masc start --base-path /ws --host 0.0.0.0 --port 9001" })
    d

let test_server_argv () =
  Alcotest.(check (list string))
    "argv has no shell interpolation"
    [ "/bin/masc"; "start"; "--base-path"; "/ws"; "--host"; "127.0.0.1"; "--port"; "8935" ]
    (L.server_argv ~masc_bin:"/bin/masc" ~base_path:"/ws" ~host:"127.0.0.1"
       ~port:8935)

let outcome_str = function
  | L.Ready -> "Ready"
  | L.Server_exited code -> Printf.sprintf "Server_exited %d" code
  | L.Timed_out n -> Printf.sprintf "Timed_out %d" n

let outcome_testable =
  Alcotest.testable
    (fun ppf o -> Format.pp_print_string ppf (outcome_str o))
    ( = )

let test_wait_ready_immediately () =
  let slept = ref 0 in
  let o =
    L.wait_healthy
      ~health_ok:(fun () -> true)
      ~child_exit:(fun () -> None)
      ~attempts:5
      ~sleep:(fun () -> incr slept)
  in
  Alcotest.check outcome_testable "ready without sleeping" L.Ready o;
  Alcotest.(check int) "never slept" 0 !slept

let test_wait_ready_on_third () =
  let n = ref 0 in
  let slept = ref 0 in
  let o =
    L.wait_healthy
      ~health_ok:(fun () ->
        incr n;
        !n >= 3)
      ~child_exit:(fun () -> None)
      ~attempts:10
      ~sleep:(fun () -> incr slept)
  in
  Alcotest.check outcome_testable "ready on third poll" L.Ready o;
  Alcotest.(check int) "slept between the three polls" 2 !slept

let test_wait_server_exited () =
  let o =
    L.wait_healthy
      ~health_ok:(fun () -> false)
      ~child_exit:(fun () -> Some 1)
      ~attempts:5
      ~sleep:(fun () -> ())
  in
  Alcotest.check outcome_testable "child death stops the wait and says how"
    (L.Server_exited 1) o

let test_wait_times_out () =
  let slept = ref 0 in
  let o =
    L.wait_healthy
      ~health_ok:(fun () -> false)
      ~child_exit:(fun () -> None)
      ~attempts:3
      ~sleep:(fun () -> incr slept)
  in
  Alcotest.check outcome_testable "exhausts attempts" (L.Timed_out 3) o;
  Alcotest.(check int) "slept between attempts only" 2 !slept

let test_wait_zero_attempts () =
  let slept = ref 0 in
  let o =
    L.wait_healthy
      ~health_ok:(fun () -> false)
      ~child_exit:(fun () -> None)
      ~attempts:0
      ~sleep:(fun () -> incr slept)
  in
  Alcotest.check outcome_testable "no attempts times out at zero" (L.Timed_out 0)
    o;
  Alcotest.(check int) "never slept" 0 !slept

let test_start_stop_reaped () =
  let dir = Filename.temp_file "tui-lifecycle" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  let script = Filename.concat dir "fake-masc" in
  let oc = open_out script in
  (* Ignores the server argv and just stays alive; exec keeps the pid the
     process-group leader so tree-kill and waitpid target it directly. *)
  output_string oc "#!/bin/sh\nexec sleep 30\n";
  close_out oc;
  Unix.chmod script 0o755;
  match
    L.start ~masc_bin:script ~base_path:dir ~host:"127.0.0.1" ~port:18999
      ~env:(Unix.environment ())
  with
  | Error e -> Alcotest.failf "start failed: %s" e
  | Ok owned ->
      let pgid = L.owned_pgid owned in
      (* The child sets its own process group after fork, so [-pgid] can lag
         the parent's return by a scheduler tick; poll briefly rather than
         race it. *)
      let rec await_alive tries =
        if Process_eio_detached.is_pgid_alive ~pgid then true
        else if tries <= 0 then false
        else (
          Unix.sleepf 0.05;
          await_alive (tries - 1))
      in
      Alcotest.(check bool)
        "owned server comes up after start" true (await_alive 40);
      L.stop owned ~grace_sec:0.3;
      let rec await_exit tries =
        if not (L.is_running owned) then true
        else if tries <= 0 then false
        else (
          Unix.sleepf 0.05;
          await_exit (tries - 1))
      in
      Alcotest.(check bool)
        "lifecycle observes and reaps the exited child" true (await_exit 40);
      Alcotest.(check bool)
        "reaped startup handle stays exited" false (L.is_running owned);
      Alcotest.(check bool)
        "owned server is gone after stop and reap" false
        (Process_eio_detached.is_pgid_alive ~pgid);
      (try Sys.remove script with Sys_error _ -> ());
      (try Unix.rmdir dir with Unix.Unix_error _ -> ())


let temp_dir prefix =
  let dir = Filename.temp_file prefix "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  dir

let write_script dir name body =
  let script = Filename.concat dir name in
  Out_channel.with_open_text script (fun oc -> output_string oc body);
  Unix.chmod script 0o755;
  script

let read_file path = In_channel.with_open_bin path In_channel.input_all

let await_exit_report owned =
  let rec loop tries =
    match L.exit_report owned with
    | Some report -> report
    | None ->
      if tries <= 0 then Alcotest.fail "the child did not exit"
      else (
        Unix.sleepf 0.05;
        loop (tries - 1))
  in
  loop 100

let start_fake ~script ~base_path ~port =
  match
    L.start ~masc_bin:script ~base_path ~host:"127.0.0.1" ~port
      ~env:(Unix.environment ())
  with
  | Error e -> Alcotest.failf "start failed: %s" e
  | Ok owned -> owned

let last_line_testable =
  Alcotest.testable
    (fun ppf line -> Format.pp_print_string ppf (L.describe_last_line line))
    ( = )

let output_testable =
  Alcotest.testable
    (fun ppf output -> Format.pp_print_string ppf (L.describe_output output))
    ( = )

(* A base path another server holds is refused on stderr before that
   server's own log exists, with exit 1. The starter used to send stderr to
   /dev/null and keep no status, so all it could say was that the child was
   gone. *)
let test_a_refusal_is_read_back_with_its_status () =
  let base_path = temp_dir "tui-lifecycle-refusal" in
  let script =
    write_script base_path "fake-masc"
      "#!/bin/sh\necho booting\necho '[FATAL] Base path is locked. The lease records PID 4242.' >&2\nexit 1\n"
  in
  let owned = start_fake ~script ~base_path ~port:18998 in
  let report = await_exit_report owned in
  Alcotest.(check string) "the exit status is kept" "exit 1" report.L.status;
  Alcotest.check last_line_testable "the last line is the refusal"
    (L.Said "[FATAL] Base path is locked. The lease records PID 4242.")
    report.L.last_line;
  let path = L.startup_output_path ~base_path ~port:18998 in
  Alcotest.check output_testable "the output went to the per-port file"
    (L.Written_to path) report.L.output;
  Alcotest.(check string) "stdout and stderr share the file"
    "booting\n[FATAL] Base path is locked. The lease records PID 4242.\n"
    (read_file path);
  Alcotest.(check bool) "a second look reads the same exit" true
    (L.exit_report owned = Some report)

(* One file per port, emptied by each start: the second start's reader must
   not take the first start's last words for its own. *)
let test_each_start_empties_its_file () =
  let base_path = temp_dir "tui-lifecycle-truncate" in
  let first = write_script base_path "first" "#!/bin/sh\necho first-start-refusal >&2\nexit 3\n" in
  let second = write_script base_path "second" "#!/bin/sh\nexit 0\n" in
  let report = await_exit_report (start_fake ~script:first ~base_path ~port:18997) in
  Alcotest.check last_line_testable "first start" (L.Said "first-start-refusal")
    report.L.last_line;
  let report = await_exit_report (start_fake ~script:second ~base_path ~port:18997) in
  Alcotest.(check string) "second status" "exit 0" report.L.status;
  Alcotest.check last_line_testable "the second start said nothing"
    L.Said_nothing report.L.last_line

(* The log is how a failure is explained; a base path whose .masc is not a
   directory cannot hold it, and the server still starts. *)
let test_an_unopenable_log_does_not_stop_the_start () =
  let base_path = temp_dir "tui-lifecycle-no-log" in
  Out_channel.with_open_text (Filename.concat base_path ".masc") (fun oc ->
    output_string oc "not a directory");
  let script = write_script base_path "fake-masc" "#!/bin/sh\necho lost >&2\nexit 2\n" in
  let report = await_exit_report (start_fake ~script ~base_path ~port:18996) in
  Alcotest.(check string) "the child still ran" "exit 2" report.L.status;
  (match report.L.output with
   | L.Not_kept { path; reason = _ } ->
     Alcotest.(check string) "names the file it could not open"
       (L.startup_output_path ~base_path ~port:18996) path
   | L.Written_to path -> Alcotest.failf "expected no log, got %s" path);
  Alcotest.check last_line_testable "nothing to read back" L.Said_nothing
    report.L.last_line

(* Only the tail is read. A reason written after more output than that
   still comes back whole, and the fragment the cut lands in is not taken
   for a line. *)
let test_the_tail_read_keeps_the_last_line_whole () =
  let base_path = temp_dir "tui-lifecycle-tail" in
  let script =
    write_script base_path "fake-masc"
      "#!/bin/sh\ni=0\nwhile [ $i -lt 3000 ]; do echo \"routine log line number $i with some padding text\"; i=$((i+1)); done\necho '[FATAL] Port 8935 is still in use after 5 retries.' >&2\nexit 1\n"
  in
  let report = await_exit_report (start_fake ~script ~base_path ~port:18995) in
  let path = L.startup_output_path ~base_path ~port:18995 in
  Alcotest.(check bool) "the output is longer than the tail" true
    ((Unix.stat path).Unix.st_size > 65_536);
  Alcotest.check last_line_testable "the reason comes back whole"
    (L.Said "[FATAL] Port 8935 is still in use after 5 retries.")
    report.L.last_line

let test_last_line_of_text () =
  Alcotest.check last_line_testable "trailing blank lines are skipped"
    (L.Said "reason") (L.last_line_of_text "a\nreason\n\n  \n");
  Alcotest.check last_line_testable "nothing written" L.Said_nothing
    (L.last_line_of_text "");
  Alcotest.check last_line_testable "only blanks" L.Said_nothing
    (L.last_line_of_text "\n \n")

(* Nothing answering is the only reading that calls for a server, and one
   spawn is the whole session's budget: a refresh also fails for reasons a new
   server would not fix, and a second masc on this port would only fail to
   bind.

   The reading, not the message, is what decides. A port with nothing on it
   refuses each request separately, so the refresh completes with every
   surface in error rather than throwing -- which is the shape a first install
   produces, and the shape that reached no server start while this was keyed
   on a thrown refresh instead. *)
let test_start_is_due_only_when_nothing_answered () =
  Alcotest.(check bool)
    "nothing answered starts one" true
    (L.start_due ~contact:L.Nothing_answered ~already_attempted:false);
  Alcotest.(check bool)
    "a second failed poll does not start another" false
    (L.start_due ~contact:L.Nothing_answered ~already_attempted:true);
  Alcotest.(check bool)
    "a server that answered needs none" false
    (L.start_due ~contact:L.Server_reached ~already_attempted:false);
  Alcotest.(check bool)
    "no reading yet starts nothing" false
    (L.start_due ~contact:L.Undecided ~already_attempted:false)

(* The command handed to an operator whose TUI could not find the binary has
   to start a server. Bare [masc] on a terminal is the front door and opens
   the TUI, so without [start] the advice loops the operator back to the
   screen they are already looking at. *)
let test_manual_command_starts_a_server () =
  match
    L.discover_server_binary ~tui_exe:"/nowhere/masc-tui"
      ~file_exists:(fun _ -> false)
      ~path_lookup:(fun _ -> None)
      ~base_path:"/ws" ~host:"127.0.0.1" ~port:8935
  with
  | L.Sibling _ | L.On_path _ -> Alcotest.fail "nothing should have been found"
  | L.Not_found { manual_command } ->
      Alcotest.(check string)
        "the manual command serves rather than opening the TUI"
        "masc start --base-path /ws --host 127.0.0.1 --port 8935"
        manual_command

let () =
  Alcotest.run "tui_server_lifecycle"
    [
      ( "discovery",
        [
          Alcotest.test_case "prefers sibling" `Quick test_discover_prefers_sibling;
          Alcotest.test_case "falls back to PATH" `Quick
            test_discover_falls_back_to_path;
          Alcotest.test_case "not found carries command" `Quick
            test_discover_not_found_carries_command;
        ] );
      ( "argv",
        [ Alcotest.test_case "exact argv" `Quick test_server_argv ] );
      ( "wait_healthy",
        [
          Alcotest.test_case "ready immediately" `Quick test_wait_ready_immediately;
          Alcotest.test_case "ready on third" `Quick test_wait_ready_on_third;
          Alcotest.test_case "server exited" `Quick test_wait_server_exited;
          Alcotest.test_case "times out" `Quick test_wait_times_out;
          Alcotest.test_case "zero attempts" `Quick test_wait_zero_attempts;
        ] );
      ( "start_due",
        [
          Alcotest.test_case "only when nothing answered" `Quick
            test_start_is_due_only_when_nothing_answered;
          Alcotest.test_case "the manual command starts a server" `Quick
            test_manual_command_starts_a_server;
        ] );
      ( "start_stop",
        [ Alcotest.test_case "start then stop is reaped" `Quick test_start_stop_reaped ]
      );
      ( "startup_output",
        [
          Alcotest.test_case "a refusal is read back with its status" `Quick
            test_a_refusal_is_read_back_with_its_status;
          Alcotest.test_case "each start empties its file" `Quick
            test_each_start_empties_its_file;
          Alcotest.test_case "an unopenable log does not stop the start" `Quick
            test_an_unopenable_log_does_not_stop_the_start;
          Alcotest.test_case "the tail read keeps the last line whole" `Quick
            test_the_tail_read_keeps_the_last_line_whole;
          Alcotest.test_case "last line of text" `Quick test_last_line_of_text;
        ] );
    ]
