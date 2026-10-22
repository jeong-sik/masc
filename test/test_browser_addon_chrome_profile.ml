module Chrome = Masc.Browser_addon_stagehand
module Profile = Masc.Browser_addon_chrome_profile
module Owner = Masc.Browser_addon_owner
module Socket = Masc.Browser_addon_socket
module Wire = Masc.Browser_addon_wire
module Lease = Native_addon_lease
module B = Browser_lane
let ok = function Ok value -> value | Error detail -> Alcotest.fail detail
let lease value = ok (Result.map_error Lease.error_to_string value)
let check = Alcotest.check Alcotest.bool
let rec remove path = match (Unix.lstat path).Unix.st_kind with
  | Unix.S_DIR -> Array.iter (fun name -> remove (Filename.concat path name)) (Sys.readdir path);Unix.rmdir path
  | Unix.S_REG|Unix.S_LNK|Unix.S_CHR|Unix.S_BLK|Unix.S_FIFO|Unix.S_SOCK -> Unix.unlink path
let settled admission = match lease (Lease.status admission) with
  | Lease.Settled -> true | Awaiting_exec|Live _|Cleanup_pending _ -> false
let scenario launcher guardian () =
  let root=Filename.temp_dir "browser-preserved-profile-" "" |> Unix.realpath in
  let incarnation=Uuidm.(to_string (v4_gen (Random.State.make_self_init ()) ())) in
  let original=ref None and configuration=ref None and successor=ref None and allocated=ref None in
  let worker_slot=Filename.concat root "worker-slot" in
  Fun.protect ~finally:(fun () ->
    let clear claim=Result.is_ok (Lease.retire claim) && settled claim in
    let safe=match !original,!configuration,!allocated with
      | Some admission,Some c,Some directory -> clear admission
        && Result.is_ok (Chrome.settle c ~incarnation ~directory)
        && Result.is_ok (Socket.cleanup ~admission ~directory:worker_slot)
      | None,None,None -> true | _ -> false in
    let safe=safe && (match !successor with None -> true | Some claim -> clear claim) in
    if safe then remove root else prerr_endline ("retained uncertain profile fixture: " ^ root)) (fun () ->
  Eio_main.run (fun env ->
    Time_compat.set_clock (Eio.Stdenv.clock env);Fs_compat.set_fs (Eio.Stdenv.fs env);
    Eio.Time.with_timeout_exn (Eio.Stdenv.clock env) 30. (fun () -> Eio.Switch.run (fun sw ->
      let profile_path=Filename.concat root "profile" in Unix.mkdir profile_path 0o700;
      let marker=Filename.concat profile_path "fixture-session" in
      Out_channel.with_open_bin marker (fun out -> output_string out "retained-login-fixture");
      let selected=ok (Profile.select ~path:(Some profile_path)) in
      let profile=match selected with Persistent profile -> profile | Private -> Alcotest.fail "expected preserved profile" in
      check "stable profile descriptor round-trips" true (Profile.of_json (Profile.to_json selected)=Ok selected);
      let singleton=Filename.concat profile_path "SingletonLock" in
      Unix.symlink (Filename.concat root "absent-singleton-target") singleton;
      check "a dangling singleton blocks startup" true (Result.is_error (Profile.before_launch profile));
      check "singleton evidence remains a link" true ((Unix.lstat singleton).Unix.st_kind=Unix.S_LNK);
      Unix.unlink singleton;
      let listener=Eio.Net.listen (Eio.Stdenv.net env) ~sw ~reuse_addr:true ~backlog:4
        (`Tcp (Eio.Net.Ipaddr.V4.loopback,0)) in
      let port=match Eio.Net.listening_addr listener with `Tcp (_,port) -> port | `Unix _ -> Alcotest.fail "TCP listener required" in
      let connected,notify=Eio.Promise.create () in
      Eio.Fiber.fork_daemon ~sw (fun () -> Eio.Switch.run (fun peer ->
        let _flow,_=Eio.Net.accept ~sw:peer listener in
        Eio.Promise.resolve notify ();Eio.Fiber.await_cancel ()));
      let executable=Filename.concat root "chromium" in
      Out_channel.with_open_bin executable (fun out -> Printf.fprintf out {|#!/usr/bin/env python3
import os, sys, time
profile = next(arg.split("=", 1)[1] for arg in sys.argv[1:] if arg.startswith("--user-data-dir="))
with open(os.path.join(profile, "DevToolsActivePort"), "w") as out:
    out.write("%d\n/devtools/browser/preserved-fixture\n")
while True:
    time.sleep(60)
|} port);
      Unix.chmod executable 0o700;
      let browser:Browser_configuration.stagehand={chrome=executable;extension=root;profile=Some profile_path} in
      let c=ok (Chrome.configuration ~browser ~launcher ~guardian ~claim_directory:(Filename.concat root "child-slot")) in
      configuration:=Some c;
      let context=ok (Socket.context ~live_bidi:None ~instance_id:incarnation ~automation:None ~models:None ~stagehand:(Some c)) in
      let admission=lease (Lease.prepare ~directories:[worker_slot] ~instance_id:incarnation ~cleanup_context:(Some context)) in
      original:=Some admission;
      let allocation=ok (Socket.acquire ~admission ~directory:worker_slot) in
      let directory=Filename.dirname (Socket.socket_path allocation) in
      allocated:=Some directory;
      let owner=ok (Owner.create ~incarnation) in
      Eio.Switch.on_release sw (fun () -> Owner.revoke owner);
      let c2=ok (Chrome.configuration ~browser ~launcher ~guardian ~claim_directory:(Filename.concat root "next-child-slot")) in
      Chrome.run ~env ~owner ~directory (fun () ->
        let opening=Eio.Fiber.fork_promise ~sw (fun () -> Owner.dispatch owner {Wire.incarnation;
          command=Issue {route=B.Stagehand_route;verb=Session_open {headless=Some true};actor=None;timeout_sec=25.;only_if_idle=false}}) in
        Eio.Promise.await connected;
        let current=lease (Lease.current ~directories:(Chrome.claim_directories c)) in
        check "the original guardian holds both resource slots" true
          (match lease (Lease.status current) with Live _ -> true | Awaiting_exec|Cleanup_pending _|Settled -> false);
        check "a second installation cannot start on this live profile" true
          (match Lease.prepare ~directories:(Chrome.claim_directories c2) ~instance_id:"blocked-profile" ~cleanup_context:None with
           | Error (Lease.Busy _) -> true | Error _|Ok _ -> false);
        check "Retire joins preserved-profile startup" true
          (match Owner.dispatch owner {Wire.incarnation;command=Retire} with Wire.Receipt -> true | _ -> false);
        ignore (Eio.Promise.await_exn opening));
      let next=lease (Lease.prepare ~directories:(Chrome.claim_directories c2)
        ~instance_id:"next-profile" ~cleanup_context:None) in
      successor:=Some next;
      lease (Lease.retire next);
      ok (Chrome.settle c ~incarnation ~directory);
      lease (Lease.retire admission);
      (match ok (Socket.cleanup ~admission ~directory:worker_slot) with
       | Socket.Allocation_released -> ()
       | Allocation_retained -> Alcotest.fail "the allocation was retained, not released");
      check "old cleanup works after the shared profile intent advances" false (Sys.file_exists directory);
      Alcotest.check Alcotest.string "login fixture survives old-owner cleanup" "retained-login-fixture"
        (In_channel.with_open_bin marker In_channel.input_all);
      ok (Profile.verify profile);
      let gate=Filename.concat (Profile.claim_directory profile) "gate" in
      let saved=Filename.concat root "original-gate" in
      Unix.rename gate saved;
      let replacement=Unix.openfile gate [Unix.O_CREAT;Unix.O_EXCL;Unix.O_WRONLY] 0o600 in Unix.close replacement;
      check "replaced synchronization inode refuses another selection" true
        (Result.is_error (Profile.select ~path:(Some profile_path)));
      Unix.unlink gate;Unix.rename saved gate;
      ok (Profile.verify profile)))))
let () =
  if Array.length Sys.argv<>3 then (prerr_endline "expected native launcher and guardian";exit 1);
  let launcher=Unix.realpath Sys.argv.(1) and guardian=Unix.realpath Sys.argv.(2) in
  Alcotest.run ~argv:[|Sys.argv.(0)|] "browser preserved profile"
    ["lifecycle",[Alcotest.test_case "shared admission, old cleanup and original profile preservation" `Quick (scenario launcher guardian)]]
