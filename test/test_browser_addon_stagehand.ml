module Chrome = Masc.Browser_addon_stagehand
module Socket = Masc.Browser_addon_socket
module Owner = Masc.Browser_addon_owner
module Wire = Masc.Browser_addon_wire
module Lease = Native_addon_lease
module B = Browser_lane
let launcher=ref "" and guardian=ref ""
let ok = function Ok value -> value | Error detail -> Alcotest.fail detail
let lease result = ok (Result.map_error Lease.error_to_string result)
let check = Alcotest.check Alcotest.bool
let rec remove path = match (Unix.lstat path).Unix.st_kind with
  | Unix.S_DIR -> Array.iter (fun name -> remove (Filename.concat path name)) (Sys.readdir path);Unix.rmdir path
  | Unix.S_REG | Unix.S_LNK | Unix.S_CHR | Unix.S_BLK | Unix.S_FIFO | Unix.S_SOCK -> Unix.unlink path
let stopped pid = match Unix.kill pid 0 with
  | () -> false
  | exception Unix.Unix_error (Unix.ESRCH,_,_) -> true
let child_stopped claim = match lease (Lease.status claim) with
  | Lease.Settled -> true
  | Awaiting_exec | Live _ | Cleanup_pending _ -> false
let receipt = function
  | Wire.Receipt -> true
  | Snapshot_result _ | Model_reply _ | Download_reply _ | Poll_result _ | Issue_result _ | Service_refusal _ -> false
let refused = function
  | Wire.Issue_result (Ok (B.Refused _)) -> true
  | Issue_result (Ok (Answered _ | Lane_absent | Timed_out | Rejected_before_effect _))
  | Issue_result (Error _) | Snapshot_result _ | Model_reply _ | Download_reply _ | Poll_result _ | Receipt | Service_refusal _ -> false

let scenario () =
  let root=Filename.temp_dir "browser-addon-chrome-" "" |> Unix.realpath in
  let claim=ref None and configuration=ref None and allocation=ref None in
  let incarnation=Uuidm.(to_string (v4_gen (Random.State.make_self_init ()) ())) in
  Fun.protect ~finally:(fun () ->
    let safe=match !claim,!configuration,!allocation with
      | Some admission,Some c,Some directory ->
        Result.is_ok (Lease.retire admission) && Result.is_ok (Chrome.settle c ~incarnation ~directory)
        && Result.is_ok (Socket.cleanup ~admission ~directory:(Filename.concat root "worker-slot"))
      | None,None,None -> true
      | _ -> false in
    if safe then remove root else prerr_endline ("retained unconfirmed Chrome fixture: " ^ root)) (fun () ->
  Eio_main.run (fun env ->
    Time_compat.set_clock (Eio.Stdenv.clock env);
    Fs_compat.set_fs (Eio.Stdenv.fs env);
    Eio.Time.with_timeout_exn (Eio.Stdenv.clock env) 30. (fun () -> Eio.Switch.run (fun sw ->
      let listener=Eio.Net.listen (Eio.Stdenv.net env) ~sw ~reuse_addr:true ~backlog:4
        (`Tcp (Eio.Net.Ipaddr.V4.loopback,0)) in
      let port=match Eio.Net.listening_addr listener with
        | `Tcp (_,port) -> port | `Unix _ -> Alcotest.fail "expected a TCP listener" in
      let third_connection,connected=Eio.Promise.create () in
      Eio.Fiber.fork_daemon ~sw (fun () ->
        for attempt=1 to 3 do
          Eio.Switch.run (fun peer ->
            let flow,_=Eio.Net.accept ~sw:peer listener in
            if attempt<3 then Eio.Flow.close flow
            else (Eio.Promise.resolve connected ();Eio.Fiber.await_cancel ()))
        done;
        `Stop_daemon);
      let executable=Filename.concat root "chromium" in
      Out_channel.with_open_bin executable (fun out -> Printf.fprintf out {|#!/usr/bin/env python3
import os, sys, time
profile = next(arg.split("=", 1)[1] for arg in sys.argv[1:] if arg.startswith("--user-data-dir="))
with open(os.path.join(profile, "child-pid"), "w") as f:
    f.write(str(os.getpid()))
with open(os.path.join(profile, "DevToolsActivePort"), "w") as f:
    f.write("%d\n/devtools/browser/addon-fixture\n")
while True:
    time.sleep(60)
|} port);
      Unix.chmod executable 0o700;
      let browser : Browser_configuration.stagehand = {chrome=executable;extension=root;profile=None} in
      check "a relative persistent profile is refused" true
        (Result.is_error (Chrome.configuration ~browser:{browser with profile=Some "relative-profile"}
          ~launcher:!launcher ~guardian:!guardian ~claim_directory:(Filename.concat root "chrome-slot")));
      let c=ok (Chrome.configuration ~browser ~launcher:!launcher ~guardian:!guardian
        ~claim_directory:(Filename.concat root "chrome-slot")) in
      check "strict configuration rejects an extra control field" true
        (let fields=match Chrome.configuration_to_json c with `Assoc fields -> fields | _ -> Alcotest.fail "expected object" in
         Result.is_error (Chrome.configuration_of_json (`Assoc (("profile",`String root)::fields))));
      let context=ok (Socket.context ~instance_id:incarnation ~automation:None ~models:None ~stagehand:(Some c)) in
      let admission=lease (Lease.prepare ~directories:[Filename.concat root "worker-slot"]
        ~instance_id:incarnation ~cleanup_context:(Some context)) in
      claim:=Some admission;
      let resource=ok (Socket.acquire ~admission ~directory:(Filename.concat root "worker-slot")) in
      let directory=Filename.dirname (Socket.socket_path resource) in
      configuration:=Some c;allocation:=Some directory;
      check "host acquisition selects the Chrome worker path" true
        (List.mem "--stagehand" (Socket.arguments resource ~max_message_bytes:1048576));
      let owner=ok (Owner.create ~incarnation) in
      Eio.Switch.on_release sw (fun () -> Owner.revoke owner);
      let send command=Owner.dispatch owner {Wire.incarnation;command} in
      let issue verb=send (Wire.Issue {route=B.Stagehand_route;verb;actor=Some "chrome-fixture";
        timeout_sec=25.;only_if_idle=false}) in
      let original_ids=ref [] in
      let rec wait_closed () = match B.server_session_observation B.Server_stagehand with
        | B.Browser_closed -> ()
        | Browser_open | Browser_changing | Browser_unknown -> Eio.Fiber.yield ();wait_closed () in
      let inspect () =
        let child=lease (Lease.current ~directories:[Filename.concat root "chrome-slot"]) in
        original_ids:=Lease.instance_id child:: !original_ids;
        check "failed startup settled its original native group" true (child_stopped child);
        child in
      Chrome.run ~env ~owner ~directory (fun () ->
        let _,chrome=ok (Masc.Browser_addon_inventory.owned_of_json
          (Yojson.Safe.Util.member "owned_backends" (Owner.snapshot owner))) in
        check "actual Chrome backend is registered without inventing an open browser" true
          (chrome.registered && chrome.session=B.Browser_closed && not chrome.locate);
        check "unselected model work is refused before opening Chrome" true
          (match issue (B.Page_locate {tab_id=0;instruction=None}) with
           | Wire.Issue_result (Ok (B.Rejected_before_effect _)) -> true
           | _ -> false);
        check "first CDP refusal reaches the actual controller" true
          (refused (issue (B.Session_open {headless=Some true})));
        let first=inspect () in
        wait_closed ();
        check "second CDP refusal can start on the same owner" true
          (refused (issue (B.Session_open {headless=Some true})));
        let second=inspect () in
        wait_closed ();
        check "a later open never reuses a consumed child admission" true (Lease.instance_id first<>Lease.instance_id second);
        let opening=Eio.Fiber.fork_promise ~sw (fun () -> issue (B.Session_open {headless=Some true})) in
        Eio.Promise.await third_connection;
        check "retirement joins the actual Chrome owner during CDP startup" true (receipt (send Wire.Retire));
        let third=inspect () in
        check "retirement is idempotent" true (receipt (send Wire.Retire));
        ignore (Eio.Promise.await_exn opening);
        let ids=Sys.readdir (Filename.concat directory "chromium-profiles") |> Array.to_list in
        Alcotest.check Alcotest.int "exactly the three requested starts occurred" 3 (List.length ids);
        List.iter (fun id ->
          let file=Filename.concat (Filename.concat (Filename.concat directory "chromium-profiles") id) "child-pid" in
          let pid=In_channel.with_open_text file (fun input -> int_of_string (input_line input)) in
          check "each actual Chromium child stopped" true (stopped pid)) ids;
        check "retired child cannot be admitted again" true
          (Result.is_error (Lease.prepare ~directories:[Filename.concat root "chrome-slot"]
            ~instance_id:(Lease.instance_id third) ~cleanup_context:None)));
      let outside=Filename.concat root "outside-profile" in
      Out_channel.with_open_text outside (fun out -> output_string out "must survive");
      let first=List.hd !original_ids in
      let profile=Filename.concat (Filename.concat directory "chromium-profiles") first in
      Unix.symlink outside (Filename.concat profile "external-link");
      lease (Lease.retire admission);
      ok (Socket.cleanup ~admission ~directory:(Filename.concat root "worker-slot"));
      check "host cleanup released the original allocation" false (Sys.file_exists directory);
      check "profile cleanup never follows a symlink" true (Sys.file_exists outside);
      check "child admission ledger survives profile cleanup" true (Sys.file_exists (Filename.concat root "chrome-slot/lease"))))))

let identity_scenario () =
  let root=Filename.temp_dir "browser-addon-identity-" "" |> Unix.realpath in
  let admission=ref None in
  Fun.protect ~finally:(fun () ->
    let safe=match !admission with
      | None -> true
      | Some claim -> Result.is_ok (Lease.retire claim) && child_stopped claim in
    if safe then remove root else prerr_endline ("retained unconfirmed identity fixture: " ^ root)) (fun () ->
  Eio_main.run (fun env ->
    Eio.Time.with_timeout_exn (Eio.Stdenv.clock env) 30. (fun () -> Eio.Switch.run (fun sw ->
      let claim=lease (Lease.prepare ~directories:[Filename.concat root "slot"]
        ~instance_id:"browser-identity" ~cleanup_context:None) in
      admission:=Some claim;
      let input,keepalive=Eio_unix.pipe sw and ready,output=Eio_unix.pipe sw in
      let log=Eio.Path.open_out ~sw ~create:(`Exclusive 0o600)
        Eio.Path.(Eio.Stdenv.fs env / Filename.concat root "owner.log") in
      let process=Eio.Process.spawn ~sw
        (Posix_spawn_process_mgr.foreground_mgr ~clock:(Eio.Stdenv.clock env) ~grace_seconds:5.)
        ~stdin:input ~stdout:output ~stderr:log
        [!launcher;"--instance";"browser-identity";"--slot";Filename.concat root "slot";"--";
         !guardian;"--instance";"browser-identity";"--";"/usr/bin/env";"python3";"-c";"import time;time.sleep(60)"] in
      Eio.Flow.close input;Eio.Flow.close output;
      Eio.Switch.on_release sw (fun () ->
        ignore (Eio_unix.run_in_systhread (fun () -> Lease.retire claim));
        Eio.Flow.close keepalive;Eio.Process.signal process Sys.sigterm);
      let receipt=Eio.Buf_read.of_flow ready ~max_size:1024 |> Eio.Buf_read.line
        |> Yojson.Safe.from_string |> Browser_process_owner.ready_of_json |> ok in
      check "the receipt names the actual original guardian" true (receipt.owner_pid=Eio.Process.pid process);
      let connection ~pid ~before_reply =
        let writes=ref [] and closes=ref 0 in
        let inbox=Eio.Stream.create 1 in
        let cdp=Masc.Browser_cdp.create ~clock:(Eio.Stdenv.clock env) ~command_deadline_s:15.
          ~send:(fun frame -> let value=Yojson.Safe.from_string frame in
            writes:=value:: !writes;Eio.Stream.add inbox value)
          ~close:(fun () -> incr closes) ~on_event:(fun _ -> ()) in
        Eio.Fiber.fork_daemon ~sw (fun () ->
          let request=Eio.Stream.take inbox in
          check "only the read-only identity query precedes admission" true
            (Yojson.Safe.Util.member "method" request=`String "SystemInfo.getProcessInfo");
          before_reply ();
          Masc.Browser_cdp.receive cdp (Yojson.Safe.to_string (`Assoc [
            "id",Yojson.Safe.Util.member "id" request;
            "result",`Assoc ["processInfo",`List [`Assoc ["type",`String "browser";"id",`Int pid]]]]));
          `Stop_daemon);
        cdp,writes,closes in
      let bad,writes,closes=connection ~pid:receipt.child_pid ~before_reply:(fun () -> ()) in
      check "a changed child incarnation refuses before any CDP command" true
        (Result.is_error (Chrome.verify_browser ~admission:claim
          ~receipt:{receipt with child_started="different child"} bad));
      Alcotest.check Alcotest.int "no command reaches a stale child" 0 (List.length !writes);
      Alcotest.check Alcotest.int "only the refused connection closes" 1 !closes;
      let foreign,writes,closes=connection ~pid:(Unix.getpid ()) ~before_reply:(fun () -> ()) in
      check "another browser PID cannot inherit a debugging endpoint" true
        (Result.is_error (Chrome.verify_browser ~admission:claim ~receipt foreign));
      Alcotest.check Alcotest.int "no extension/page command follows a foreign reply" 1 (List.length !writes);
      Alcotest.check Alcotest.int "the foreign connection is closed" 1 !closes;
      let current,writes,closes=connection ~pid:receipt.child_pid ~before_reply:(fun () -> ()) in
      ok (Chrome.verify_browser ~admission:claim ~receipt current);
      Alcotest.check Alcotest.int "the owned connection stays open" 0 !closes;
      Alcotest.check Alcotest.int "identity admission sends one read-only query" 1 (List.length !writes);
      let late,_,closes=connection ~pid:receipt.child_pid ~before_reply:(fun () ->
        lease (Eio_unix.run_in_systhread (fun () -> Lease.request_termination claim));
        ignore (Eio.Process.await process)) in
      check "a matching PID reply after owner loss still refuses" true
        (Result.is_error (Chrome.verify_browser ~admission:claim ~receipt late));
      Alcotest.check Alcotest.int "late identity response closes its connection" 1 !closes;
      check "original group cleanup is confirmed separately" true (child_stopped claim)))))

let () =
  if Array.length Sys.argv<>3 then (prerr_endline "expected native launcher and browser process owner";exit 1);
  launcher:=Unix.realpath Sys.argv.(1);guardian:=Unix.realpath Sys.argv.(2);
  Alcotest.run ~argv:[|Sys.argv.(0)|] "browser addon Chrome" ["lifecycle",[
    Alcotest.test_case "host allocation, real process ownership, failed startup and concurrent detach" `Quick scenario;
    Alcotest.test_case "CDP identity requires the original live browser child" `Quick identity_scenario]]
