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

(* A damaged owner record may still name a live browser. Losing the record
   and emptying its profile would make that browser impossible to recover. *)
let test_malformed_owner_record_blocks_profile_reset () =
  let masc_root = Filename.temp_dir "masc-stagehand-owner-" "" in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree masc_root)
  @@ fun () ->
  let profile = Process.server_profile ~masc_root in
  let record = Process.owner_record_path ~masc_root in
  Fs_compat.mkdir_p profile;
  Out_channel.with_open_text record (fun output -> output_string output "{broken owner record");
  let marker = Filename.concat profile "must-survive" in
  Out_channel.with_open_text marker (fun output -> output_string output "profile in use");
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  let config : Masc.Browser_configuration.stagehand =
    { chrome = Filename.concat masc_root "missing-chromium"; extension = masc_root; profile = None }
  in
  (match
     Stagehand.open_ ~sw ~env ~masc_root ~config ~headless:true
       ~model:(fun _ -> fail "the model is not called") ~log:(fun _ -> ())
   with
   | Error detail ->
     check bool "the record is the refusal" true
       (String.starts_with ~prefix:"malformed stagehand owner record" detail)
   | Ok _ -> fail "a malformed owner record must block a new browser");
  check bool "the owner record remains for repair" true (Sys.file_exists record);
  check bool "the previous browser profile is untouched" true (Sys.file_exists marker)
;;

(* A live PID with a different command is not proof that the old browser's
   profile is safe to erase. Keep the record for an operator to inspect. *)
let test_unmatched_live_pid_blocks_profile_reset () =
  let masc_root = Filename.temp_dir "masc-stagehand-live-pid-" "" in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree masc_root)
  @@ fun () ->
  let profile = Process.server_profile ~masc_root in
  let record = Process.owner_record_path ~masc_root in
  Fs_compat.mkdir_p profile;
  let chrome = Filename.concat masc_root "missing-chromium" in
  let owner : Process.owner = { pid = Unix.getpid (); chrome; profile } in
  Out_channel.with_open_text record (fun output ->
    output_string output (Process.owner_to_string owner));
  let marker = Filename.concat profile "must-survive" in
  Out_channel.with_open_text marker (fun output -> output_string output "profile in use");
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  let config : Masc.Browser_configuration.stagehand =
    { chrome; extension = masc_root; profile = None }
  in
  (match
     Stagehand.open_ ~sw ~env ~masc_root ~config ~headless:true
       ~model:(fun _ -> fail "the model is not called") ~log:(fun _ -> ())
   with
   | Error detail ->
     check bool "the refusal identifies the live recorded PID" true
       (String.starts_with
          ~prefix:(Printf.sprintf "recorded Chromium pid %d" (Unix.getpid ()))
          detail)
   | Ok _ -> fail "an unmatched live PID must block a new browser");
  check bool "the unmatched PID record remains" true (Sys.file_exists record);
  check bool "the previous browser profile remains" true (Sys.file_exists marker)
;;

(* A process group can outlive the leader recorded as its PGID. Leader ESRCH
   alone cannot authorize clearing the record or its still-used profile. *)
let test_dead_leader_with_live_group_blocks_profile_reset () =
  let ready_read, ready_write = Unix.pipe () in
  let leader =
    match Unix.fork () with
    | 0 ->
      Unix.close ready_read;
      (try
         ignore (Unix.setsid ());
         (match Unix.fork () with
          | 0 ->
            Unix.close ready_write;
            Unix.sleep 60;
            Unix._exit 0
          | _ ->
            let ready = Bytes.of_string "R" in
            ignore (Unix.write ready_write ready 0 1);
            Unix.close ready_write;
            Unix._exit 0)
       with _ -> Unix._exit 1)
    | pid -> pid
  in
  Unix.close ready_write;
  Fun.protect
    ~finally:(fun () ->
      Unix.close ready_read;
      (try Unix.kill (-leader) Sys.sigkill with
       | Unix.Unix_error (Unix.ESRCH, _, _) -> ()))
  @@ fun () ->
  let ready = Bytes.create 1 in
  let count = Unix.read ready_read ready 0 1 in
  ignore (Unix.waitpid [] leader);
  check int "the orphan group was created" 1 count;
  (match Unix.kill leader 0 with
   | () -> fail "the group leader should have exited"
   | exception Unix.Unix_error (Unix.ESRCH, _, _) -> ());
  let masc_root = Filename.temp_dir "masc-stagehand-orphan-group-" "" in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree masc_root)
  @@ fun () ->
  let profile = Process.server_profile ~masc_root in
  let record = Process.owner_record_path ~masc_root in
  Fs_compat.mkdir_p profile;
  let chrome = Filename.concat masc_root "missing-chromium" in
  let owner : Process.owner = { pid = leader; chrome; profile } in
  Out_channel.with_open_text record (fun output ->
    output_string output (Process.owner_to_string owner));
  let marker = Filename.concat profile "must-survive" in
  Out_channel.with_open_text marker (fun output -> output_string output "profile in use");
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  let config : Masc.Browser_configuration.stagehand =
    { chrome; extension = masc_root; profile = None }
  in
  (match
     Stagehand.open_ ~sw ~env ~masc_root ~config ~headless:true
       ~model:(fun _ -> fail "the model is not called") ~log:(fun _ -> ())
   with
   | Error detail ->
     check bool "the live group is the refusal" true
       (String.starts_with
          ~prefix:(Printf.sprintf "recorded Chromium group %d is still alive" leader)
          detail)
   | Ok _ -> fail "a live orphan group must block a new browser");
  check bool "the orphan group owner record remains" true (Sys.file_exists record);
  check bool "the orphan group profile remains" true (Sys.file_exists marker)
;;

let () =
  run "server_browser_stagehand"
    [ "lifetime"
    , [ test_case "failed open stops Chromium before same-switch retry" `Quick
          test_failure_stops_child_before_same_switch_retry
      ; test_case "malformed owner record blocks profile reset" `Quick
          test_malformed_owner_record_blocks_profile_reset
      ; test_case "unmatched live PID blocks profile reset" `Quick
          test_unmatched_live_pid_blocks_profile_reset
      ; test_case "dead leader with live group blocks profile reset" `Quick
          test_dead_leader_with_live_group_blocks_profile_reset
      ]
    ]
