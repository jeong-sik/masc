module L = Endpoint_job_launch
module P = Endpoint_job_protocol
module R = Endpoint_job_registry
module G = Endpoint_process_gate
let require = function Ok value -> value | Error e -> Alcotest.fail e
let get value = value |> Result.map_error L.error_to_string |> require
let registry value = value |> Result.map_error R.error_to_string |> require
let check label value = Alcotest.(check bool) label true value
let id suffix = P.Id.of_string ("019a0000-0000-7000-8000-0000000000" ^ suffix) |> require
let digest value = P.Sha256.of_string Digestif.SHA256.(digest_string value |> to_hex) |> require
let route : P.route = {backend=Remote_ssh;endpoint_incarnation=id "01";boot_id=id "02"}
let owner : P.owner = {workspace_id=id "03";keeper_name="original owner"}
let rec remove path = match Unix.lstat path with
  | {Unix.st_kind=Unix.S_DIR;_} ->
      Array.iter (fun name -> remove (Filename.concat path name)) (Sys.readdir path);Unix.rmdir path
  | _ -> Unix.unlink path
  | exception Unix.Unix_error (Unix.ENOENT,_,_) -> ()
type fixture = {
  root : string; work : string; registry_path : string; input : Unix.file_descr;
  output : Unix.file_descr; output_path : string; execution : L.execution; uid : int;
}
let fixture f () =
  let root=Filename.temp_file "masc-launch-owner-" "" in Unix.unlink root;Unix.mkdir root 0o711;
  let work=Filename.concat root "work" and registry_path=Filename.concat root "registry" in
  Unix.mkdir work 0o700;Unix.mkdir registry_path 0o700;
  let account=Unix.getpwnam "nobody" in
  let uid=if account.pw_uid>0 && account.pw_uid<>Unix.geteuid () then account.pw_uid else Unix.geteuid ()+1 in
  let gid=max 0 account.pw_gid in
  if Unix.geteuid ()=0 then Unix.chown work uid gid;
  let output_path=Filename.concat root "stdout" in
  let input=Unix.openfile "/dev/null" [Unix.O_RDONLY;Unix.O_CLOEXEC] 0 in
  let output=Unix.openfile output_path [Unix.O_CREAT;Unix.O_WRONLY;Unix.O_CLOEXEC] 0o600 in
  Fun.protect ~finally:(fun () -> Unix.close input;Unix.close output;remove root) (fun () ->
    Eio_main.run (fun env ->
      Eio.Time.with_timeout_exn env#clock 20. (fun () -> Eio.Switch.run (fun sw ->
        let store=R.open_registry ~sw ~fs:env#fs ~root_path:registry_path ~route ~owner ~payload_uid:uid |> registry in
        let execution : L.execution = {executable="/bin/sh";env=["PATH=/usr/bin:/bin";"EXPLICIT=original"];
          cwd=work;payload_gid=gid} in
        f ~env ~sw ~store {root;work;registry_path;input;output;output_path;execution;uid}))))
let prepare ?(mode=Exec_ssh_protocol.Effect) ?(domain=P.Workspace_process)
    ?(network_policy_sha256=None) store fixture suffix script =
  let spec=P.spec ~domain ~argv:["/bin/sh";"-c";script] ~env:["EXPLICIT","original"]
    ~cwd:fixture.work ~remote_root:fixture.work ~stdin:"" ~mode
    ~network_policy_sha256 |> require in
  let binding=P.binding ~route ~owner ~operation_id:(id suffix)
    ~invocation_sha256:(digest suffix) ~spec_sha256:(P.spec_sha256 spec) |> require in
  let original=R.admit store ~new_admission_id:(id "04") ~binding ~spec |> registry in
  let permit=R.commit_launch original ~confirmed_admission_id:(id "04") ~launch_id:(id (if suffix="05" then "06" else "08")) |> registry in
  binding,permit
let completed = function
  | R.Not_performed e -> Alcotest.fail (R.error_to_string e)
  | R.Performed {value;release_error=None} -> get value
  | R.Performed {release_error=Some e;_} -> Alcotest.fail (File_lock_eio.durable_lock_error_to_string e)
let start ?(after_rendezvous=fun () -> ()) ?input ?output ~sw ~env fixture permit =
  let stdin=match input with None -> fixture.input | Some fd -> fd in
  let stdout=match output with None -> fixture.output | Some fd -> fd in
  L.For_testing.launch_effect_workspace ~after_rendezvous ~sw ~fs:env#fs ~cgroup_parent_path:"/sys/fs/cgroup"
    ~execution:fixture.execution ~stdin ~stdout ~stderr:fixture.output permit |> completed
let leaf fixture binding name = Filename.concat
  (Filename.concat fixture.registry_path (P.Id.to_string binding.P.operation_id ^ ".job")) name
let read path = In_channel.with_open_bin path In_channel.input_all
let exit expected (value : G.exit_observation) =
  check "original physical status" (value.status=G.Exited expected)

let durable_before_activation = fixture (fun ~env ~sw:_ ~store fixture -> Eio.Switch.run (fun sw ->
  let binding,permit=prepare store fixture "05" "test \"$EXPLICIT\" = original; printf payload; : > activated; exit 7" in
  let marker=Filename.concat fixture.work "activated" in
  let observed=ref false in
  let child=start ~sw ~env fixture permit ~after_rendezvous:(fun () ->
    observed:=true;
    check "actual child remains paused before durable activation intent" (not (Sys.file_exists marker));
    check "activation intent has not been fabricated early" (not (Sys.file_exists (leaf fixture binding L.activation_leaf)));
    let json=Yojson.Safe.from_string (read (leaf fixture binding L.rendezvous_leaf)) in
    let open Yojson.Safe.Util in
    Alcotest.(check string) "original admission is durable" (P.Id.to_string (id "04"))
      (json |> member "admission_id" |> to_string);
    Alcotest.(check string) "actual payload UID is recorded before activation" (string_of_int fixture.uid)
      (json |> member "actual_execution" |> member "payload_uid" |> to_string)) in
  check "real rendezvous boundary observed" !observed;
  check "activation request is retained as a request" (L.activation child=L.Requested);
  exit 7 (L.await_quiescent child |> get);
  check "payload effect occurred only after activation" (Sys.file_exists marker);
  Alcotest.(check string) "actual payload output" "payload" (read fixture.output_path);
  let json=Yojson.Safe.from_string (read (leaf fixture binding L.activation_leaf)) in
  Alcotest.(check string) "actual activation intent remains durable" "activate"
    Yojson.Safe.Util.(json |> member "decision" |> to_string)))

let publication_failure_retains_paused_owner = fixture (fun ~env ~sw:_ ~store fixture -> Eio.Switch.run (fun sw ->
  let binding,permit=prepare store fixture "05" ": > activated" in
  (* A conflicting durable target must never be overwritten or grant activation. *)
  let path=leaf fixture binding L.activation_leaf in
  Out_channel.with_open_bin path (fun oc -> output_string oc "conflicting original evidence");Unix.chmod path 0o400;
  let child=start ~sw ~env fixture permit in
  (match L.activation child with
   | L.Held (L.Publication_failed _) -> ()
   | L.Requested | L.Held _ -> Alcotest.fail "uncertain publication did not hold the original paused owner");
  check "paused owner never ran payload" (not (Sys.file_exists (Filename.concat fixture.work "activated")));
  Alcotest.(check string) "conflicting evidence preserved" "conflicting original evidence" (read path);
  let observed=ref false in
  ignore (L.For_testing.cancel ~after_intent:(fun current ->
    observed:=true;
    check "original cancel intent exists before original kernel tree kill"
      (R.cancellation_state current=R.Cancellation_requested)) child |> get);
  check "real durable cancel boundary observed" !observed;
  let physical=L.await_quiescent child |> get in
  check "bootstrap kill remains a raw physical observation" (physical.status=G.Signaled 9);
  check "failed startup cannot activate during cancellation" (not (Sys.file_exists (Filename.concat fixture.work "activated")));
  let _,next=prepare store fixture "07" "exit 3" in
  exit 3 (Eio.Switch.run (fun next_sw -> start ~sw:next_sw ~env fixture next |> L.await_quiescent |> get))))

let busy_startup_leaves_other_job_executable = fixture (fun ~env ~sw:_ ~store fixture -> Eio.Switch.run (fun sw ->
  let binding,permit=prepare store fixture "05" "exit 4" in
  let entered,signal=Eio.Promise.create () and resume,release=Eio.Promise.create () in
  let child,finished=Eio.Promise.create () in
  let unblock ()=if Eio.Promise.peek resume=None then Eio.Promise.resolve release () in
  Fun.protect ~finally:unblock (fun () ->
    Eio.Fiber.fork ~sw (fun () -> Eio.Promise.resolve finished
      (start ~sw ~env fixture permit ~after_rendezvous:(fun () -> Eio.Promise.resolve signal ();Eio.Promise.await resume)));
    Eio.Promise.await entered;
    check "own startup is nonwaiting busy" (R.load store ~binding=Error R.Busy);
    let _,next=prepare store fixture "07" "exit 5" in
    exit 5 (Eio.Switch.run (fun next_sw -> start ~sw:next_sw ~env fixture next |> L.await_quiescent |> get));
    check "second job finished while the first actual gate is paused" (Eio.Promise.peek child=None);
    unblock ();
    exit 4 (Eio.Promise.await child |> L.await_quiescent |> get))))

let wait_and_cancel_require_original_authority = fixture (fun ~env ~sw:_ ~store fixture ->
  let input,writer=Unix.pipe ~cloexec:true () and reader,output=Unix.pipe ~cloexec:true () in
  Fun.protect ~finally:(fun () -> List.iter Unix.close [input;writer;reader;output]) (fun () ->
    Eio.Switch.run (fun sw ->
      let script="printf ready; exec /bin/cat" in
      let binding,permit=prepare store fixture "05" script in
      let child=start ~sw ~env fixture permit ~input ~output in
      Eio_unix.await_readable reader;
      let bytes=Bytes.create 5 in
      let n=Eio_unix.run_in_systhread (fun () -> Unix.read reader bytes 0 5) in
      Alcotest.(check string) "original payload actually entered and waits on its own input" "ready" (Bytes.sub_string bytes 0 n);
      let other_root=Filename.concat fixture.root "other-registry" in Unix.mkdir other_root 0o700;
      let other=R.open_registry ~sw ~fs:env#fs ~root_path:other_root ~route ~owner ~payload_uid:fixture.uid |> registry in
      let other_binding,_other_permit=prepare other fixture "05" script in
      let actual=R.load store ~binding |> registry in
      let alternate=R.load other ~binding:other_binding |> registry in
      check "another valid protected registry has every matching public coordinate"
        (R.binding alternate=R.binding actual && R.specification alternate=R.specification actual
         && R.admission_id alternate=R.admission_id actual && R.payload_uid alternate=R.payload_uid actual
         && R.launch_state alternate=R.launch_state actual && R.revision alternate=R.revision actual);
      let other_claim=Filename.concat other_root (P.Id.to_string binding.operation_id ^ ".claim.json") in
      let alternate_bytes=read other_claim in
      let actual_claim=Filename.concat fixture.registry_path (P.Id.to_string binding.operation_id ^ ".claim.json") in
      Unix.rename actual_claim (actual_claim ^ ".unavailable");
      Fun.protect ~finally:(fun () -> Unix.rename (actual_claim ^ ".unavailable") actual_claim) (fun () ->
        match L.cancel child with
        | Error (L.Registry_error _) -> ()
        | Error _ | Ok _ -> Alcotest.fail "a matching alternate replaced unavailable original cancellation authority");
      let entered,signal=Eio.Promise.create () in
      Eio.Fiber.first
        (fun () -> Eio.Promise.resolve signal ();ignore (L.await_quiescent child |> get);
          Alcotest.fail "live original settled after untrusted cancel or waiter cancellation")
        (fun () -> Eio.Promise.await entered);
      let _,next=prepare store fixture "07" "exit 6" in
      exit 6 (Eio.Switch.run (fun next_sw -> start ~sw:next_sw ~env fixture next |> L.await_quiescent |> get));
      let input_bytes="original-still-alive\n" in
      let sent=Eio_unix.run_in_systhread (fun () -> Unix.write_substring writer input_bytes 0 (String.length input_bytes)) in
      Alcotest.(check int) "actual original input sent after both cancelled waits and other job teardown"
        (String.length input_bytes) sent;
      Eio_unix.await_readable reader;
      let echoed=Bytes.create (String.length input_bytes) in
      let n=Eio_unix.run_in_systhread (fun () -> Unix.read reader echoed 0 (Bytes.length echoed)) in
      Alcotest.(check string) "same original still performs work after unavailable authority and cancelled wait"
        input_bytes (Bytes.sub_string echoed 0 n);
      ignore (L.For_testing.cancel ~after_intent:(fun committed ->
        let actual=R.load store ~binding |> registry in
        check "actual origin cancellation is durable before the original tree kill"
          (R.cancellation_state committed=R.Cancellation_requested
           && R.cancellation_state actual=R.Cancellation_requested);
        let alternate_now=R.load other ~binding:other_binding |> registry in
        check "matching alternate registry never acquires the cancellation"
          (R.cancellation_state alternate_now=R.No_cancellation
           && R.revision alternate_now=R.revision alternate
           && R.launch_state alternate_now=R.launch_state alternate)) child |> get);
      let current=R.load store ~binding |> registry in
      check "known original cancellation is durably retained" (R.cancellation_state current=R.Cancellation_requested);
      Alcotest.(check string) "cancellation never rewrites the alternate original claim" alternate_bytes (read other_claim);
      let physical=L.await_quiescent child |> get in
      check "cancel requests settle the original main and tree" (physical.status=G.Signaled 9))))

let unavailable_boundaries () =
  let isolated : P.isolated_preparation = {preparation_id=id "09";image_sha256=digest "image";
    input_manifest_sha256=digest "inputs"} in
  List.iter (fun (mode,domain,network_policy_sha256) -> fixture (fun ~env ~sw ~store fixture ->
    let binding,permit=prepare ~mode ~domain ~network_policy_sha256 store fixture "05" ": > activated" in
    (match L.launch_effect_workspace ~sw ~fs:env#fs ~cgroup_parent_path:"/sys/fs/cgroup"
        ~execution:fixture.execution ~stdin:fixture.input ~stdout:fixture.output ~stderr:fixture.output permit with
     | R.Performed {value=Error L.Scope_unavailable;release_error=None} -> ()
     | R.Not_performed _ | R.Performed _ -> Alcotest.fail "unimplemented boundary reached a kernel launch");
    check "no original rendezvous claims an unavailable boundary"
      (not (Sys.file_exists (leaf fixture binding L.rendezvous_leaf)));
    check "no fallback payload was run" (not (Sys.file_exists (Filename.concat fixture.work "activated")))) ())
    [Exec_ssh_protocol.Observe,P.Workspace_process,None;
     Guest_local,P.Workspace_process,None;
     Effect,P.Workspace_process,Some (digest "network policy");
     Effect,P.Isolated_job isolated,None]

let refusal = fixture (fun ~env ~sw ~store fixture ->
  let _,permit=prepare store fixture "05" ": > activated" in
  match L.launch_effect_workspace ~sw ~fs:env#fs ~cgroup_parent_path:"/sys/fs/cgroup"
      ~execution:fixture.execution ~stdin:fixture.input ~stdout:fixture.output ~stderr:fixture.output permit with
  | R.Performed {value=Error (L.Group_error G.Group.Unsupported);release_error=None}
  | R.Performed {value=Error (L.Group_error (G.Group.Refused G.Group.Controller_not_root));release_error=None} -> ()
  | R.Not_performed _ | R.Performed _ -> Alcotest.fail "unsupported platform or controller must refuse")
let () =
  if G.For_testing.linux_build && Unix.geteuid ()<>0 && Sys.getenv_opt "GITHUB_ACTIONS"=Some "true" then (
    let executable=Unix.realpath Sys.executable_name in
    Unix.execvp "sudo" (Array.concat [[|"sudo";"-n";"--";executable|];Array.sub Sys.argv 1 (Array.length Sys.argv-1)]));
  let cases=if not G.For_testing.linux_build || Unix.geteuid ()<>0 then
      ["platform/controller refusal (kernel integration not run)",refusal;
       "unavailable boundaries never fall back to workspace execution",unavailable_boundaries]
    else ["durable original rendezvous before activation",durable_before_activation;
      "publication failure preserves paused owner without replay",publication_failure_retains_paused_owner;
      "busy original startup leaves another actual job executable",busy_startup_leaves_other_job_executable;
      "wait cancellation and original authority before tree kill",wait_and_cancel_require_original_authority;
      "unavailable boundaries never fall back to workspace execution",unavailable_boundaries] in
  Alcotest.run "Endpoint job launch" ["original supervisor",List.map
    (fun (name,test) -> Alcotest.test_case name `Quick test) cases]
