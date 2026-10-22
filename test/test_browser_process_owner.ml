module Lease = Native_addon_lease
module Owner = Browser_process_owner
let launcher=ref "" and owner=ref ""
let ok = function Ok value -> value | Error error -> Alcotest.fail (Lease.error_to_string error)
let check = Alcotest.check Alcotest.bool
type fixture = { root:string; mutable children:int list; mutable descriptors:Unix.file_descr list;
  mutable claim:Lease.t option }
let rec remove path = match (Unix.lstat path).Unix.st_kind with
  | Unix.S_DIR -> Array.iter (fun name -> remove (Filename.concat path name)) (Sys.readdir path);Unix.rmdir path
  | Unix.S_REG|Unix.S_LNK|Unix.S_CHR|Unix.S_BLK|Unix.S_FIFO|Unix.S_SOCK -> Unix.unlink path
let close fixture fd =
  Unix.close fd;fixture.descriptors<-List.filter ((<>) fd) fixture.descriptors
let track fixture fd = fixture.descriptors<-fd::fixture.descriptors;fd
let rec reap_blocking pid = try Unix.waitpid [] pid with Unix.Unix_error (Unix.EINTR,_,_) -> reap_blocking pid
let with_fixture work =
  let root=Filename.temp_dir "masc-browser-process-owner-" "" in
  Unix.chmod root 0o700;
  let fixture={root;children=[];descriptors=[];claim=None} in
  Fun.protect ~finally:(fun () ->
    List.iter Unix.close fixture.descriptors;
    (* Each PID here is our own unreaped fork child. It cannot have been reused.
       No PID from a receipt or a process table grants this test's cleanup. *)
    List.iter (fun pid ->
      (try Unix.kill (-pid) Sys.sigkill with Unix.Unix_error (Unix.ESRCH,_,_) -> ());
      (try Unix.kill pid Sys.sigkill with Unix.Unix_error (Unix.ESRCH,_,_) -> ());
      ignore (reap_blocking pid)) fixture.children;
    let released=match fixture.claim with
      | None -> true
      | Some claim ->
        (match Lease.retire claim with
         | Error _ -> false
         | Ok () -> match Lease.status claim with
           | Ok Lease.Settled -> true
           | Error _ | Ok (Awaiting_exec|Live _|Cleanup_pending _) -> false) in
    if released then remove root
    else prerr_endline ("retained unconfirmed browser process fixture: " ^ root)) (fun () -> work fixture)
let wait_for label predicate =
  let deadline=Unix.gettimeofday ()+.15. in
  let rec loop () = if predicate () then ()
    else if Unix.gettimeofday ()>=deadline then Alcotest.fail ("did not settle: " ^ label)
    else (Unix.sleepf 0.005;loop ()) in
  loop ()
let reap fixture pid =
  let result=ref None in
  wait_for "original owner exit" (fun () -> match Unix.waitpid [Unix.WNOHANG] pid with
    | 0,_ -> false
    | _,status -> result:=Some status;fixture.children<-List.filter ((<>) pid) fixture.children;true);
  match !result with Some result -> result | None -> Alcotest.fail "missing exit status"
let settled claim = wait_for "original claim settlement" (fun () -> match ok (Lease.status claim) with
  | Lease.Settled -> true | Awaiting_exec|Live _|Cleanup_pending _ -> false)
let read_line fd =
  let deadline=Unix.gettimeofday ()+.10. and buffer=Buffer.create 128 and byte=Bytes.create 1 in
  let rec loop () =
    let remaining=deadline-.Unix.gettimeofday () in
    if remaining<=0. then Alcotest.fail "missing bootstrap receipt";
    match Unix.select [fd] [] [] remaining with
    | [],_,_ -> Alcotest.fail "bootstrap receipt did not arrive"
    | _ ->
      match Unix.read fd byte 0 1 with
      | 0 -> Alcotest.fail "owner ended before bootstrap receipt"
      | _ -> if Bytes.get byte 0='\n' then Buffer.contents buffer
        else (Buffer.add_char buffer (Bytes.get byte 0);loop ()) in
  loop ()
let fill_pipe fd =
  Unix.set_nonblock fd;
  Fun.protect ~finally:(fun () -> Unix.clear_nonblock fd) (fun () ->
    let fill bytes =
      let rec loop () = match Unix.write fd bytes 0 (Bytes.length bytes) with
        | 0 -> Alcotest.fail "pipe made no write progress"
        | _ -> loop ()
        | exception Unix.Unix_error ((Unix.EAGAIN|Unix.EWOULDBLOCK),_,_) -> ()
        | exception Unix.Unix_error (Unix.EINTR,_,_) -> loop () in
      loop () in
    fill (Bytes.make 4096 'x');fill (Bytes.make 1 'x'))
let spawn_channels ~blocked fixture claim script =
  let input,keepalive=Unix.pipe ~cloexec:true () and output,ready=Unix.pipe ~cloexec:true () in
  List.iter (fun fd -> ignore (track fixture fd)) [input;keepalive;output;ready];
  let log=Unix.openfile (Filename.concat fixture.root "owner.log")
      [Unix.O_WRONLY;Unix.O_CREAT;Unix.O_APPEND;Unix.O_CLOEXEC] 0o600 in
  ignore (track fixture log);
  if blocked then fill_pipe ready;
  let command=[!launcher;"--instance";Lease.instance_id claim] @
    List.concat_map (fun directory -> ["--slot";directory]) (Lease.directories claim) @
    ["--";!owner;"--instance";Lease.instance_id claim;"--";"/usr/bin/env";"python3";"-c";script;fixture.root] in
  match Unix.fork () with
  | 0 ->
    ignore (Unix.setsid ());
    Unix.dup2 input Unix.stdin;Unix.dup2 ready Unix.stdout;Unix.dup2 log Unix.stderr;
    List.iter Unix.close [input;keepalive;output;ready;log];
    Unix.execv !launcher (Array.of_list command)
  | pid ->
    fixture.children<-pid::fixture.children;
    close fixture input;close fixture ready;close fixture log;
    pid,keepalive,output
let spawn fixture claim script =
    let pid,keepalive,output=spawn_channels ~blocked:false fixture claim script in
    let receipt=match Owner.ready_of_json (Yojson.Safe.from_string (read_line output)) with
      | Ok value -> value | Error message -> Alcotest.fail message in
    check "bootstrap instance is original" true (receipt.instance_id=Lease.instance_id claim);
    check "bootstrap owner is original fork child" true (receipt.owner_pid=pid);
    let process=match ok (Lease.status claim) with
      | Lease.Live value -> value
      | Awaiting_exec|Cleanup_pending _|Settled -> Alcotest.fail "owner did not preserve its kernel lease" in
    check "kernel lease names original owner independently" true (process.pid=pid);
    close fixture output;
    pid,keepalive,receipt
let prepare fixture instance =
  let claim=ok (Lease.prepare ~cleanup_context:None
    ~directories:[Filename.concat fixture.root "slot"] ~instance_id:instance) in
  fixture.claim<-Some claim;claim
let tree_script = {|import json,os,pathlib,signal,sys,time
root=pathlib.Path(sys.argv[1])
os.closerange(3,4096)
stdin_eof=(sys.stdin.read()=='')
descendant=os.fork()
if descendant==0:
 signal.signal(signal.SIGTERM,signal.SIG_IGN)
 (root/'descendant-ready').write_text(str(os.getpid()))
 while True: time.sleep(.01)
pending=root/'child-ready.pending'
pending.write_text(json.dumps({'pid':os.getpid(),'descendant':descendant,'stdin_eof':stdin_eof}))
pending.replace(root/'child-ready')
while True: time.sleep(.01)
|}
let wait_tree fixture claim receipt =
  wait_for "browser child and descendant" (fun () ->
    Sys.file_exists (Filename.concat fixture.root "child-ready")
    && Sys.file_exists (Filename.concat fixture.root "descendant-ready"));
  let value=Yojson.Safe.from_file (Filename.concat fixture.root "child-ready") in
  check "receipt child is actual payload" true
    (Yojson.Safe.Util.(value |> member "pid" |> to_int)=receipt.Owner.child_pid);
  check "browser stdin cannot consume the keepalive pipe" true
    (Yojson.Safe.Util.(value |> member "stdin_eof" |> to_bool));
  check "child descriptor closure preserves owner lease" true
    (match ok (Lease.status claim) with Lease.Live value -> value.pid=receipt.owner_pid
     | Awaiting_exec|Cleanup_pending _|Settled -> false)
let check_retired fixture claim pid keepalive =
  check "owner ends through whole-group KILL" true (reap fixture pid=Unix.WSIGNALED Sys.sigkill);
  close fixture keepalive;
  ok (Lease.retire claim);settled claim;
  check "original group has no live browser descendants" false (Posix_spawn_detached.group_id_has_members pid);
  check "consumed instance cannot run again" true
    (Result.is_error (Lease.prepare ~cleanup_context:None ~directories:(Lease.directories claim)
      ~instance_id:(Lease.instance_id claim)));
  let replacement=prepare fixture "replacement" in
  ok (Lease.retire replacement);settled replacement
let test_original_lease_termination () = with_fixture (fun fixture ->
  let claim=prepare fixture "term" in
  let pid,keepalive,receipt=spawn fixture claim tree_script in
  wait_tree fixture claim receipt;
  ok (Lease.request_termination claim);
  check_retired fixture claim pid keepalive)
let test_keepalive_owner_crash () = with_fixture (fun fixture ->
  let claim=prepare fixture "writer-crash" in
  let pid,keepalive,receipt=spawn fixture claim tree_script in
  wait_tree fixture claim receipt;
  (* A separate process is the sole writer, as the browser Add-on worker will
     be. Killing that original process closes the pipe without a stop message. *)
  let parent_read,parent_write=Unix.pipe ~cloexec:true () in
  match Unix.fork () with
  | 0 ->
    Unix.close parent_read;
    ignore (Unix.write_substring parent_write "r" 0 1);Unix.close parent_write;
    while true do Unix.sleep 1 done
  | writer ->
    fixture.children<-writer::fixture.children;
    Unix.close parent_write;
    ignore (track fixture parent_read);
    let byte=Bytes.create 1 in
    ignore (Unix.read parent_read byte 0 1);
    close fixture parent_read;
    close fixture keepalive;
    Unix.kill writer Sys.sigkill;
    ignore (reap fixture writer);
    check "EOF retires browser owner without another command" true
      (reap fixture pid=Unix.WSIGNALED Sys.sigkill);
    ok (Lease.retire claim);settled claim;
    check "EOF clears original browser group" false (Posix_spawn_detached.group_id_has_members pid))
let test_normal_child_exit () = with_fixture (fun fixture ->
  let claim=prepare fixture "normal-exit" in
  let script={|import os,pathlib,signal,sys,time
root=pathlib.Path(sys.argv[1])
if os.fork()==0:
 signal.signal(signal.SIGTERM,signal.SIG_IGN)
 (root/'descendant-ready').write_text(str(os.getpid()))
 while True: time.sleep(.01)
while not (root/'descendant-ready').exists() or not (root/'allow-exit').exists(): time.sleep(.01)
|} in
  let pid,keepalive,_=spawn fixture claim script in
  Out_channel.with_open_text (Filename.concat fixture.root "allow-exit") (fun output -> output_string output "exit");
  check_retired fixture claim pid keepalive)
let test_not_group_leader () = with_fixture (fun fixture ->
  let marker=Filename.concat fixture.root "must-not-start" in
  let log=Unix.openfile (Filename.concat fixture.root "refused.log")
      [Unix.O_WRONLY;Unix.O_CREAT;Unix.O_CLOEXEC] 0o600 in
  let arguments=[!owner;"--instance";"unowned";"--";"/usr/bin/env";"python3";"-c";
    "import pathlib,sys;pathlib.Path(sys.argv[1]).write_text('unexpected')";marker] in
  let pid=Unix.create_process !owner (Array.of_list arguments) Unix.stdin log log in
  fixture.children<-pid::fixture.children;Unix.close log;
  check "non-owner process refuses before spawn" true (reap fixture pid=Unix.WEXITED 1);
  check "no browser child was started" false (Sys.file_exists marker))
type stop = Term | Eof | Child_exit
let test_blocked_bootstrap stop () = with_fixture (fun fixture ->
  let claim=prepare fixture "blocked-bootstrap" in
  let script=match stop with
    | Term|Eof -> tree_script
    | Child_exit -> {|import pathlib,sys,time
root=pathlib.Path(sys.argv[1])
(root/'child-ready').write_text('ready')
while not (root/'allow-exit').exists(): time.sleep(.01)
|} in
  let pid,keepalive,_=spawn_channels ~blocked:true fixture claim script in
  wait_for "browser entered with unread bootstrap output" (fun () ->
    Sys.file_exists (Filename.concat fixture.root "child-ready")
    && (match ok (Lease.status claim) with Lease.Live process -> process.pid=pid
        | Awaiting_exec|Cleanup_pending _|Settled -> false));
  (match stop with
   | Term -> ok (Lease.request_termination claim)
   | Eof -> close fixture keepalive
   | Child_exit -> Out_channel.with_open_text (Filename.concat fixture.root "allow-exit")
       (fun output -> output_string output "exit"));
  check "bootstrap backpressure cannot prevent group termination" true
    (reap fixture pid=Unix.WSIGNALED Sys.sigkill);
  ok (Lease.retire claim);settled claim;
  check "blocked bootstrap leaves no live original group" false (Posix_spawn_detached.group_id_has_members pid))
let () =
  if Array.length Sys.argv<>3 then (prerr_endline "expected native launcher and browser process owner";exit 1);
  launcher:=Unix.realpath Sys.argv.(1);owner:=Unix.realpath Sys.argv.(2);
  Alcotest.run ~argv:[|Sys.argv.(0)|] "browser process owner" ["lifecycle",[
    Alcotest.test_case "original lease termination clears the group" `Quick test_original_lease_termination;
    Alcotest.test_case "keepalive writer crash clears the group" `Quick test_keepalive_owner_crash;
    Alcotest.test_case "normal browser exit clears descendants" `Quick test_normal_child_exit;
    Alcotest.test_case "an unrelated group is refused before spawn" `Quick test_not_group_leader;
    Alcotest.test_case "TERM settles despite blocked bootstrap output" `Quick (test_blocked_bootstrap Term);
    Alcotest.test_case "EOF settles despite blocked bootstrap output" `Quick (test_blocked_bootstrap Eof);
    Alcotest.test_case "child exit settles despite blocked bootstrap output" `Quick (test_blocked_bootstrap Child_exit)]]
