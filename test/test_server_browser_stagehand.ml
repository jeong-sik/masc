(* A refused CDP connection after spawn must release the child before open_
   returns: the same switch can then reuse the server profile safely. *)
open Alcotest
module Stagehand = Server_browser_stagehand
module Process = Masc.Browser_chromium_process

let read path =
  let input = open_in path in
  Fun.protect ~finally:(fun () -> close_in input) (fun () -> input_line input)
;;

let stopped pid =
  match Unix.kill pid 0 with
  | () -> false
  | exception Unix.Unix_error (Unix.ESRCH, _, _) -> true
;;

let fake_chromium ~path ~port =
  let script =
    Printf.sprintf
      "#!/bin/sh\nfor arg in \"$@\"; do\n  case \"$arg\" in --user-data-dir=*) profile=${arg#--user-data-dir=};; esac\ndone\nprintf '%%s\\n' \"$$\" > \"$profile/../started-pid\"\nprintf '%d\\n/devtools/browser/fake\\n' > \"$profile/DevToolsActivePort\"\nexec sleep 60\n"
      port
  in
  let output = open_out path in
  Fun.protect ~finally:(fun () -> close_out output) (fun () -> output_string output script);
  Unix.chmod path 0o700
;;

let test_failure_stops_child_before_same_switch_retry () =
  let masc_root = Filename.temp_dir "masc-stagehand-cleanup-" "" in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree masc_root)
  @@ fun () ->
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  let clock = Eio.Stdenv.clock env in
  let listener =
    Eio.Net.listen (Eio.Stdenv.net env) ~sw ~reuse_addr:true ~backlog:2
      (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
  in
  let port =
    match Eio.Net.listening_addr listener with
    | `Tcp (_, port) -> port
    | `Unix _ -> fail "expected a TCP listener"
  in
  Eio.Fiber.fork ~sw (fun () ->
    for _attempt = 1 to 2 do
      Eio.Switch.run (fun peer_sw ->
        let flow, _ = Eio.Net.accept ~sw:peer_sw listener in
        Eio.Flow.close flow)
    done);
  let chrome = Filename.concat masc_root "fake-chromium" in
  fake_chromium ~path:chrome ~port;
  let config : Masc.Browser_configuration.stagehand = { chrome; extension = masc_root; profile = None } in
  let profile = Process.server_profile ~masc_root in
  let record = Process.owner_record_path ~masc_root in
  let log_path = Filename.concat (Filename.dirname profile) "chromium.log" in
  Fs_compat.mkdir_p (Filename.dirname profile);
  let previous_log = open_out log_path in
  output_string previous_log "previous Chromium failure\n";
  close_out previous_log;
  let started_pid = Filename.concat (Filename.dirname profile) "started-pid" in
  let attempt () =
    (* The foreground process manager grants the group its full 5 s TERM
       grace even when the fake Chromium leader exits immediately. Allow
       time for CDP refusal and scheduling before that cleanup completes. *)
    Eio.Time.with_timeout_exn clock 10.0 (fun () ->
      Stagehand.open_ ~sw ~env ~masc_root ~config ~headless:true
        ~model:(fun _ -> fail "the model is not called before attach") ~log:(fun _ -> ()))
  in
  (match attempt () with
   | Error detail -> check bool "first failure reached CDP" true (String.starts_with ~prefix:"CDP connection:" detail)
   | Ok _ -> fail "a refused CDP upgrade opened a session");
  let first_pid = int_of_string (read started_pid) in
  check string "previous failure log survives first launch" "previous Chromium failure" (read log_path);
  check bool "first Chromium stopped before Error" true (stopped first_pid);
  check bool "first owner record removed" false (Sys.file_exists record);
  let stale = Filename.concat profile "stale-from-first-attempt" in
  let output = open_out stale in
  close_out output;
  (match attempt () with
   | Error detail -> check bool "second failure reached CDP" true (String.starts_with ~prefix:"CDP connection:" detail)
   | Ok _ -> fail "the second refused CDP upgrade opened a session");
  let second_pid = int_of_string (read started_pid) in
  check string "previous failure log survives retry" "previous Chromium failure" (read log_path);
  check bool "second Chromium stopped before Error" true (stopped second_pid);
  check bool "second owner record removed" false (Sys.file_exists record);
  check bool "server profile was safe to recreate" false (Sys.file_exists stale)
;;

let () =
  run "server_browser_stagehand"
    [ "lifetime", [ test_case "failed open stops Chromium before same-switch retry" `Quick test_failure_stops_child_before_same_switch_retry ] ]
