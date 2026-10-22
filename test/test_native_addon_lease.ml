module Lease = Native_addon_lease
type fixture = { root : string; children : int list ref; releases : string list ref }
let launcher = ref ""
let ok = function Ok value -> value | Error error -> Alcotest.fail (Lease.error_to_string error)
let rejected = function Ok _ -> Alcotest.fail "unexpected admission" | Error _ -> ()
let check = Alcotest.check Alcotest.bool
let contains text fragment =
  let size = String.length fragment and limit = String.length text in
  let rec at index = index + size <= limit
    && (String.equal (String.sub text index size) fragment || at (index + 1)) in
  at 0
let not_private label fragments = function
  | Error (Lease.Resource_not_private detail) ->
      List.iter (fun fragment -> check (label ^ " names " ^ fragment) true (contains detail fragment)) fragments
  | Ok _ | Error _ -> Alcotest.fail (label ^ " was not refused as not private")
let write path text =
  let channel = open_out path in
  Fun.protect ~finally:(fun () -> close_out channel) (fun () -> output_string channel text)
let rec remove path =
  match (Unix.lstat path).Unix.st_kind with
  | Unix.S_DIR -> Array.iter (fun name -> remove (Filename.concat path name)) (Sys.readdir path);Unix.rmdir path
  | Unix.S_REG | Unix.S_LNK | Unix.S_CHR | Unix.S_BLK | Unix.S_FIFO | Unix.S_SOCK -> Unix.unlink path
let wait_for label predicate =
  let deadline = Unix.gettimeofday () +. 10. in
  let rec loop () =
    if predicate () then ()
    else if Unix.gettimeofday () >= deadline then Alcotest.fail ("fixture did not settle: " ^ label)
    else (Unix.sleepf 0.005; loop ()) in
  loop ()
let with_fixture work =
  let root = Filename.temp_file "masc-native-admission-" "" in
  Unix.unlink root; Unix.mkdir root 0o700;
  let fixture = {root;children=ref [];releases=ref []} in
  Fun.protect ~finally:(fun () ->
    List.iter (fun path -> write path "release") !(fixture.releases);
    List.iter (fun pid ->
      (try Unix.kill (-pid) Sys.sigkill with Unix.Unix_error (Unix.ESRCH,_,_) -> ());
      ignore (Unix.waitpid [] pid)) !(fixture.children);
    remove root) (fun () -> work fixture)
let path fixture name = Filename.concat fixture.root name
let prepare directories instance_id = ok (Lease.prepare ~cleanup_context:None ~directories ~instance_id)
let spawn fixture claim arguments =
  let argv = Array.of_list (!launcher :: "--instance" :: Lease.instance_id claim ::
    List.concat_map (fun directory -> ["--slot";directory]) (Lease.directories claim) @
    ["--";"/usr/bin/env";"python3";"-c"] @ arguments) in
  match Unix.fork () with
  | 0 -> ignore (Unix.setsid ());Unix.execv !launcher argv
  | pid -> fixture.children := pid :: !(fixture.children);pid
let reap fixture pid =
  let outcome = ref None in
  wait_for "owned child exit" (fun () ->
    match Unix.waitpid [Unix.WNOHANG] pid with
    | 0,_ -> false
    | _,status -> fixture.children := List.filter ((<>) pid) !(fixture.children);
        outcome := Some status;true);
  match !outcome with Some status -> status | None -> Alcotest.fail "missing child exit"
let running claim = match ok (Lease.status claim) with
  | Lease.Live process -> Some process
  | Lease.Awaiting_exec | Lease.Cleanup_pending _ | Lease.Settled -> None
let live claim =
  wait_for "live kernel lease" (fun () -> Option.is_some (running claim));
  match running claim with Some process -> process | None -> Alcotest.fail "lost live process"
let settled claim = wait_for "released claim" (fun () ->
  match ok (Lease.status claim) with
  | Lease.Settled -> true | Lease.Live _ | Lease.Awaiting_exec | Lease.Cleanup_pending _ -> false)
let payload = "import pathlib,sys,time\npathlib.Path(sys.argv[1]).write_text('started')\nwhile True: time.sleep(.01)"
let start fixture claim name =
  let marker = path fixture name in
  let pid = spawn fixture claim [payload;marker] in
  let process = live claim in
  check "receipt names actual child" true (process.pid=pid);
  wait_for "payload started" (fun () -> Sys.file_exists marker);
  pid
let stop fixture claim pid =
  ok (Lease.request_termination claim);
  let status = reap fixture pid in
  check "graceful TERM only" true (status=Unix.WSIGNALED Sys.sigterm);
  settled claim
let denied_launcher fixture claim name =
  let marker = path fixture name in
  let pid = spawn fixture claim [payload;marker] in
  check "launcher refused" true (reap fixture pid=Unix.WEXITED 1);
  check "payload never entered" false (Sys.file_exists marker)
let test_pending_replacement () = with_fixture (fun fixture ->
  let directory = path fixture "slot" in
  let a = prepare [directory;directory ^ "/."] "a" in
  check "canonical duplicate slot" true (List.length (Lease.directories a)=1);
  let b = prepare [directory] "b" in
  denied_launcher fixture a "old-a";
  rejected (Lease.retire a);
  rejected (Lease.prepare ~cleanup_context:None ~directories:[directory] ~instance_id:"a");
  ok (Lease.retire b);settled b;
  denied_launcher fixture b "retired-b";
  rejected (Lease.prepare ~cleanup_context:None ~directories:[directory] ~instance_id:"b"))
let test_live_restart_and_replay () = with_fixture (fun fixture ->
  let directories = [path fixture "installation";path fixture "profile"] in
  let a = prepare directories "a" in
  let pid_a = start fixture a "a-started" in
  rejected (Lease.prepare ~cleanup_context:None ~directories ~instance_id:"b");
  stop fixture a pid_a;
  let b = prepare (List.rev directories) "b" in
  let pid_b = start fixture b "b-started" in
  rejected (Lease.request_termination a);
  check "stale stop preserves replacement" true (Option.is_some (running b));
  stop fixture b pid_b;
  (* Both latest receipts now name B; durable history must still fence A. *)
  rejected (Lease.prepare ~cleanup_context:None ~directories ~instance_id:"a");
  denied_launcher fixture a "replayed-a";
  let c = prepare directories "c" in
  let pid_c = start fixture c "c-started" in
  stop fixture c pid_c)
let test_retired_pending_replay () = with_fixture (fun fixture ->
  let directories = [path fixture "slot"] in
  let a = prepare directories "a" in
  ok (Lease.retire a);settled a;
  let b = prepare directories "b" in
  ok (Lease.retire b);settled b;
  rejected (Lease.prepare ~cleanup_context:None ~directories ~instance_id:"a");
  denied_launcher fixture a "retired-a-replay")
let test_interrupted_history () =
  List.iter (fun contents -> with_fixture (fun fixture ->
    let directory = path fixture "slot" in
    let a = prepare [directory] "a" in
    let digest = Digestif.SHA256.(to_hex (digest_string "a")) in
    (* A crash after truncating a retirement/consumption record must never make
       this existing inode indistinguishable from a never-admitted instance. *)
    write (Filename.concat directory ("instance-" ^ digest ^ ".json")) contents;
    let b = prepare [directory] "b" in
    ok (Lease.retire b);settled b;
    rejected (Lease.prepare ~cleanup_context:None ~directories:[directory] ~instance_id:"a");
    denied_launcher fixture a "interrupted-a-replay")) ["";"{\"instance_id\":"]
let test_partial_slot_replacement () = with_fixture (fun fixture ->
  let first = path fixture "first" and second = path fixture "second" in
  let a = prepare [first;second] "a" in
  let b = prepare [second] "b" in
  denied_launcher fixture a "partial-a";
  let c = prepare [first] "c" in
  let pid_c = start fixture c "c-started" in
  stop fixture c pid_c;
  let pid_b = start fixture b "b-started" in
  stop fixture b pid_b)
let test_leftover_group () = with_fixture (fun fixture ->
  let directories = [path fixture "slot"] in
  let a = prepare directories "a" in
  let marker = path fixture "descendant" and release = path fixture "release" in
  fixture.releases := [release];
  let script = "import os,pathlib,signal,sys,time\npid=os.fork()\nif pid:\n while True: time.sleep(.01)\nsignal.signal(signal.SIGTERM,signal.SIG_IGN)\npathlib.Path(sys.argv[1]).write_text(str(os.getpid()))\nwhile not pathlib.Path(sys.argv[2]).exists(): time.sleep(.01)\nos._exit(0)" in
  let pid = spawn fixture a [script;marker;release] in
  ignore (live a : Lease.process);
  wait_for "descendant ready" (fun () -> Sys.file_exists marker);
  ok (Lease.request_termination a);
  ignore (reap fixture pid : Unix.process_status);
  check "live group prevents release" true
    (match ok (Lease.status a) with Lease.Cleanup_pending _ -> true
     | Lease.Awaiting_exec | Lease.Live _ | Lease.Settled -> false);
  rejected (Lease.prepare ~cleanup_context:None ~directories ~instance_id:"b");
  write release "release";settled a;
  let b = prepare directories "b" in ok (Lease.retire b);settled b)
let test_receipt_not_signal_authority () = with_fixture (fun fixture ->
  let directory = path fixture "slot" in
  let a = prepare [directory] "a" in
  let pid = start fixture a "a-started" in
  let process = live a in
  let receipt started = Yojson.Safe.to_string (`Assoc ["instance_id",`String "a";
    "pid",`Int pid;"started",`String started]) in
  write (Filename.concat directory "owner.json") (receipt "different incarnation");
  rejected (Lease.request_termination a);
  Unix.kill pid 0;
  write (Filename.concat directory "owner.json") (receipt process.started);
  stop fixture a pid)
let test_private_inodes () = with_fixture (fun fixture ->
  let directory = path fixture "real" in Unix.mkdir directory 0o700;
  let alias = path fixture "symlink" in Unix.symlink directory alias;
  rejected (Lease.prepare ~cleanup_context:None ~directories:[alias] ~instance_id:"a");
  Unix.chmod directory 0o755;
  not_private "an open claim directory" [directory;"0755";"0077"]
    (Lease.prepare ~cleanup_context:None ~directories:[directory] ~instance_id:"b");
  Unix.chmod directory 0o700;
  let sentinel = path fixture "sentinel" in write sentinel "preserve";
  Unix.link sentinel (Filename.concat directory "lease");
  not_private "a linked lease file" [Filename.concat directory "lease";"exactly one link";"2 links"]
    (Lease.prepare ~cleanup_context:None ~directories:[directory] ~instance_id:"c");
  let channel = open_in sentinel in
  let contents = Fun.protect ~finally:(fun () -> close_in channel) (fun () -> really_input_string channel 8) in
  Alcotest.check Alcotest.string "unrelated inode preserved" "preserve" contents)
let test_reopen_after_handle_loss () = with_fixture (fun fixture ->
  let directories = [path fixture "installation";path fixture "profile"] in
  let original = prepare directories "original" in
  let pid = start fixture original "original-started" in
  let recovered = ok (Lease.reopen ~directories:(List.rev directories) ~instance_id:"original") in
  let observed = ok (Lease.current ~directories) in
  Alcotest.check Alcotest.string "current ownership comes from retained slots" "original" (Lease.instance_id observed);
  rejected (Lease.reopen ~directories ~instance_id:"different");
  stop fixture recovered pid;
  settled (ok (Lease.reopen ~directories ~instance_id:"original"));
  let replacement = prepare directories "replacement" in
  rejected (Lease.reopen ~directories ~instance_id:"original");
  denied_launcher fixture original "lost-handle-replay";
  ok (Lease.retire replacement))
let test_reopen_never_creates () = with_fixture (fun fixture ->
  let directory = path fixture "slot" in
  let claim = prepare [directory] "a" in
  let owner = Filename.concat directory "owner.json" in
  Unix.unlink owner;
  rejected (Lease.reopen ~directories:[directory] ~instance_id:"a");
  rejected (Lease.current ~directories:[directory]);
  check "missing owner is not recreated" false (Sys.file_exists owner);
  let absent = path fixture "absent" in
  rejected (Lease.reopen ~directories:[absent] ~instance_id:"a");
  check "missing claim directory is not recreated" false (Sys.file_exists absent);
  (* Metadata repair belongs to a fresh admission, not a recovery read. *)
  let next = prepare [directory] "b" in
  denied_launcher fixture claim "damaged-old-claim";
  ok (Lease.retire next))
let test_namespace_sync_failure () = with_fixture (fun fixture ->
  let directory = path fixture "slot" in
  let observed = ref None in
  rejected (Lease.For_testing.prepare ~cleanup_context:None ~directories:[directory] ~instance_id:"a"
    ~sync_ancestry:(fun parent ->
      observed := Some parent;
      raise (Unix.Unix_error (Unix.EIO,"fsync",parent))));
  check "failure occurs after directory creation" true (Sys.file_exists directory);
  check "parent sync was attempted" true (!observed=Some (Unix.realpath fixture.root));
  check "failed namespace cannot publish admission" false (Sys.file_exists (Filename.concat directory "intent.json"));
  let next = prepare [directory] "b" in
  let pid = start fixture next "recovered-after-sync-failure" in
  stop fixture next pid)
let test_partial_preparation_recovery () =
  List.iter (fun interrupted -> with_fixture (fun fixture ->
    let directory = path fixture "slot" in
    Unix.mkdir directory 0o700;
    let metadata name =
      let fd=Unix.openfile (Filename.concat directory name) [Unix.O_CREAT;Unix.O_WRONLY] 0o600 in
      Unix.close fd in
    (match interrupted with
     | `Directory -> ()
     | `Gate -> metadata "gate"
     | `Metadata -> List.iter metadata ["gate";"lease";"intent.json";"owner.json"]
     | `Reservation ->
         ignore (prepare [directory] "interrupted" : Lease.t);
         write (Filename.concat directory "intent.json") "");
    let inode name = try Some (Unix.stat (Filename.concat directory name)).Unix.st_ino
      with Unix.Unix_error (Unix.ENOENT,_,_) -> None in
    let gate=inode "gate" and lease=inode "lease" in
    (match ok (Lease.recover_preparation ~directory) with
     | Lease.Unpublished -> check "only an unreserved bootstrap is unpublished" true (interrupted<>`Reservation)
     | Lease.Current previous ->
         check "interrupted reservation remains permanently fenced" true (interrupted=`Reservation);
         settled previous;
         denied_launcher fixture previous "interrupted-replay";
         rejected (Lease.prepare ~cleanup_context:None ~directories:[directory] ~instance_id:"interrupted"));
    List.iter (fun (name,before) -> match before with
      | None -> () | Some expected -> check "stable synchronization inode preserved" true (inode name=Some expected))
      ["gate",gate;"lease",lease];
    let next=prepare [directory] "replacement" in
    let pid=start fixture next "replacement-started" in
    stop fixture next pid)) [`Directory;`Gate;`Metadata;`Reservation]
let test_preparation_recovery_refuses_uncertain_authority () = with_fixture (fun fixture ->
  let directory=path fixture "slot" in
  let claim=prepare [directory] "consumed" in
  let pid=start fixture claim "consumed-started" in
  let intent=Filename.concat directory "intent.json" in
  let original=In_channel.with_open_bin intent In_channel.input_all in
  write intent "";
  rejected (Lease.recover_preparation ~directory);
  check "failed recovery preserves running payload" true (Posix_spawn_detached.group_id_has_members pid);
  check "missing consumed intent remains unmodified" true
    (In_channel.with_open_bin intent In_channel.input_all="");
  write intent original;
  stop fixture claim pid;
  write intent "{";
  rejected (Lease.recover_preparation ~directory);
  check "damaged published authority is not repaired" true
    (In_channel.with_open_bin intent In_channel.input_all="{"))
let test_cleanup_context () = with_fixture (fun fixture ->
  let directories=[path fixture "installation";path fixture "profile"] in
  let context=Some (`Assoc ["kind",`String "fixture-resource";"path",`String fixture.root]) in
  let claim=ok (Lease.prepare ~directories ~instance_id:"context" ~cleanup_context:context) in
  check "descriptor retained before launch" true (ok (Lease.cleanup_context claim)=context);
  let pid=start fixture claim "context-started" in
  check "launcher consumption preserves descriptor" true (ok (Lease.cleanup_context claim)=context);
  stop fixture claim pid;
  let recovered=ok (Lease.current ~directories) in
  check "retirement and recovery preserve descriptor" true (ok (Lease.cleanup_context recovered)=context);
  let directory=List.hd (Lease.directories claim) in
  let file=Filename.concat directory
    ("instance-" ^ Digestif.SHA256.(to_hex (digest_string "context")) ^ ".json") in
  let fields=match Yojson.Safe.from_file file with `Assoc fields -> fields | _ -> Alcotest.fail "expected history" in
  write file (Yojson.Safe.to_string (`Assoc (List.remove_assoc "cleanup_context" fields)));
  rejected (Lease.cleanup_context claim);
  rejected (Lease.reopen ~directories ~instance_id:"context"))

let () =
  if Array.length Sys.argv <> 2 then failwith "expected actual native Addon launcher path";
  launcher := Unix.realpath Sys.argv.(1);
  (* Alcotest owns argv after removing the launcher argument. *)
  Alcotest.run ~argv:[|Sys.argv.(0)|] "native Addon admission"
    ["real launcher", List.map (fun (name,test) -> Alcotest.test_case name `Quick test)
      ["pending replacement and retirement",test_pending_replacement;
       "live restart and consumed replay",test_live_restart_and_replay;
       "retired pending replay",test_retired_pending_replay;
       "interrupted history cannot resurrect",test_interrupted_history;
       "partial slot replacement",test_partial_slot_replacement;
       "live descendant blocks release",test_leftover_group;
       "receipt is not signaling authority",test_receipt_not_signal_authority;
       "private inode enforcement",test_private_inodes;
       "reopen exact ownership after lost handles",test_reopen_after_handle_loss;
       "reopen never recreates missing authority",test_reopen_never_creates;
       "namespace sync failure refuses admission",test_namespace_sync_failure;
       "interrupted preparation recovers without readmission",test_partial_preparation_recovery;
       "preparation recovery refuses consumed and damaged authority",test_preparation_recovery_refuses_uncertain_authority;
       "cleanup descriptor survives launcher and retirement",test_cleanup_context]]
