module L = Endpoint_job_launch
module P = Endpoint_job_protocol
module R = Endpoint_job_registry
module G = Endpoint_process_gate
module O = Endpoint_job_output
module S = Endpoint_job_supervisor
module D = Endpoint_job_result
module C = Endpoint_job_lifetime
module Recovery_test = Fs_compat_test_support.Publication_recovery_for_testing
let require = function Ok value -> value | Error e -> Alcotest.fail e
let get value = value |> Result.map_error L.error_to_string |> require
let registry value = value |> Result.map_error R.error_to_string |> require
let check label value = Alcotest.(check bool) label true value
let id suffix = P.Id.of_string ("019a0000-0000-7000-8000-0000000000" ^ suffix) |> require
let digest value = P.Sha256.of_string Agent_core_sha256.(digest_string value |> to_hex) |> require
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
let prepare ?(stdin="") ?(mode=Exec_ssh_protocol.Effect) ?(domain=P.Workspace_process)
    ?(network_policy_sha256=None) store fixture suffix script =
  let spec=P.spec ~domain ~argv:["/bin/sh";"-c";script] ~env:["EXPLICIT","original"]
    ~cwd:fixture.work ~remote_root:fixture.work ~stdin ~mode
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
let start ?(after_rendezvous=fun () -> ()) ?input ?output ?error_output ~sw ~env fixture permit =
  let stdin=match input with None -> fixture.input | Some fd -> fd in
  let stdout=match output with None -> fixture.output | Some fd -> fd in
  let stderr=match error_output with None -> fixture.output | Some fd -> fd in
  (* All supplied ends here are dedicated child stdio. Opposite controller
     Eio ends retain their flags on the POSIX backend. *)
  List.iter Unix.clear_nonblock [stdin;stdout;stderr];
  L.For_testing.launch_effect_workspace ~after_rendezvous ~sw ~fs:env#fs ~cgroup_parent_path:"/sys/fs/cgroup"
    ~execution:fixture.execution ~stdin ~stdout ~stderr permit |> completed
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

let output value = value |> Result.map_error O.error_to_string |> require
let pipe_launch ?input ?after_chunk ?after_prefix ~sw ~env fixture permit =
  let source,writer=Eio_unix.pipe sw in
  let owner=Eio_unix.Fd.use_exn "original stdout" (Eio_unix.Resource.fd writer)
    (fun fd -> start ?input ~output:fd ~sw ~env fixture permit) in
  Eio.Flow.close writer;
  let capture=match after_chunk,after_prefix with
    | None,None -> O.start
    | (Some _,(Some _ | None)) | None,Some _ ->
      let after_chunk=match after_chunk with Some hook -> hook | None -> (fun () -> ()) in
      let after_prefix=match after_prefix with Some hook -> hook | None -> (fun () -> ()) in
      O.For_testing.start ~after_chunk ~after_prefix ~on_metadata:(fun _ _ -> ()) in
  let captured=capture ~sw ~fs:env#fs ~owner ~stream:P.Stdout ~source |> output in
  owner,captured
let all_output captured (seal : O.seal) =
  let buffer=Buffer.create 128 in
  let rec read offset =
    if offset=seal.byte_length then Buffer.contents buffer else (
      let part=O.read captured ~offset ~max_bytes:max_int |> output in
      check "sealed bytes are always retrievable in nonempty transfer chunks" (String.length part.data>0);
      Buffer.add_string buffer part.data;
      read (Int64.add offset (Int64.of_int (String.length part.data)))) in
  read 0L

let complete_binary_output_is_durably_sealed = fixture (fun ~env ~sw:_ ~store fixture -> Eio.Switch.run (fun sw ->
  let stdout,stdout_writer=Eio_unix.pipe sw and stderr,stderr_writer=Eio_unix.pipe sw in
  let script="/usr/bin/python3 -c 'import sys;sys.stdout.buffer.write(bytes(range(256))*1025);sys.stderr.buffer.write(bytes([101,0,255]))'" in
  let binding,permit=prepare store fixture "05" script in
  let owner=Eio_unix.Fd.use_exn "original stdout" (Eio_unix.Resource.fd stdout_writer) (fun out ->
    Eio_unix.Fd.use_exn "original stderr" (Eio_unix.Resource.fd stderr_writer) (fun err ->
      start ~output:out ~error_output:err ~sw ~env fixture permit)) in
  Eio.Flow.close stdout_writer;Eio.Flow.close stderr_writer;
  let captured=O.start ~sw ~fs:env#fs ~owner ~stream:P.Stdout ~source:stdout |> output in
  let errors=O.start ~sw ~fs:env#fs ~owner ~stream:P.Stderr ~source:stderr |> output in
  let sealed=O.await_sealed captured |> output and error_seal=O.await_sealed errors |> output in
  exit 0 (L.await_quiescent owner |> get);
  let expected=String.init (256*1025) (fun i -> Char.chr (i mod 256)) in
  Alcotest.(check int64) "entire multi-buffer output retained" (Int64.of_int (String.length expected)) sealed.byte_length;
  check "complete stream digest" (sealed.sha256=digest expected);
  Alcotest.(check string) "all binary bytes survive bounded range reads" expected (all_output captured sealed);
  Alcotest.(check string) "stderr is independently sealed with binary bytes" "e\000\255" (all_output errors error_seal);
  let manifest=Yojson.Safe.from_string (read (leaf fixture binding "stdout.seal.json")) in
  Alcotest.(check string) "digest manifest is actually on disk" (P.Sha256.to_string sealed.sha256)
    Yojson.Safe.Util.(manifest |> member "sha256" |> to_string);
  (match O.start ~sw ~fs:env#fs ~owner ~stream:P.Stdout ~source:(Eio.Flow.string_source "replacement") with
   | Error (O.Publication_failed _) -> ()
   | Error _ | Ok _ -> Alcotest.fail "existing spool was adopted or overwritten");
  Alcotest.(check string) "duplicate capture preserves actual complete original" expected
    (read (leaf fixture binding "stdout.bin"))))

let output_metadata_waits_only_for_its_original_owner = fixture (fun ~env ~sw:_ ~store fixture ->
  Eio.Switch.run (fun sw ->
    let stdout,out=Eio_unix.pipe sw and stderr,err=Eio_unix.pipe sw in
    let _,permit=prepare store fixture "05" "printf stdout; printf stderr >&2" in
    let owner=Eio_unix.Fd.use_exn "original stdout" (Eio_unix.Resource.fd out) (fun out ->
      Eio_unix.Fd.use_exn "original stderr" (Eio_unix.Resource.fd err) (fun err ->
        start ~output:out ~error_output:err ~sw ~env fixture permit)) in
    Eio.Flow.close out;Eio.Flow.close err;
    let entered,signal=Eio.Promise.create () and resume,release=Eio.Promise.create () in
    let unblock ()=if Eio.Promise.peek resume=None then Eio.Promise.resolve release () in
    Fun.protect ~finally:unblock (fun () ->
      let captured=O.For_testing.start ~after_prefix:(fun () -> ()) ~sw ~fs:env#fs ~owner ~stream:P.Stdout ~source:stdout
        ~after_chunk:(fun () -> ()) ~on_metadata:(fun operation stage ->
          match operation,stage with
          | O.For_testing.Publish "stdout.seal.json",O.For_testing.Acquired ->
            Eio.Promise.resolve signal ();Eio.Promise.await resume
          | Open_recovery,Waiting | Open_recovery,Acquired | Publish _,Waiting | Publish _,Acquired -> ()) |> output in
      Eio.Promise.await entered;
      let exception Cancel_waiter in
      let waiting,arrived=Eio.Promise.create () in
      (match Eio.Switch.run (fun waiter_sw ->
        Eio.Fiber.fork ~sw:waiter_sw (fun () ->
          ignore (O.For_testing.start ~after_prefix:(fun () -> ()) ~sw:waiter_sw ~fs:env#fs ~owner ~stream:P.Stderr ~source:stderr
            ~after_chunk:(fun () -> ()) ~on_metadata:(fun operation stage ->
              match operation,stage with
              | O.For_testing.Open_recovery,O.For_testing.Waiting -> Eio.Promise.resolve arrived ()
              | Open_recovery,Acquired | Publish _,Waiting | Publish _,Acquired -> ()) |> output));
        Eio.Promise.await waiting;
        Eio.Switch.fail waiter_sw Cancel_waiter) with
       | () -> Alcotest.fail "queued metadata cancellation did not propagate"
       | exception Cancel_waiter -> ());
      let waiting,arrived=Eio.Promise.create () and errors,finished=Eio.Promise.create () in
      let acquired=ref false in
      Eio.Fiber.fork ~sw (fun () ->
        let errors=O.For_testing.start ~after_prefix:(fun () -> ()) ~sw ~fs:env#fs ~owner ~stream:P.Stderr ~source:stderr
          ~after_chunk:(fun () -> ()) ~on_metadata:(fun operation stage ->
            match operation,stage with
            | O.For_testing.Open_recovery,O.For_testing.Waiting -> Eio.Promise.resolve arrived ()
            | Open_recovery,Acquired -> acquired:=true
            | Publish _,Waiting | Publish _,Acquired -> ()) |> output in
        Eio.Promise.resolve finished errors);
      Eio.Promise.await waiting;
      check "same original stderr reached metadata acquisition and waits for held stdout seal" (not !acquired);
      check "queued stderr has not returned a false successful capture" (Eio.Promise.peek errors=None);
      let _,next=prepare store fixture "07" "printf independent" in
      let next_owner,next_output=pipe_launch ~sw ~env fixture next in
      let next_seal=O.await_sealed next_output |> output in
      exit 0 (L.await_quiescent next_owner |> get);
      Alcotest.(check string) "another actual owner seals output while the first metadata lock is held"
        "independent" (all_output next_output next_seal);
      check "another owner's completion never releases the original owner's metadata lock" (not !acquired);
      unblock ();
      let errors=Eio.Promise.await errors in
      let sealed=O.await_sealed captured |> output and error_seal=O.await_sealed errors |> output in
      exit 0 (L.await_quiescent owner |> get);
      check "queued stderr progressed after exact original owner released its publication" !acquired;
      Alcotest.(check string) "stdout retained through controlled metadata overlap" "stdout" (all_output captured sealed);
      Alcotest.(check string) "stderr retained after cancellation of a previous queued metadata attempt"
        "stderr" (all_output errors error_seal))))

let output_observer_cancel_preserves_capture_and_child = fixture (fun ~env ~sw:_ ~store fixture ->
  let input,writer=Unix.pipe ~cloexec:true () in let writer_open=ref true in
  Fun.protect ~finally:(fun () -> Unix.close input;if !writer_open then Unix.close writer) (fun () ->
    Eio.Switch.run (fun sw ->
      let _,permit=prepare store fixture "05" "printf prefix; exec /bin/cat" in
      let owner,captured=pipe_launch ~input ~sw ~env fixture permit in
      let entered,signal=Eio.Promise.create () in
      Eio.Fiber.first
        (fun () -> Eio.Promise.resolve signal ();ignore (O.await_sealed captured |> output);
          Alcotest.fail "source with a live child writer was prematurely sealed")
        (fun () -> Eio.Promise.await entered);
      (match O.extent captured |> output with
       | P.Growing _ -> () | P.Sealed _ -> Alcotest.fail "current prefix was misclassified as source EOF");
      let _,next=prepare store fixture "07" "exit 8" in
      exit 8 (Eio.Switch.run (fun next_sw -> start ~sw:next_sw ~env fixture next |> L.await_quiescent |> get));
      let bytes="after-observer-cancel\000\255" in
      let sent=Eio_unix.run_in_systhread (fun () -> Unix.write_substring writer bytes 0 (String.length bytes)) in
      Alcotest.(check int) "same original input still works" (String.length bytes) sent;
      Unix.close writer;writer_open:=false;
      let seal=O.await_sealed captured |> output in
      exit 0 (L.await_quiescent owner |> get);
      Alcotest.(check string) "cancelled observer lost neither original capture nor later bytes"
        ("prefix" ^ bytes) (all_output captured seal))))

(* The real child writes the initial prefix and then waits for its original
   stdin. The capture hook pauses after pwrite, before publishing that extent. *)
let with_growing_capture ~after_next_chunk f = fixture (fun ~env ~sw:_ ~store fixture ->
  let input,writer=Unix.pipe ~cloexec:true () in
  let writer_open=ref true in
  Fun.protect ~finally:(fun () -> Unix.close input;if !writer_open then Unix.close writer) (fun () ->
    Eio.Switch.run (fun sw ->
      let entered,signal=Eio.Promise.create () and resume,release=Eio.Promise.create () in
      let initial=ref true in
      let published,signal_published=Eio.Promise.create () in
      let published_once=Atomic.make false in
      let unblock ()=if Eio.Promise.peek resume=None then Eio.Promise.resolve release () in
      let binding,permit=prepare store fixture "05" "printf prefix; exec /bin/cat" in
      let owner,captured=pipe_launch ~input ~sw ~env fixture permit
        ~after_prefix:(fun () -> if Atomic.compare_and_set published_once false true then Eio.Promise.resolve signal_published ())
        ~after_chunk:(fun () ->
        if !initial then (initial:=false;Eio.Promise.resolve signal ();Eio.Promise.await resume)
        else after_next_chunk ()) in
      Fun.protect ~finally:unblock (fun () ->
        Eio.Promise.await entered;
        Alcotest.(check string) "real pwrite precedes the published prefix" "prefix"
          (read (leaf fixture binding "stdout.bin"));
        unblock ();
        Eio.Promise.await published;
        check "captured original is still growing, without EOF or a seal"
          (O.extent captured=Ok (P.Growing 6L));
        let close_input ()=if !writer_open then (Unix.close writer;writer_open:=false) in
        f ~env ~sw ~store fixture ~binding ~owner ~captured ~writer ~close_input))))

type live_read_change = Missing_claim | Rebound_claim | Replaced_spool

let is_original_registry_refusal : O.error -> bool = function
  | O.Registry_error _ -> true
  | Invalid_storage | Storage_unavailable | Source_protocol_error | Offset_unavailable
  | Invalid_range | Interrupted | Capture_failed | Codec_error _ | Publication_failed _
  | Recovery_failed _ -> false

let growing_range_read_revalidates_original when_changed change =
  with_growing_capture ~after_next_chunk:(fun () -> ())
    (fun ~env ~sw ~store fixture ~binding ~owner ~captured ~writer:_ ~close_input ->
      let claim=Filename.concat fixture.registry_path (P.Id.to_string binding.P.operation_id ^ ".claim.json") in
      let spool=leaf fixture binding "stdout.bin" in
      let saved_claim=claim ^ ".evidence" and saved_spool=spool ^ ".evidence" in
      let claim_bytes=read claim in
      let changed=ref false in
      let mutate () =
        changed:=true;
        match change with
        | Missing_claim -> Unix.rename claim saved_claim
        | Rebound_claim ->
          let fields=match Yojson.Safe.from_string claim_bytes with
            | `Assoc fields -> fields
            | _ -> Alcotest.fail "original claim object missing" in
          let json=`Assoc (List.map (fun (name,value) ->
            name,(if name="launch_id" then `String (P.Id.to_string (id "09")) else value)) fields) in
          Out_channel.with_open_bin claim (fun channel -> output_string channel (Yojson.Safe.to_string json));
          let rebound=R.load store ~binding |> registry in
          check "replacement claim remains valid to a fresh binding-only load" (R.launch_state rebound=R.Requested (id "09"))
        | Replaced_spool ->
          Unix.rename spool saved_spool;
          Out_channel.with_open_bin spool (fun channel -> output_string channel "forged");Unix.chmod spool 0o600;
          check "detached original still has one link" ((Unix.lstat saved_spool).st_nlink=1)
      in
      let restore () = if !changed then (
        changed:=false;
        match change with
        | Missing_claim -> Unix.rename saved_claim claim
        | Rebound_claim -> Out_channel.with_open_bin claim (fun channel -> output_string channel claim_bytes)
        | Replaced_spool -> Unix.unlink spool;Unix.rename saved_spool spool) in
      Fun.protect ~finally:restore (fun () ->
        let chunk=match when_changed with
          | `Before -> mutate ();O.read captured ~offset:0L ~max_bytes:6
          | `After -> O.For_testing.read captured ~offset:0L ~max_bytes:6 ~after_read:mutate in
        (match chunk with
         | Error error ->
           let refused=match change with
             | Missing_claim | Rebound_claim -> is_original_registry_refusal error
             | Replaced_spool -> error=O.Invalid_storage in
           check ("read returns its typed source/attachment refusal: " ^ O.error_to_string error) refused
         | Ok _ -> Alcotest.fail "captured read returned bytes through changed original authority");
        check "refused read neither seals nor poisons the growing capture" (O.extent captured=Ok (P.Growing 6L));
        Alcotest.(check string) "read refusal preserves original held-file evidence" "prefix"
          (read (if change=Replaced_spool then saved_spool else spool));
        let _,next=prepare store fixture "07" "exit 9" in
        exit 9 (Eio.Switch.run (fun next_sw -> start ~sw:next_sw ~env fixture next |> L.await_quiescent |> get));
        restore ());
      let recovered=O.read captured ~offset:0L ~max_bytes:6 |> output in
      Alcotest.(check string) "restored exact source still reads the original prefix" "prefix" recovered.data;
      check "captured prefix never grants full reopened seal authority" (O.revalidate_sealed captured=Error O.Invalid_storage);
      close_input ();
      let seal=O.await_sealed captured |> output in
      exit 0 (L.await_quiescent owner |> get);
      check "even a captured cached seal does not grant full reopened validation" (O.revalidate_sealed captured=Error O.Invalid_storage);
      Alcotest.(check string) "restored original seals without recapture" "prefix" (all_output captured seal))

type captured_read_observer = Append_ahead_of_extent | Cancel_read_observer | Capture_fails_during_read

let growing_range_read_observer_keeps_original_capture mode () =
  let appended,signal_append=Eio.Promise.create () and resume,release=Eio.Promise.create () in
  let unblock ()=if Eio.Promise.peek resume=None then Eio.Promise.resolve release () in
  let appended_once=Atomic.make false in
  with_growing_capture ~after_next_chunk:(fun () ->
    if Atomic.compare_and_set appended_once false true then (
      Eio.Promise.resolve signal_append ();Eio.Promise.await resume))
    (fun ~env:_ ~sw:_ ~store:_ fixture ~binding ~owner ~captured ~writer ~close_input ->
      Fun.protect ~finally:unblock (fun () ->
        (match mode with
         | Append_ahead_of_extent -> ()
         | Cancel_read_observer ->
           let entered,signal=Eio.Promise.create () in
           let cancelled=ref false in
           Eio.Fiber.first
             (fun () ->
               match O.For_testing.read captured ~offset:0L ~max_bytes:6 ~after_read:(fun () ->
                 Eio.Promise.resolve signal ();Eio.Fiber.await_cancel ()) with
               | Ok _ | Error _ -> Alcotest.fail "cancelled read observer unexpectedly returned"
               | exception (Eio.Cancel.Cancelled _ as error) -> cancelled:=true;raise error)
             (fun () -> Eio.Promise.await entered);
           check "read observer receives cancellation" !cancelled
         | Capture_fails_during_read ->
           let manifest=leaf fixture binding "stdout.seal.json" in
           Out_channel.with_open_bin manifest (fun channel -> output_string channel "conflicting seal");
           Unix.chmod manifest 0o400;
           let result=O.For_testing.read captured ~offset:0L ~max_bytes:6 ~after_read:(fun () ->
             close_input ();
             check "real EOF publication failure remains observable" (Result.is_error (O.await_sealed captured))) in
           check "post-read unavailable capture never returns earlier bytes" (Result.is_error result));
        match mode with
        | Capture_fails_during_read -> exit 0 (L.await_quiescent owner |> get)
        | Append_ahead_of_extent | Cancel_read_observer ->
          let bytes="-appended" in
          let sent=Eio_unix.run_in_systhread (fun () -> Unix.write_substring writer bytes 0 (String.length bytes)) in
          check "original child accepts subsequent input" (sent=String.length bytes);
          Eio.Promise.await appended;
          let prefix=O.read captured ~offset:0L ~max_bytes:max_int |> output in
          check "write ahead of extent is accepted as the previous growing prefix"
            (prefix.extent=P.Growing 6L && prefix.data="prefix");
          Alcotest.(check string) "actual spool contains the unadvertised append" ("prefix" ^ bytes)
            (read (leaf fixture binding "stdout.bin"));
          unblock ();
          close_input ();
          let seal=O.await_sealed captured |> output in
          exit 0 (L.await_quiescent owner |> get);
          Alcotest.(check string) "read observer does not cancel or replay the original capture"
            ("prefix" ^ bytes) (all_output captured seal))) ()

let failed_seal_is_not_completion_and_does_not_block_other_job = fixture (fun ~env ~sw:_ ~store fixture ->
  Eio.Switch.run (fun sw ->
    let binding,permit=prepare store fixture "05" "printf original" in
    let path=leaf fixture binding "stdout.seal.json" in
    Out_channel.with_open_bin path (fun oc -> output_string oc "preserved conflicting receipt");Unix.chmod path 0o400;
    let owner,captured=pipe_launch ~sw ~env fixture permit in
    (match O.await_sealed captured with
     | Error (O.Publication_failed _) -> ()
     | Error _ | Ok _ -> Alcotest.fail "failed durable seal became output completion");
    exit 0 (L.await_quiescent owner |> get);
    check "a physical process exit does not hide unavailable output" (Result.is_error (O.extent captured));
    Alcotest.(check string) "actual incomplete output evidence retained" "original" (read (leaf fixture binding "stdout.bin"));
    Alcotest.(check string) "existing receipt never replaced" "preserved conflicting receipt" (read path);
    let _,next=prepare store fixture "07" "exit 9" in
    exit 9 (Eio.Switch.run (fun next_sw -> start ~sw:next_sw ~env fixture next |> L.await_quiescent |> get))))

let output_attachment_change_never_seals change = fixture (fun ~env ~sw:_ ~store fixture ->
  Eio.Switch.run (fun sw ->
    let binding,permit=prepare store fixture "05" "printf original" in
    let spool=leaf fixture binding "stdout.bin" in
    let moved=Filename.concat fixture.root "moved-original.bin" in
    let linked=Filename.concat fixture.root "linked-original.bin" in
    let changed=ref false in
    let owner,captured=pipe_launch ~sw ~env fixture permit ~after_chunk:(fun () ->
      if not !changed then (
        changed:=true;
        match change with
        | `Move_and_replace ->
          Unix.rename spool moved;
          Out_channel.with_open_bin spool (fun oc -> output_string oc "replacement");Unix.chmod spool 0o600;
          Alcotest.(check int) "moved original retains one link, so FD-only validation cannot detect detachment"
            1 (Unix.stat moved).st_nlink
        | `Symlink_to_original -> Unix.rename spool moved;Unix.symlink moved spool
        | `Extra_link -> Unix.link spool linked
        | `Changed_file_mode -> Unix.chmod spool 0o640
        | `Changed_storage_mode -> Unix.chmod (Filename.dirname spool) 0o750)) in
    (match O.await_sealed captured with
     | Error O.Invalid_storage -> ()
     | Error _ | Ok _ -> Alcotest.fail "changed original output attachment acquired a durable seal");
    check "filesystem mutation ran after a real captured write" !changed;
    exit 0 (L.await_quiescent owner |> get);
    check "changed attachment stays unavailable to extent consumers" (O.extent captured=Error O.Invalid_storage);
    check "no seal manifest was published beside unverified output" (not (Sys.file_exists (leaf fixture binding "stdout.seal.json")));
    let original=match change with `Move_and_replace | `Symlink_to_original -> moved
      | `Extra_link | `Changed_file_mode | `Changed_storage_mode -> spool in
    Alcotest.(check string) "all original bytes remain as failure evidence" "original" (read original);
    (match change with
     | `Move_and_replace -> Alcotest.(check string) "replacement bytes are never overwritten" "replacement" (read spool)
     | `Symlink_to_original -> Alcotest.(check string) "symlink evidence is never replaced" moved (Unix.readlink spool)
     | `Extra_link -> Alcotest.(check string) "extra link evidence remains" "original" (read linked)
     | `Changed_file_mode | `Changed_storage_mode -> ());
    let _,next=prepare store fixture "07" "exit 9" in
    exit 9 (Eio.Switch.run (fun next_sw -> start ~sw:next_sw ~env fixture next |> L.await_quiescent |> get))))

let output_owner_teardown_settles_external_observers = fixture (fun ~env ~sw:_ ~store fixture ->
  let input,writer=Unix.pipe ~cloexec:true () in
  Fun.protect ~finally:(fun () -> Unix.close input;Unix.close writer) (fun () ->
    let captured=Eio.Switch.run (fun sw ->
      let _,permit=prepare store fixture "05" "exec /bin/cat" in
      let _,captured=pipe_launch ~input ~sw ~env fixture permit in captured) in
    (match O.await_sealed captured with
     | Error O.Interrupted -> ()
     | Error _ | Ok _ -> Alcotest.fail "owner teardown left a waiting observer or fabricated a seal");
    check "interrupted capture remains unavailable" (O.extent captured=Error O.Interrupted)))

let output_owner_teardown_finishes_entered_metadata = fixture (fun ~env ~sw ~store fixture ->
  let entered,signal=Eio.Promise.create () and resume,release=Eio.Promise.create () in
  let teardown,begin_teardown=Eio.Promise.create () and cancelled,notice_cancel=Eio.Promise.create () in
  let created,provide_capture=Eio.Promise.create () and drained,finish_scope=Eio.Promise.create () in
  let unblock ()=if Eio.Promise.peek resume=None then Eio.Promise.resolve release () in
  Fun.protect ~finally:unblock (fun () ->
    Eio.Fiber.fork ~sw (fun () ->
      let captured=Eio.Switch.run (fun job_sw ->
        let binding,permit=prepare store fixture "05" "printf original" in
        let source,writer=Eio_unix.pipe job_sw in
        let owner=Eio_unix.Fd.use_exn "original stdout" (Eio_unix.Resource.fd writer)
          (fun fd -> start ~output:fd ~sw:job_sw ~env fixture permit) in
        Eio.Flow.close writer;
        let captured=O.For_testing.start ~after_prefix:(fun () -> ()) ~sw:job_sw ~fs:env#fs ~owner ~stream:P.Stdout ~source
          ~after_chunk:(fun () -> ()) ~on_metadata:(fun operation stage ->
            match operation,stage with
            | O.For_testing.Publish "stdout.seal.json",O.For_testing.Acquired ->
              Eio.Promise.resolve signal ();Eio.Promise.await resume
            | Open_recovery,Waiting | Open_recovery,Acquired | Publish _,Waiting | Publish _,Acquired -> ()) |> output in
        Eio.Fiber.fork_daemon ~sw:job_sw (fun () ->
          try Eio.Fiber.await_cancel () with Eio.Cancel.Cancelled _ as ex ->
            let bt=Printexc.get_raw_backtrace () in
            Eio.Promise.resolve notice_cancel ();Printexc.raise_with_backtrace ex bt);
        Eio.Promise.resolve provide_capture (binding,captured);
        Eio.Promise.await teardown;
        captured) in
      Eio.Promise.resolve finish_scope captured);
    Eio.Promise.await entered;
    let binding,captured=Eio.Promise.await created in
    let manifest=leaf fixture binding "stdout.seal.json" in
    check "actual seal publication is entered before its manifest exists" (not (Sys.file_exists manifest));
    Eio.Promise.resolve begin_teardown ();
    Eio.Promise.await cancelled;
    check "normal owner teardown waits for its already entered metadata transaction" (Eio.Promise.peek drained=None);
    unblock ();
    ignore (Eio.Promise.await drained);
    (match O.await_sealed captured with
     | Error O.Interrupted -> ()
     | Error _ | Ok _ -> Alcotest.fail "owner cancellation was lost after completing the entered publication");
    check "external output observer retains the original interruption" (O.extent captured=Error O.Interrupted);
    let json=Yojson.Safe.from_string (read manifest) in
    Alcotest.(check string) "entered publication finished its actual manifest before scope resource release"
      (P.Sha256.to_string (digest "original")) Yojson.Safe.Util.(json |> member "sha256" |> to_string);
    Alcotest.(check string) "normal teardown preserves original spool evidence" "original"
      (read (leaf fixture binding "stdout.bin"))))

let supervise value = value |> Result.map_error S.error_to_string |> require
let result_child value = match D.process value with
  | D.Child child -> child
  | Not_created _ -> Alcotest.fail "expected actual original child evidence"
let supervised ?execution ?(after_spawn=fun _ -> ()) ?(before_result_publish=fun () -> ())
    ?(after_result_publish=fun () -> ()) ?(before_result_read=fun _ -> ())
    ?(on_result_read_busy=fun _ -> ()) ~sw ~env fixture permit =
  let execution=match execution with None -> fixture.execution | Some execution -> execution in
  match S.For_testing.launch_effect_workspace ~before_result_read ~on_result_read_busy
      ~after_spawn ~before_result_publish ~after_result_publish ~sw ~fs:env#fs
      ~cgroup_parent_path:"/sys/fs/cgroup" ~execution permit with
  | S.Not_performed {error;_} -> Alcotest.fail (S.error_to_string error)
  | S.Performed {value;registry_release_error=None;pipe_cleanup_errors=[]} -> supervise value
  | S.Performed _ -> Alcotest.fail "original owner cleanup was not confirmed"
let supervised_output owner stream (seal : O.seal) =
  let buffer=Buffer.create 128 in
  let rec read offset =
    if offset=seal.byte_length then Buffer.contents buffer else (
      let part=S.read_output owner ~stream ~offset ~max_bytes:max_int |> supervise in
      check "supervisor range read advances through original bytes" (String.length part.data>0);
      Buffer.add_string buffer part.data;read (Int64.add offset (Int64.of_int (String.length part.data)))) in
  read 0L

let supervisor_owns_original_input_and_both_outputs = fixture (fun ~env ~sw:_ ~store fixture ->
  Eio.Switch.run (fun sw ->
    let data=String.init (256*1027) (fun i -> Char.chr (i mod 256)) in
    let binding,permit=prepare ~stdin:data store fixture "05" "/bin/cat; printf error >&2; exit 7" in
    let owner=supervised ~sw ~env fixture permit in
    check "same original admission reaches complete stdio supervision"
      ((S.original owner).binding=binding && (S.original owner).admission_id=id "04");
    let settled=S.await_settled owner |> supervise in
    exit 7 settled.physical_exit;
    let observed=S.await_observation owner |> supervise in
    check "physical observation retains the same actual gate and input evidence" (observed.settled=settled);
    (match observed.status with
     | P.Status {original;phase=P.Termination_observed (P.Exited 7);result=P.Result_pending;
         stdout=P.Sealed {sha256;_};stderr=P.Sealed _;_} ->
       check "original physical result does not fabricate exec proof or terminal publication"
         (original=S.original owner && sha256=settled.stdout.sha256)
     | P.Admitted _ | Status _ | Output _ | Released _ | Refused _ | Held _ ->
       Alcotest.fail "physical settlement became payload success or a ready result");
    (match settled.stdin with
     | S.Written n -> Alcotest.(check int64) "only the committed binary stdin was supplied" (Int64.of_int (String.length data)) n
     | S.Write_failed _ -> Alcotest.fail "cat lost its committed input");
    check "stdout digest covers all original input bytes" (settled.stdout.sha256=digest data);
    Alcotest.(check string) "owned stdin/stdout pair preserves binary bytes" data (supervised_output owner P.Stdout settled.stdout);
    Alcotest.(check string) "stderr belongs to the same original process" "error" (supervised_output owner P.Stderr settled.stderr);
    let receipt=S.await_result owner |> supervise in
    check "ready result digest covers the exact immutable receipt bytes" (receipt.sha256=digest receipt.content);
    Alcotest.(check string) "complete original result is actually retained on disk" receipt.content
      (read (leaf fixture binding S.result_leaf));
    let stat=Unix.lstat (leaf fixture binding S.result_leaf) in
    check "result is a single-link private immutable controller record" (stat.st_kind=Unix.S_REG && stat.st_nlink=1 && stat.st_perm land 0o7777=0o400);
    (match receipt.status with
     | P.Status {original;phase=P.Termination_observed (P.Exited 7);result=P.Result_ready sha256;_} ->
       check "ready means durable physical observation rather than payload success" (original=S.original owner && sha256=receipt.sha256)
     | P.Admitted _ | Status _ | Output _ | Released _ | Refused _ | Held _ -> Alcotest.fail "receipt did not remain bound to its original observation");
    let json=Yojson.Safe.from_string receipt.content in
    let wire=Yojson.Safe.Util.(json |> member "payload" |> member "status") in
    let status=P.response_of_json wire |> Result.map_error P.error_to_string |> require in
    (match status with
     | P.Status {original;result=P.Result_pending;_} -> check "frozen receipt has no self-referential digest" (original=S.original owner)
     | P.Admitted _ | Status _ | Output _ | Released _ | Refused _ | Held _ -> Alcotest.fail "stored receipt promoted itself before publication");
    check "duplicate result observers share the same original receipt" (S.await_result owner=Ok receipt)))

let supervisor_early_exit_does_not_wait_on_stdin = fixture (fun ~env ~sw:_ ~store fixture ->
  Eio.Switch.run (fun sw ->
    let _,permit=prepare ~stdin:(String.make (2*1024*1024) 'x') store fixture "05" "exit 0" in
    let owner=supervised ~sw ~env fixture permit ~after_spawn:(fun original ->
      exit 0 (L.await_quiescent original |> get)) in
    let settled=S.await_settled owner |> supervise in
    exit 0 settled.physical_exit;
    (match settled.stdin with
     | S.Write_failed {confirmed_prefix} -> Alcotest.(check int64) "reaped child accepted no synthetic replacement input" 0L confirmed_prefix
     | S.Written _ -> Alcotest.fail "closed original stdin was reported fully written");
    Alcotest.(check int64) "complete stdout is actually empty" 0L settled.stdout.byte_length;
    Alcotest.(check int64) "complete stderr is actually empty" 0L settled.stderr.byte_length))

let supervisor_reports_capture_failure_before_blocked_child_exit = fixture (fun ~env ~sw:_ ~store fixture ->
  Eio.Switch.run (fun sw ->
    let fifo=Filename.concat fixture.work "control" in
    Unix.mkfifo fifo 0o600;Unix.chown fifo fixture.uid fixture.execution.payload_gid;
    let binding,permit=prepare store fixture "05" "printf original; exec 1>&-; exec /bin/cat control >/dev/null" in
    let owner=supervised ~sw ~env fixture permit ~after_spawn:(fun _ ->
      let path=leaf fixture binding "stdout.seal.json" in
      Out_channel.with_open_bin path (fun oc -> output_string oc "preserved conflicting receipt");Unix.chmod path 0o400) in
    (match S.await_settled owner with
     | Error (S.Output_error {stream=P.Stdout;cause=O.Publication_failed _}) -> ()
     | Error _ | Ok _ -> Alcotest.fail "unavailable stdout waited on or completed a FIFO-blocked child");
    (match S.await_result owner with
     | Error (S.Output_error {stream=P.Stdout;cause=O.Publication_failed _}) -> ()
     | Error _ | Ok _ -> Alcotest.fail "result observer waited for a child blocked on failed output");
    (match S.snapshot owner with
     | Error (S.Output_error {stream=P.Stdout;cause=O.Publication_failed _}) -> ()
     | Error _ | Ok _ -> Alcotest.fail "status observation hid failed output behind pending success");
    let _,next=prepare store fixture "07" "exit 8" in
    let other=Eio.Switch.run (fun next_sw ->
      supervised ~sw:next_sw ~env fixture next |> S.await_settled |> supervise) in
    exit 8 other.physical_exit;
    ignore (S.cancel owner |> supervise);
    let stopped=S.await_quiescent owner |> supervise in
    check "original was still alive until its own durable cancel" (stopped.status=G.Signaled 9);
    (match S.await_observation owner with
     | Error (S.Output_error {stream=P.Stdout;cause=O.Publication_failed _}) -> ()
     | Error _ | Ok _ -> Alcotest.fail "physical termination hid missing complete original output");
    let current=R.load store ~binding |> registry in
    check "output failure never substitutes another cancellation owner" (R.cancellation_state current=R.Cancellation_requested)))

let supervisor_teardown_settles_external_observers = fixture (fun ~env ~sw:_ ~store fixture ->
  let fifo=Filename.concat fixture.work "control" in
  Unix.mkfifo fifo 0o600;Unix.chown fifo fixture.uid fixture.execution.payload_gid;
  let owner=Eio.Switch.run (fun sw ->
    let _,permit=prepare store fixture "05" "exec /bin/cat control" in
    supervised ~sw ~env fixture permit) in
  match S.await_settled owner with
  | Error S.Interrupted | Error (S.Output_error {cause=O.Interrupted;_}) -> ()
  | Error _ | Ok _ -> Alcotest.fail "supervisor teardown left an observer waiting or invented a complete result")

let result_publication_failure_preserves_raw_settlement = fixture (fun ~env ~sw:_ ~store fixture ->
  Eio.Switch.run (fun sw ->
    let binding,permit=prepare store fixture "05" "printf original; exit 7" in
    let path=leaf fixture binding S.result_leaf in
    let original=supervised ~sw ~env fixture permit ~after_spawn:(fun _ ->
      Out_channel.with_open_bin path (fun oc -> output_string oc "preserved conflicting result");Unix.chmod path 0o400) in
    let settled=S.await_settled original |> supervise in exit 7 settled.physical_exit;
    (match S.await_result original with
     | Error (S.Publication_failed _) -> ()
     | Error _ | Ok _ -> Alcotest.fail "conflicting result became durable readiness or hid actual settlement");
    Alcotest.(check string) "failed exclusive result publication preserves original conflicting evidence"
      "preserved conflicting result" (read path);
    Alcotest.(check string) "complete output remains available even with unavailable terminal receipt"
      "original" (supervised_output original P.Stdout settled.stdout);
    let _,next=prepare store fixture "07" "printf independent; exit 8" in
    let result=Eio.Switch.run (fun next_sw -> supervised ~sw:next_sw ~env fixture next |> S.await_result |> supervise) in
    (match result.status with
     | P.Status {phase=P.Termination_observed (P.Exited 8);result=P.Result_ready _;_} -> ()
     | P.Admitted _ | Status _ | Output _ | Released _ | Refused _ | Held _ -> Alcotest.fail "another original result could not publish")))

let result_waits_for_original_cancel stage ~after_publication ~change_stdout = fixture (fun ~env ~sw:_ ~store fixture ->
  Eio.Switch.run (fun sw ->
    let entered,signal_entered=Eio.Promise.create () and resume,signal_resume=Eio.Promise.create () in
    let locked,signal_locked=Eio.Promise.create () and unlock,signal_unlock=Eio.Promise.create () in
    let busy,signal_busy=Eio.Promise.create () and finished,signal_finished=Eio.Promise.create () in
    let cancel_done,signal_cancel_done=Eio.Promise.create () in
    let reached=ref false and published=ref false and publish_attempts=ref 0 and commits=ref 0 in
    let release promise resolver = if Eio.Promise.peek promise=None then Eio.Promise.resolve resolver () in
    Fun.protect ~finally:(fun () -> release resume signal_resume;release unlock signal_unlock) (fun () ->
      let binding,permit=prepare store fixture "05" "printf original; exit 7" in
      let path=leaf fixture binding S.result_leaf in
      let original=supervised ~sw ~env fixture permit
        ~before_result_publish:(fun () -> incr publish_attempts)
        ~after_result_publish:(fun () -> published:=true;incr commits)
        ~before_result_read:(fun current ->
          if current=stage && (not after_publication || !published) && not !reached then (
            reached:=true;Eio.Promise.resolve signal_entered ();Eio.Promise.await resume))
        ~on_result_read_busy:(fun current ->
          if current=stage then release busy signal_busy) in
      Eio.Promise.await entered;
      let before=if !published then Some (read path,Unix.stat path) else None in
      let record=R.load store ~binding |> registry in
      Eio.Fiber.fork ~sw (fun () ->
        let cancelled=R.For_testing.request_cancel ~after_publication:(fun () ->
          Eio.Promise.resolve signal_locked ();Eio.Promise.await unlock)
          record ~confirmed_admission_id:(id "04") in
        Eio.Promise.resolve signal_cancel_done cancelled);
      Eio.Promise.await locked;
      check "real original cancellation holds the registry lease" (R.load store ~binding=Error R.Busy);
      Eio.Fiber.fork ~sw (fun () -> Eio.Promise.resolve signal_finished (S.await_result original));
      release resume signal_resume;
      Eio.Promise.await busy;
      check "a busy original read leaves the result observer pending" (Eio.Promise.peek finished=None);
      let _,next=prepare store fixture "07" "printf independent; exit 8" in
      let other=Eio.Switch.run (fun next_sw -> supervised ~sw:next_sw ~env fixture next |> S.await_result |> supervise) in
      (match other.status with
       | P.Status {phase;result;_} ->
         check "different job published its own result"
           (phase=P.Termination_observed (P.Exited 8) && result=P.Result_ready other.sha256)
       | P.Admitted _ | Output _ | Released _ | Refused _ | Held _ ->
         Alcotest.fail "contended original blocked a different job");
      if change_stdout then Out_channel.with_open_bin (leaf fixture binding "stdout.bin") (fun oc -> output_string oc "tampered");
      release unlock signal_unlock;
      let cancelled=Eio.Promise.await cancel_done |> registry in
      let result=Eio.Promise.await finished in
      if change_stdout then
        check "stdout changed while stderr waited and readiness was refused"
          (result=Error (S.Output_error {stream=P.Stdout;cause=O.Invalid_storage}))
      else (
        let receipt=result |> supervise in
        (match receipt.status with
         | P.Status {revision;cancel_requested;result;_} ->
           check "ready status includes the original cancellation"
             (revision=R.revision cancelled && cancel_requested && result=P.Result_ready receipt.sha256)
         | P.Admitted _ | Output _ | Released _ | Refused _ | Held _ ->
           Alcotest.fail "result did not retain cancellation progress");
        check "repeated observers share the same result" (S.await_result original=Ok receipt);
        Alcotest.(check string) "returned receipt is the original durable file" receipt.content (read path));
      Alcotest.(check int) "result publication section was entered once" 1 !publish_attempts;
      Alcotest.(check int) "exclusive result publication committed once" 1 !commits;
      (match before with
       | None -> ()
       | Some (content,stat) ->
         let after=Unix.stat path in
         Alcotest.(check string) "waiting after publication preserves receipt bytes" content (read path);
         check "waiting after publication preserves receipt inode" (stat.Unix.st_dev=after.st_dev && stat.st_ino=after.st_ino)))))

let result_busy_observer_and_owner_cancellation = fixture (fun ~env ~sw ~store fixture ->
  let exception Cancel_waiter in
  let entered,signal_entered=Eio.Promise.create () and resume,signal_resume=Eio.Promise.create () in
  let locked,signal_locked=Eio.Promise.create () and unlock,signal_unlock=Eio.Promise.create () in
  let busy,signal_busy=Eio.Promise.create () and created,signal_created=Eio.Promise.create () in
  let closed,signal_closed=Eio.Promise.create () and cancel_done,signal_cancel_done=Eio.Promise.create () in
  let release promise resolver = if Eio.Promise.peek promise=None then Eio.Promise.resolve resolver () in
  Fun.protect ~finally:(fun () -> release resume signal_resume;release unlock signal_unlock) (fun () ->
    let binding,permit=prepare store fixture "05" "printf original; exit 7" in
    Eio.Fiber.fork ~sw (fun () ->
      (match Eio.Switch.run (fun job_sw ->
        let original=supervised ~sw:job_sw ~env fixture permit
          ~before_result_read:(function
            | S.For_testing.Observe_original -> Eio.Promise.resolve signal_entered ();Eio.Promise.await resume
            | Open_storage | Reopen_stdout | Reopen_stderr | Validate_stdout | Validate_stderr | Refresh_after_publication
            | Cancel_held_original -> ())
          ~on_result_read_busy:(function
            | S.For_testing.Observe_original -> release busy signal_busy
            | Open_storage | Reopen_stdout | Reopen_stderr | Validate_stdout | Validate_stderr | Refresh_after_publication
            | Cancel_held_original -> ()) in
        Eio.Promise.resolve signal_created (original,job_sw);
        Eio.Fiber.await_cancel ()) with
       | () -> Alcotest.fail "job owner unexpectedly survived teardown"
       | exception Cancel_waiter -> Eio.Promise.resolve signal_closed ()));
    let original,job_sw=Eio.Promise.await created in
    Eio.Promise.await entered;
    let record=R.load store ~binding |> registry in
    Eio.Fiber.fork ~sw (fun () ->
      let cancelled=R.For_testing.request_cancel ~after_publication:(fun () ->
        Eio.Promise.resolve signal_locked ();Eio.Promise.await unlock)
        record ~confirmed_admission_id:(id "04") in
      Eio.Promise.resolve signal_cancel_done cancelled);
    Eio.Promise.await locked;
    release resume signal_resume;
    Eio.Promise.await busy;
    let waiting,signal_waiting=Eio.Promise.create () in
    let observer_cancelled=ref false in
    Eio.Fiber.first
      (fun () ->
        try Eio.Promise.resolve signal_waiting ();ignore (S.await_result original);
          Alcotest.fail "busy publisher unexpectedly completed"
        with Eio.Cancel.Cancelled _ as ex -> observer_cancelled:=true;raise ex)
      (fun () -> Eio.Promise.await waiting);
    check "observer cancellation leaves the publisher running" !observer_cancelled;
    Eio.Switch.fail job_sw Cancel_waiter;
    Eio.Promise.await closed;
    check "owner teardown interrupts the busy result"
      (S.await_result original=Error S.Interrupted);
    check "teardown did not acquire the competing cancellation lease" (R.load store ~binding=Error R.Busy);
    release unlock signal_unlock;
    ignore (Eio.Promise.await cancel_done |> registry)))

let result_observer_cancel_and_source_progress_preserve_publication = fixture (fun ~env ~sw:_ ~store fixture ->
  Eio.Switch.run (fun sw ->
    let entered,signal=Eio.Promise.create () and resume,release=Eio.Promise.create () in
    let unblock ()=if Eio.Promise.peek resume=None then Eio.Promise.resolve release () in
    Fun.protect ~finally:unblock (fun () ->
      let binding,permit=prepare store fixture "05" "printf original; exit 7" in
      let original=supervised ~sw ~env fixture permit ~before_result_publish:(fun () ->
        Eio.Promise.resolve signal ();Eio.Promise.await resume) in
      Eio.Promise.await entered;
      check "actual settled result remains unpublished at the controlled boundary" (not (Sys.file_exists (leaf fixture binding S.result_leaf)));
      let waiting,notice=Eio.Promise.create () in
      let cancelled=ref false in
      Eio.Fiber.first
        (fun () -> try Eio.Promise.resolve notice ();ignore (S.await_result original |> supervise);
          Alcotest.fail "unpublished result was prematurely acknowledged"
          with Eio.Cancel.Cancelled _ as ex -> cancelled:=true;raise ex)
        (fun () -> Eio.Promise.await waiting);
      check "result observer cancellation propagates without owning the publisher" !cancelled;
      let record=R.load store ~binding |> registry in
      let current=R.request_cancel record ~confirmed_admission_id:(id "04") |> registry in
      let _,next=prepare store fixture "07" "printf independent; exit 8" in
      ignore (Eio.Switch.run (fun next_sw -> supervised ~sw:next_sw ~env fixture next |> S.await_result |> supervise));
      check "another original can publish before this result boundary resumes" (not (Sys.file_exists (leaf fixture binding S.result_leaf)));
      unblock ();
      let receipt=S.await_result original |> supervise in
      (match receipt.status with
       | P.Status {revision;cancel_requested=true;result=P.Result_ready hash;_} ->
         check "returned readiness retains latest same-launch cancellation progress" (revision=R.revision current && hash=receipt.sha256)
       | P.Admitted _ | Status _ | Output _ | Released _ | Refused _ | Held _ -> Alcotest.fail "publication rolled back cancellation progress");
      let json=Yojson.Safe.from_string receipt.content in
      let status=P.response_of_json Yojson.Safe.Util.(json |> member "payload" |> member "status") |> Result.map_error P.error_to_string |> require in
      (match status with
       | P.Status {revision=2L;cancel_requested=false;result=P.Result_pending;_} -> ()
       | P.Admitted _ | Status _ | Output _ | Released _ | Refused _ | Held _ -> Alcotest.fail "later cancellation rewrote the frozen original receipt");
      check "frozen result bytes retain the same digest across duplicate observers" (receipt.sha256=digest receipt.content && S.await_result original=Ok receipt))))

let result_owner_teardown_settles_external_observers = fixture (fun ~env ~sw:_ ~store fixture ->
  let fifo=Filename.concat fixture.work "control" in
  Unix.mkfifo fifo 0o600;Unix.chown fifo fixture.uid fixture.execution.payload_gid;
  let original=Eio.Switch.run (fun sw ->
    let _,permit=prepare store fixture "05" "exec /bin/cat control" in
    supervised ~sw ~env fixture permit) in
  match S.await_result original with
  | Error S.Interrupted | Error (S.Output_error {cause=O.Interrupted;_}) -> ()
  | Error _ | Ok _ -> Alcotest.fail "owner teardown left a result observer waiting or invented readiness")

let snapshot_does_not_wait_for_a_blocked_original = fixture (fun ~env ~sw:_ ~store fixture ->
  Eio.Switch.run (fun sw ->
    let fifo=Filename.concat fixture.work "control" in
    Unix.mkfifo fifo 0o600;Unix.chown fifo fixture.uid fixture.execution.payload_gid;
    let binding,permit=prepare store fixture "05" "exec /bin/cat control" in
    let original=supervised ~sw ~env fixture permit in
    let pending ()=let observed=S.snapshot original |> supervise in
      check "snapshot retains the same original source without a process wait"
        (R.binding observed.record=binding && R.launch_state observed.record=R.Requested (id "06"));
      match observed.progress with
      | S.Awaiting_settlement {stdout=P.Growing 0L;stderr=P.Growing 0L} -> ()
      | Awaiting_settlement _ | Physically_settled _ | Publication_known _ ->
        Alcotest.fail "blocked original became physical or complete settlement" in
    pending ();
    let _,next=prepare store fixture "07" "printf independent; exit 8" in
    ignore (Eio.Switch.run (fun next_sw -> supervised ~sw:next_sw ~env fixture next |> S.await_result |> supervise));
    pending ();
    ignore (S.cancel original |> supervise);
    let receipt=S.await_result original |> supervise in
    let observed=S.snapshot original |> supervise in
    match observed.progress with
    | S.Publication_known actual -> check "snapshot shares the exact original publication" (actual=receipt.sha256)
    | Awaiting_settlement _ | Physically_settled _ -> Alcotest.fail "snapshot lost published original result"))

let snapshot_keeps_settlement_publication_and_current_source_distinct = fixture (fun ~env ~sw:_ ~store fixture ->
  Eio.Switch.run (fun sw ->
    let entered,signal=Eio.Promise.create () and resume,release=Eio.Promise.create () in
    let unblock ()=if Eio.Promise.peek resume=None then Eio.Promise.resolve release () in
    Fun.protect ~finally:unblock (fun () ->
      let binding,permit=prepare store fixture "05" "printf original; exit 7" in
      let original=supervised ~sw ~env fixture permit ~before_result_publish:(fun () ->
        Eio.Promise.resolve signal ();Eio.Promise.await resume) in
      Eio.Promise.await entered;
      let observed=S.snapshot original |> supervise in
      (match observed.progress with
       | S.Physically_settled {status=P.Status {phase=P.Termination_observed (P.Exited 7);
           result=P.Result_pending;stdout=P.Sealed _;stderr=P.Sealed _;_};_} -> ()
       | Physically_settled _ | Awaiting_settlement _ | Publication_known _ ->
         Alcotest.fail "unpublished settlement waited or claimed a complete result");
      check "snapshot never publishes the pending receipt" (not (Sys.file_exists (leaf fixture binding S.result_leaf)));
      unblock ();
      let receipt=S.await_result original |> supervise in
      let current=S.cancel original |> supervise in
      let observed=S.snapshot original |> supervise in
      check "snapshot separately refreshes later original cancellation"
        (R.cancellation_state observed.record=R.Cancellation_requested && R.revision observed.record=R.revision current);
      (match observed.progress with
       | S.Publication_known actual -> check "current cancellation never rewrites the historical publication"
           (actual=receipt.sha256 && receipt.sha256=digest receipt.content)
       | Awaiting_settlement _ | Physically_settled _ -> Alcotest.fail "fresh source lost original publication");
      let storage=R.open_storage ~sw current |> registry in
      let restored=D.load ~sw ~storage ~expected_sha256:(Some receipt.sha256) |> Result.map_error D.error_to_string |> require in
      match D.inspect restored |> Result.map_error D.error_to_string |> require with
      | P.Status {cancel_requested=true;result=P.Result_ready hash;_} ->
        check "fresh result authority requires actual original readback" (hash=receipt.sha256)
      | P.Admitted _ | Status _ | Output _ | Released _ | Refused _ | Held _ -> Alcotest.fail "fresh original readback lost current source")))

let snapshot_missing_authority_does_not_poison_or_cancel_original = fixture (fun ~env ~sw:_ ~store fixture ->
  Eio.Switch.run (fun sw ->
    let fifo=Filename.concat fixture.work "control" in
    Unix.mkfifo fifo 0o600;Unix.chown fifo fixture.uid fixture.execution.payload_gid;
    let binding,permit=prepare store fixture "05" "exec /bin/cat control" in
    let original=supervised ~sw ~env fixture permit in
    let claim=Filename.concat fixture.registry_path (P.Id.to_string binding.operation_id ^ ".claim.json") in
    Unix.rename claim (claim ^ ".evidence");
    (match S.snapshot original with
     | Error (S.Launch_error (L.Registry_error R.Missing_original)) -> ()
     | Error _ | Ok _ -> Alcotest.fail "missing source became a pending or complete original snapshot");
    Unix.rename (claim ^ ".evidence") claim;
    let observed=S.snapshot original |> supervise in
    (match observed.progress with
     | S.Awaiting_settlement _ -> ()
     | Physically_settled _ | Publication_known _ -> Alcotest.fail "failed observer cancelled its original job");
    check "failed snapshot never records implicit cancellation" (R.cancellation_state observed.record=R.No_cancellation);
    ignore (S.cancel original |> supervise);ignore (S.await_result original |> supervise)))

let snapshot_observer_cancel_leaves_original_alive = fixture (fun ~env ~sw:_ ~store fixture ->
  Eio.Switch.run (fun sw ->
    let fifo=Filename.concat fixture.work "control" in
    Unix.mkfifo fifo 0o600;Unix.chown fifo fixture.uid fixture.execution.payload_gid;
    let _,permit=prepare store fixture "05" "exec /bin/cat control" in
    let original=supervised ~sw ~env fixture permit in
    let entered,signal=Eio.Promise.create () in
    let cancelled=ref false in
    Eio.Fiber.first
      (fun () -> try ignore (S.For_testing.snapshot original ~after_original:(fun () ->
          Eio.Promise.resolve signal ();Eio.Fiber.await_cancel ()) |> supervise);
        Alcotest.fail "paused snapshot returned without its original source observation"
        with Eio.Cancel.Cancelled _ as ex -> cancelled:=true;raise ex)
      (fun () -> Eio.Promise.await entered;
        let _,next=prepare store fixture "07" "printf independent; exit 8" in
        ignore (Eio.Switch.run (fun next_sw -> supervised ~sw:next_sw ~env fixture next |> S.await_result |> supervise)));
    check "snapshot observer cancellation propagates" !cancelled;
    let observed=S.snapshot original |> supervise in
    (match observed.progress with
     | S.Awaiting_settlement _ -> ()
     | Physically_settled _ | Publication_known _ -> Alcotest.fail "cancelled snapshot stopped the original");
    check "cancelled observer has no operation cancellation authority" (R.cancellation_state observed.record=R.No_cancellation);
    ignore (S.cancel original |> supervise);ignore (S.await_result original |> supervise)))

let block_activation fixture binding =
  let path=leaf fixture binding L.activation_leaf in
  Out_channel.with_open_bin path (fun oc -> output_string oc "preserved conflicting activation");Unix.chmod path 0o400

let held_startup_is_stopped_and_durably_proves_nonstart = fixture (fun ~env ~sw ~store fixture ->
  let marker=Filename.concat fixture.work "activated" in
  let binding,receipt=Eio.Switch.run (fun job_sw ->
    let binding,permit=prepare ~stdin:"original\000input" store fixture "05" ": > activated" in
    block_activation fixture binding;
    let original=supervised ~sw:job_sw ~env fixture permit in
    (match S.await_settled original with Error (S.Launch_error _) -> ()
     | Error _ | Ok _ -> Alcotest.fail "held startup lost its original error");
    let receipt=S.await_result original |> supervise in
    check "terminal cleanup does not hide the original startup failure" (Result.is_error (S.availability original));
    (match receipt.status with
     | P.Status {phase=P.Not_started P.Cancelled_before_activation;cancel_requested=true;
         result=P.Result_ready hash;stdout=P.Sealed {byte_length=0L;_};stderr=P.Sealed {byte_length=0L;_};_} ->
       check "proven cancelled non-start refers to the exact committed receipt" (hash=receipt.sha256)
     | P.Admitted _ | Status _ | Output _ | Released _ | Refused _ | Held _ -> Alcotest.fail "held startup became payload exit or indefinite readiness uncertainty");
    binding,receipt) in
  check "payload marker never ran before activation" (not (Sys.file_exists marker));
  let record=R.load store ~binding |> registry in
  check "cleanup recorded original cancellation before stopping its kernel tree"
    (R.cancellation_state record=R.Cancellation_requested);
  let rebooted=R.open_registry ~sw ~fs:env#fs ~root_path:fixture.registry_path
    ~route:{route with boot_id=id "09"} ~owner ~payload_uid:fixture.uid |> registry in
  let storage=R.load rebooted ~binding |> registry |> R.open_storage ~sw |> registry in
  let restored=D.load ~sw ~storage ~expected_sha256:(Some receipt.sha256) |> Result.map_error D.error_to_string |> require in
  check "bootstrap physical status is retained without inventing a payload exit" ((result_child restored).physical_exit=P.Signaled 9);
  (match D.inspect restored |> Result.map_error D.error_to_string |> require with
   | P.Status {phase=P.Not_started P.Cancelled_before_activation;cancel_requested=true;_} -> ()
   | P.Admitted _ | Status _ | Output _ | Released _ | Refused _ | Held _ -> Alcotest.fail "cold read lost the proven original non-start"))

let native_exec_rejection_is_distinct_from_payload_exit127 = fixture (fun ~env ~sw ~store fixture ->
  let binding,receipt=Eio.Switch.run (fun job_sw ->
    let binding,permit=prepare store fixture "05" ": > activated" in
    let execution={fixture.execution with executable=Filename.concat fixture.work "missing-program"} in
    let original=supervised ~execution ~sw:job_sw ~env fixture permit in
    let settled=S.await_settled original |> supervise in
    (match settled.physical_exit.boundary.preparation with
     | G.Rejected {stage=G.Child_exec;error=Unix.ENOENT} -> ()
     | G.Pending | Ready | Rejected _ -> Alcotest.fail "actual missing executable was not authoritatively rejected");
    let receipt=S.await_result original |> supervise in
    (match receipt.status with
     | P.Status {phase=P.Not_started P.Launch_rejected;cancel_requested=false;result=P.Result_ready _;_} -> ()
     | P.Admitted _ | Status _ | Output _ | Released _ | Refused _ | Held _ -> Alcotest.fail "native rejection was promoted to a payload exit");
    binding,receipt) in
  check "rejected executable performed no payload marker" (not (Sys.file_exists (Filename.concat fixture.work "activated")));
  let storage=R.load store ~binding |> registry |> R.open_storage ~sw |> registry in
  let restored=D.load ~sw ~storage ~expected_sha256:(Some receipt.sha256) |> Result.map_error D.error_to_string |> require in
  check "native bootstrap exit remains separate receipt evidence" ((result_child restored).physical_exit=P.Exited 127);
  let _,next=prepare store fixture "07" "exit 127" in
  let actual=Eio.Switch.run (fun job_sw -> supervised ~sw:job_sw ~env fixture next |> S.await_result |> supervise) in
  match actual.status with
  | P.Status {phase=P.Termination_observed (P.Exited 127);result=P.Result_ready _;_} -> ()
  | P.Admitted _ | Status _ | Output _ | Released _ | Refused _ | Held _ -> Alcotest.fail "exit code alone fabricated a non-start")

let held_cleanup_cannot_hide_unavailable_output = fixture (fun ~env ~sw:_ ~store fixture ->
  Eio.Switch.run (fun sw ->
    let binding,permit=prepare store fixture "05" ": > activated" in
    block_activation fixture binding;
    let path=leaf fixture binding "stdout.seal.json" in
    Out_channel.with_open_bin path (fun oc -> output_string oc "preserved conflicting seal");Unix.chmod path 0o400;
    let original=supervised ~sw ~env fixture permit in
    (match S.await_result original with
     | Error (S.Output_error {stream=P.Stdout;cause=O.Publication_failed _}) -> ()
     | Error _ | Ok _ -> Alcotest.fail "held cleanup hid unavailable output behind a non-start receipt");
    check "failed output did not recreate a terminal receipt" (not (Sys.file_exists (leaf fixture binding S.result_leaf)));
    check "original held child was actually stopped" ((S.await_quiescent original |> supervise).status=G.Signaled 9);
    Alcotest.(check string) "failed held cleanup preserves conflicting output evidence" "preserved conflicting seal" (read path);
    let _,next=prepare store fixture "07" "exit 8" in
    ignore (Eio.Switch.run (fun job_sw -> supervised ~sw:job_sw ~env fixture next |> S.await_result |> supervise))))

let held_cleanup_missing_authority_does_not_signal = fixture (fun ~env ~sw:_ ~store fixture ->
  Eio.Switch.run (fun sw ->
    let binding,permit=prepare store fixture "05" ": > activated" in
    block_activation fixture binding;
    let actual=ref None in
    let claim=Filename.concat fixture.registry_path (P.Id.to_string binding.operation_id ^ ".claim.json") in
    let original=supervised ~sw ~env fixture permit ~after_spawn:(fun owner ->
      actual:=Some owner;Unix.rename claim (claim ^ ".evidence")) in
    (match S.await_result original with
     | Error (S.Launch_error (L.Registry_error R.Missing_original)) -> ()
     | Error _ | Ok _ -> Alcotest.fail "missing original authority permitted a non-start or cancellation claim");
    let owner=match !actual with Some owner -> owner | None -> Alcotest.fail "actual held owner missing" in
    let entered,signal=Eio.Promise.create () in
    let cancelled=ref false in
    Eio.Fiber.first
      (fun () -> try Eio.Promise.resolve signal ();ignore (L.await_quiescent owner |> get);
        Alcotest.fail "missing original authority signalled the still-paused child"
        with Eio.Cancel.Cancelled _ as ex -> cancelled:=true;raise ex)
      (fun () -> Eio.Promise.await entered;
        let _,next=prepare store fixture "07" "exit 8" in
        ignore (Eio.Switch.run (fun job_sw -> supervised ~sw:job_sw ~env fixture next |> S.await_result |> supervise)));
    check "failed original cleanup leaves kernel ownership for explicit teardown" !cancelled;
    check "unavailable original has no fabricated receipt" (not (Sys.file_exists (leaf fixture binding S.result_leaf)))))

let held_cancel_waits_for_a_contended_original = fixture (fun ~env ~sw:_ ~store fixture ->
  Eio.Switch.run (fun sw ->
    let locked,signal_locked=Eio.Promise.create () and unlock,signal_unlock=Eio.Promise.create () in
    let busy,signal_busy=Eio.Promise.create () and finished,signal_finished=Eio.Promise.create () in
    let release promise resolver = if Eio.Promise.peek promise=None then Eio.Promise.resolve resolver () in
    Fun.protect ~finally:(fun () -> release unlock signal_unlock) (fun () ->
      let binding,permit=prepare store fixture "05" ": > activated" in
      block_activation fixture binding;
      let record=R.load store ~binding |> registry in
      let original=supervised ~sw ~env fixture permit
        ~after_spawn:(fun _ ->
          (* A shared reader owns the original's lease before the held startup
             starts its own cancellation. *)
          Eio.Fiber.fork ~sw (fun () ->
            ignore (R.For_testing.refresh ~after_lock:(fun () ->
              Eio.Promise.resolve signal_locked ();Eio.Promise.await unlock) record));
          Eio.Promise.await locked)
        ~on_result_read_busy:(function
          | S.For_testing.Cancel_held_original -> release busy signal_busy
          | Observe_original | Open_storage | Reopen_stdout | Reopen_stderr | Validate_stdout | Validate_stderr
          | Refresh_after_publication -> ()) in
      Eio.Fiber.fork ~sw (fun () -> Eio.Promise.resolve signal_finished (S.await_result original));
      (match Eio.Fiber.first
               (fun () -> Eio.Promise.await busy;`Waiting)
               (fun () -> ignore (Eio.Promise.await finished);`Settled) with
       | `Waiting -> ()
       | `Settled -> Alcotest.fail "a contended held cancellation settled the result instead of waiting");
      check "the contended cancellation recorded nothing while the lease was taken"
        (R.cancellation_state (R.load store ~binding |> registry)=R.No_cancellation);
      release unlock signal_unlock;
      let receipt=Eio.Promise.await finished |> supervise in
      (match receipt.status with
       | P.Status {phase=P.Not_started P.Cancelled_before_activation;cancel_requested=true;
           result=P.Result_ready hash;stdout=P.Sealed {byte_length=0L;_};stderr=P.Sealed {byte_length=0L;_};_} ->
         check "the waiting cancellation produced the exact committed non-start receipt" (hash=receipt.sha256)
       | P.Admitted _ | Status _ | Output _ | Released _ | Refused _ | Held _ ->
         Alcotest.fail "a contended held cancellation lost the proven non-start");
      check "waiting for the lease does not hide the original startup failure" (Result.is_error (S.availability original));
      check "cancellation was recorded once the lease was free"
        (R.cancellation_state (R.load store ~binding |> registry)=R.Cancellation_requested);
      check "the held tree was stopped once the lease was free"
        ((S.await_quiescent original |> supervise).status=G.Signaled 9);
      check "payload marker never ran" (not (Sys.file_exists (Filename.concat fixture.work "activated"))))))

let held_result_observer_cancel_preserves_cleanup_publication = fixture (fun ~env ~sw:_ ~store fixture ->
  Eio.Switch.run (fun sw ->
    let entered,signal=Eio.Promise.create () and resume,release=Eio.Promise.create () in
    let unblock ()=if Eio.Promise.peek resume=None then Eio.Promise.resolve release () in
    Fun.protect ~finally:unblock (fun () ->
      let binding,permit=prepare store fixture "05" ": > activated" in
      block_activation fixture binding;
      let original=supervised ~sw ~env fixture permit ~before_result_publish:(fun () ->
        Eio.Promise.resolve signal ();Eio.Promise.await resume) in
      Eio.Promise.await entered;
      let waiting,notice=Eio.Promise.create () in
      let cancelled=ref false in
      Eio.Fiber.first
        (fun () -> try Eio.Promise.resolve notice ();ignore (S.await_result original |> supervise);
          Alcotest.fail "paused held result was acknowledged before publication"
          with Eio.Cancel.Cancelled _ as ex -> cancelled:=true;raise ex)
        (fun () -> Eio.Promise.await waiting);
      check "held-result observer cancellation leaves cleanup publication alive" !cancelled;
      let _,next=prepare store fixture "07" "exit 8" in
      ignore (Eio.Switch.run (fun job_sw -> supervised ~sw:job_sw ~env fixture next |> S.await_result |> supervise));
      unblock ();
      let receipt=S.await_result original |> supervise in
      match receipt.status with
      | P.Status {phase=P.Not_started P.Cancelled_before_activation;result=P.Result_ready _;_} -> ()
      | P.Admitted _ | Status _ | Output _ | Released _ | Refused _ | Held _ -> Alcotest.fail "cancelled held observer lost its original terminal result")))

let result_readiness_requires_current_original_files stage change = fixture (fun ~env ~sw:_ ~store fixture ->
  Eio.Switch.run (fun sw ->
    let binding,permit=prepare store fixture "05" "printf original; exit 7" in
    let spool=leaf fixture binding "stdout.bin" and seal=leaf fixture binding "stdout.seal.json" in
    let receipt=leaf fixture binding S.result_leaf in
    let changed=ref false in
    let mutate () =
      changed:=true;
      check "mutation follows actual sealed output bytes" (read spool="original" && Sys.file_exists seal);
      check "mutation occurs at the selected real result commit boundary"
        (Sys.file_exists receipt=(match stage with `Before -> false | `After -> true));
      match change with
      | `Move_spool -> Unix.rename spool (spool ^ ".evidence")
      | `Truncate_spool -> Unix.truncate spool 3
      | `Delete_seal -> Unix.link seal (seal ^ ".evidence");Unix.unlink seal
      | `Replace_seal -> Unix.rename seal (seal ^ ".evidence");
        Out_channel.with_open_bin seal (fun oc -> output_string oc "replacement seal");Unix.chmod seal 0o400
      | `Rebind_stream ->
        Out_channel.with_open_bin spool (fun oc -> output_string oc "forged!!");
        let fields=match Yojson.Safe.from_file seal with `Assoc fields -> fields
          | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ -> Alcotest.fail "actual seal missing" in
        let fields=List.map (fun (key,value) -> key,if key="sha256" then `String (P.Sha256.to_string (digest "forged!!")) else value) fields in
        Unix.chmod seal 0o600;Yojson.Safe.to_file seal (`Assoc fields);Unix.chmod seal 0o400
      | `Delete_receipt -> Unix.link receipt (receipt ^ ".evidence");Unix.unlink receipt
      | `Replace_receipt -> Unix.rename receipt (receipt ^ ".evidence");
        Out_channel.with_open_bin receipt (fun oc -> output_string oc "replacement receipt");Unix.chmod receipt 0o400 in
    let original=supervised ~sw ~env fixture permit
      ~before_result_publish:(match stage with `Before -> mutate | `After -> fun () -> ())
      ~after_result_publish:(match stage with `Before -> (fun () -> ()) | `After -> mutate) in
    let settled=S.await_settled original |> supervise in exit 7 settled.physical_exit;
    (match change,S.await_result original with
     | (`Move_spool | `Truncate_spool | `Delete_seal | `Replace_seal | `Rebind_stream),
       Error (S.Output_error {stream=P.Stdout;cause=(O.Invalid_storage | O.Storage_unavailable)}) -> ()
     | (`Delete_receipt | `Replace_receipt),Error S.Receipt_storage_unavailable -> ()
     | _,(Error _ | Ok _) -> Alcotest.fail "changed original output/receipt attachment acquired result readiness");
    check "actual filesystem mutation was observed" !changed;
    (match stage with
     | `Before -> check "failed stream verification never publishes a terminal receipt" (not (Sys.file_exists receipt))
     | `After ->
       let retained=match change with `Delete_receipt | `Replace_receipt -> receipt ^ ".evidence"
         | `Move_spool | `Truncate_spool | `Delete_seal | `Replace_seal | `Rebind_stream -> receipt in
       let status=P.response_of_json Yojson.Safe.Util.(Yojson.Safe.from_string (read retained) |> member "payload" |> member "status")
         |> Result.map_error P.error_to_string |> require in
       (match status with
        | P.Status {result=P.Result_pending;_} -> ()
        | P.Admitted _ | Status _ | Output _ | Released _ | Refused _ | Held _ ->
          Alcotest.fail "failed post-commit validation rewrote frozen candidate evidence"));
    (match change with
     | `Move_spool -> Alcotest.(check string) "moved original bytes remain evidence" "original" (read (spool ^ ".evidence"))
     | `Truncate_spool -> Alcotest.(check string) "failed verification does not repair or hide the truncation" "ori" (read spool)
     | `Delete_seal -> check "missing seal is never recreated" (not (Sys.file_exists seal))
     | `Replace_seal -> Alcotest.(check string) "replacement seal is never overwritten" "replacement seal" (read seal)
     | `Rebind_stream -> Alcotest.(check string) "self-consistent rewritten stream is never adopted or repaired" "forged!!" (read spool)
     | `Delete_receipt -> check "missing receipt is never recreated" (not (Sys.file_exists receipt))
     | `Replace_receipt -> Alcotest.(check string) "replacement receipt is never overwritten" "replacement receipt" (read receipt));
    let _,next=prepare store fixture "07" "printf independent; exit 8" in
    let independent=Eio.Switch.run (fun next_sw -> supervised ~sw:next_sw ~env fixture next |> S.await_result |> supervise) in
    match independent.status with
    | P.Status {phase=P.Termination_observed (P.Exited 8);result=P.Result_ready _;_} -> ()
    | P.Admitted _ | Status _ | Output _ | Released _ | Refused _ | Held _ -> Alcotest.fail "failed original readiness blocked another actual job"))

let completed_output ~env ~store fixture script = Eio.Switch.run (fun sw ->
  let binding,permit=prepare store fixture "05" script in
  let original=supervised ~sw ~env fixture permit in
  let settled=S.await_settled original |> supervise in
  binding,settled)
let original_storage ~sw store binding =
  R.load store ~binding |> registry |> R.open_storage ~sw |> registry
let binary_script="/usr/bin/python3 -c 'import sys;sys.stdout.buffer.write(bytes(range(256))*1025);sys.stderr.buffer.write(bytes([101,0,255]))'"
let binary_bytes ()=String.init (256*1025) (fun i -> Char.chr (i mod 256))

let replace_byte_identical_output fixture binding =
  let spool=leaf fixture binding "stdout.bin" and seal=leaf fixture binding "stdout.seal.json" in
  let original=read spool in
  let old_spool=Unix.lstat spool and old_seal=Unix.lstat seal in
  let fields=match Yojson.Safe.from_file seal with `Assoc fields -> fields
    | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ -> Alcotest.fail "actual private seal missing" in
  Unix.rename spool (spool ^ ".evidence");
  Out_channel.with_open_bin spool (fun oc -> output_string oc original);Unix.chmod spool 0o600;
  let current=Unix.lstat spool in
  let fields=List.map (fun (key,value) -> key,match key with
    | "file_device" -> `String (string_of_int current.st_dev)
    | "file_inode" -> `String (string_of_int current.st_ino)
    | _ -> value) fields in
  Unix.rename seal (seal ^ ".evidence");Yojson.Safe.to_file seal (`Assoc fields);Unix.chmod seal 0o400;
  check "same-byte replacement supplies two genuinely new physical attachments"
    (old_spool.st_ino<>current.st_ino && old_seal.st_ino<>(Unix.lstat seal).st_ino);
  Alcotest.(check string) "replacement preserves every original byte while rebinding the valid seal" original (read spool)

let result_syncs_byte_identical_replacement_before_readiness = fixture (fun ~env ~sw:_ ~store fixture ->
  Eio.Switch.run (fun sw ->
    let binding,permit=prepare store fixture "05" "printf original; exit 7" in
    let changed=ref false in
    let owner=supervised ~sw ~env fixture permit ~before_result_publish:(fun () ->
      replace_byte_identical_output fixture binding;changed:=true) in
    let actual=S.await_settled owner |> supervise in
    exit 7 actual.physical_exit;
    let receipt=S.await_result owner |> supervise in
    check "actual cached output is compared after the same-byte inode replacement" !changed;
    (match receipt.status with
     | P.Status {result=P.Result_ready _;stdout=P.Sealed {byte_length;sha256};_} ->
       check "durability confirmation retains the original actual byte seal"
         (byte_length=actual.stdout.byte_length && sha256=actual.stdout.sha256)
     | P.Admitted _ | Status _ | Output _ | Released _ | Refused _ | Held _ -> Alcotest.fail "verified synchronized output did not produce its original result");
    Alcotest.(check string) "synchronized current spool retains original bytes" "original" (read (leaf fixture binding "stdout.bin"));
    Alcotest.(check string) "detached capture evidence is never rewritten" "original" (read (leaf fixture binding "stdout.bin.evidence"))))

let replacement_output_sync_failure_never_seals target stage = fixture (fun ~env ~sw:_ ~store fixture ->
  let binding,_=completed_output ~env ~store fixture "printf original" in
  replace_byte_identical_output fixture binding;
  let failed_leaf=match target with `Spool -> "stdout.bin" | `Seal -> "stdout.seal.json" in
  let reached=ref false in
  let result=Eio.Switch.run (fun read_sw ->
    let storage=original_storage ~sw:read_sw store binding in
    O.For_testing.reopen ~sw:read_sw ~storage ~stream:P.Stdout
      ~after_chunk:(fun () -> ()) ~after_stat:(fun ~leaf:_ -> ())
      ~before_sync:(fun ~leaf actual -> if leaf=failed_leaf && actual=stage then (
        reached:=true;raise (Unix.Unix_error (Unix.EIO,"fsync",leaf))))) in
  check "fault reaches the real matched file or parent sync boundary" !reached;
  (match result with Error O.Invalid_storage -> ()
   | Error _ | Ok _ -> Alcotest.fail "sync failure exposed a sealed same-byte replacement");
  Alcotest.(check string) "failed sync preserves current original bytes" "original" (read (leaf fixture binding "stdout.bin"));
  Alcotest.(check string) "failed sync preserves detached original capture bytes" "original" (read (leaf fixture binding "stdout.bin.evidence"));
  let _,next=prepare store fixture "07" "printf independent; exit 8" in
  let independent=Eio.Switch.run (fun next_sw -> supervised ~sw:next_sw ~env fixture next |> S.await_result |> supervise) in
  match independent.status with
  | P.Status {phase=P.Termination_observed (P.Exited 8);result=P.Result_ready _;_} -> ()
  | P.Admitted _ | Status _ | Output _ | Released _ | Refused _ | Held _ -> Alcotest.fail "failed output sync blocked another actual original")

let result_read value=value |> Result.map_error D.error_to_string |> require
let persisted_result ~env ~store fixture script = Eio.Switch.run (fun sw ->
  let binding,permit=prepare store fixture "05" script in
  let original=supervised ~sw ~env fixture permit in
  binding,(S.await_result original |> supervise))
let unlaunched_original ?(mode=Exec_ssh_protocol.Effect) ?(domain=P.Workspace_process)
    ~sw ~store fixture ~known_launch () =
  let spec=P.spec ~domain ~argv:["/bin/sh";"-c";": > must-not-run"] ~env:[]
    ~cwd:fixture.work ~remote_root:fixture.work ~stdin:"original\000unsent\255" ~mode
    ~network_policy_sha256:None |> require in
  let binding=P.binding ~route ~owner ~operation_id:(id "05")
    ~invocation_sha256:(digest "unlaunched original") ~spec_sha256:(P.spec_sha256 spec) |> require in
  let original=R.admit store ~new_admission_id:(id "04") ~binding ~spec |> registry in
  let permit=if known_launch then Some (R.commit_launch original ~confirmed_admission_id:(id "04")
      ~launch_id:(id "06") |> registry) else None in
  let cancelled=R.request_cancel original ~confirmed_admission_id:(id "04") |> registry in
  let proof=match permit with
    | None -> R.settle_cancelled_admission ~sw cancelled |> registry
    | Some permit -> R.retire_cancelled_launch ~sw permit |> registry in
  binding,proof
let no_child_result value expected =
  (match D.process value with
   | D.Not_created {launch_id} -> check "no child retains only its original optional launch" (launch_id=expected)
   | Child _ -> Alcotest.fail "no-child result invented an OS child, gate or input delivery");
  match D.inspect value |> result_read with
  | P.Status {phase=P.Not_started P.Cancelled_before_activation;cancel_requested=true;
      result=P.Result_ready hash;stdout=P.Sealed {byte_length=0L;sha256=out};stderr=P.Sealed {byte_length=0L;sha256=err};_} ->
    check "no-child readiness binds complete actual empty streams and exact receipt"
      (hash=D.sha256 value && out=digest "" && err=digest "")
  | P.Admitted _ | Status _ | Output _ | Released _ | Refused _ | Held _ ->
    Alcotest.fail "no-child result fabricated exit or lost complete original bytes"
let no_child_results_preserve_modes_domains_and_restart () =
  let isolated=P.Isolated_job {preparation_id=id "11";image_sha256=digest "image";input_manifest_sha256=digest "inputs"} in
  List.iter (fun known_launch -> List.iter (fun mode -> List.iter (fun domain ->
    fixture (fun ~env ~sw ~store fixture ->
      let binding,proof=unlaunched_original ~mode ~domain ~sw ~store fixture ~known_launch () in
      let expected=if known_launch then Some (id "06") else None in
      let published=D.publish_unlaunched ~sw ~proof |> result_read in
      no_child_result published expected;
      check "cancelled original never executes its payload" (not (Sys.file_exists (Filename.concat fixture.work "must-not-run")));
      let names=["stdout.bin";"stdout.seal.json";"stderr.bin";"stderr.seal.json";D.leaf] in
      let saved=List.map (fun name -> let path=leaf fixture binding name in name,(Unix.lstat path).st_ino,read path) names in
      let again=D.publish_unlaunched ~sw ~proof |> result_read in
      check "duplicate no-child publication retains exact frozen digest" (D.sha256 again=D.sha256 published);
      List.iter (fun (name,inode,bytes) -> let path=leaf fixture binding name in
        Alcotest.(check int) "duplicate publication does not replace original evidence inode" inode (Unix.lstat path).st_ino;
        Alcotest.(check string) "duplicate publication preserves every original evidence byte" bytes (read path)) saved;
      let rebooted=R.open_registry ~sw ~fs:env#fs ~root_path:fixture.registry_path
        ~route:{route with boot_id=id "09"} ~owner ~payload_uid:fixture.uid |> registry in
      let storage=original_storage ~sw rebooted binding in
      let restored=D.load ~sw ~storage ~expected_sha256:(Some (D.sha256 published)) |> result_read in
      no_child_result restored expected;
      let out=D.read_output restored ~stream:P.Stdout ~offset:0L ~max_bytes:max_int |> result_read in
      Alcotest.(check string) "original no-child output is an actual verified empty stream" "" out.data) ())
      [P.Workspace_process;isolated]) [Exec_ssh_protocol.Observe;Guest_local;Effect]) [false;true]

let no_child_partial_publication_cancel_reconciles_original () =
  List.iter (fun boundary -> fixture (fun ~env ~sw ~store fixture ->
    let binding,proof=unlaunched_original ~sw ~store fixture ~known_launch:true () in
    let entered,signal=Eio.Promise.create () in let cancelled=ref false in
    Eio.Fiber.first
      (fun () -> try
        ignore (D.For_testing.publish_unlaunched ~sw ~proof ~on_stage:(fun stage ->
          if stage=boundary then (Eio.Promise.resolve signal ();Eio.Fiber.await_cancel ())) |> result_read);
        Alcotest.fail "paused no-child publisher returned before its actual stage resumed"
        with Eio.Cancel.Cancelled _ as ex -> cancelled:=true;raise ex)
      (fun () -> Eio.Promise.await entered;
        ignore (R.refresh (R.storage_record (R.unlaunched_storage proof)) |> registry);
        let _,next=prepare store fixture "07" "printf independent; exit 8" in
        ignore (Eio.Switch.run (fun next_sw -> supervised ~sw:next_sw ~env fixture next |> S.await_result |> supervise)));
    check "no-child producer interruption propagates without cancelling another job" !cancelled;
    let names=List.filter (fun name -> Sys.file_exists (leaf fixture binding name))
      ["stdout.bin";"stdout.seal.json";"stderr.bin";"stderr.seal.json";D.leaf] in
    let saved=List.map (fun name -> let path=leaf fixture binding name in name,(Unix.lstat path).st_ino,read path) names in
    let recovered=D.publish_unlaunched ~sw ~proof |> result_read in
    no_child_result recovered (Some (id "06"));
    List.iter (fun (name,inode,bytes) -> let path=leaf fixture binding name in
      Alcotest.(check int) "reconciliation retains earlier committed inode" inode (Unix.lstat path).st_ino;
      Alcotest.(check string) "reconciliation retains earlier committed exact bytes" bytes (read path)) saved) ())
    [D.For_testing.Stdout_sealed;Stderr_sealed;Receipt_committed]

let no_child_missing_sealed_evidence_never_recreates_empty_data () =
  List.iter (fun name -> fixture (fun ~env:_ ~sw ~store fixture ->
    let binding,proof=unlaunched_original ~sw ~store fixture ~known_launch:true () in
    let published=D.publish_unlaunched ~sw ~proof |> result_read in
    let path=leaf fixture binding name in Unix.unlink path;
    let storage=R.unlaunched_storage proof in
    check "missing original sealed evidence refuses readback" (Result.is_error (D.load ~sw ~storage ~expected_sha256:(Some (D.sha256 published))));
    check "a repeated publisher cannot turn missing sealed data into fresh empty completion"
      (Result.is_error (D.publish_unlaunched ~sw ~proof));
    check "missing sealed evidence remains missing for reconciliation" (not (Sys.file_exists path))) ())
    ["stdout.bin";"stdout.seal.json";"stderr.bin";"stderr.seal.json"]

let no_child_receipt_rejects_invented_process_facts () =
  List.iter (fun change -> fixture (fun ~env ~sw ~store fixture ->
    let binding,proof=unlaunched_original ~sw ~store fixture ~known_launch:true () in
    ignore (D.publish_unlaunched ~sw ~proof |> result_read);
    let path=leaf fixture binding D.leaf in
    let object_ = function `Assoc fields -> fields
      | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ -> Alcotest.fail "original receipt object missing" in
    let update name f fields=List.map (fun (key,value) -> key,if key=name then f value else value) fields in
    let fields=Yojson.Safe.from_file path |> object_ in
    let payload=List.assoc "payload" fields |> object_ in
    let process=List.assoc "process" payload |> object_ in
    let process=match change with
      | `Physical -> ("physical_status",`Assoc ["kind",`String "exited";"code",`String "0"])::process
      | `Gate -> ("gate",`Null)::process
      | `Input -> ("stdin",`Assoc ["state",`String "written";"byte_length",`String "0"])::process
      | `Missing_launch -> List.remove_assoc "launch_id" process
      | `Wrong_launch -> update "launch_id" (fun _ -> `Null) process
      | `Duplicate_state -> ("state",`String "not_created")::process
      | `Unknown -> update "state" (fun _ -> `String "future") process
      | `Phase -> process in
    let payload=update "process" (fun _ -> `Assoc process) payload in
    let payload=match change with
      | `Phase -> update "status" (fun value -> `Assoc (update "phase" (fun _ ->
          `Assoc ["state",`String "termination_observed";"physical_status",`Assoc ["kind",`String "exited";"code",`String "0"]]) (object_ value))) payload
      | `Physical | `Gate | `Input | `Missing_launch | `Wrong_launch | `Duplicate_state | `Unknown -> payload in
    let payload=`Assoc payload in
    let checksum=Agent_core_sha256.(to_hex (digest_string ("masc_endpoint_terminal_result_v1\000" ^ Yojson.Safe.to_string payload))) in
    let fields=update "payload" (fun _ -> payload) fields |> update "payload_sha256" (fun _ -> `String checksum) in
    Unix.chmod path 0o600;Yojson.Safe.to_file path (`Assoc fields);Unix.chmod path 0o400;
    let malformed=read path in
    check "valid checksum cannot grant invented OS or input facts" (Result.is_error (D.load ~sw ~storage:(R.unlaunched_storage proof) ~expected_sha256:None));
    Alcotest.(check string) "invalid historical evidence is preserved without repair" malformed (read path);
    let _,next=prepare store fixture "07" "printf independent; exit 8" in
    ignore (Eio.Switch.run (fun next_sw -> supervised ~sw:next_sw ~env fixture next |> S.await_result |> supervise))) ())
    [`Physical;`Gate;`Input;`Missing_launch;`Wrong_launch;`Duplicate_state;`Unknown;`Phase]

let no_child_final_mutation_never_becomes_readiness () =
  List.iter (fun change -> fixture (fun ~env ~sw ~store fixture ->
    let binding,proof=unlaunched_original ~sw ~store fixture ~known_launch:true () in
    let receipt=leaf fixture binding D.leaf in
    let result=D.For_testing.publish_unlaunched ~sw ~proof ~on_stage:(function
      | D.For_testing.Stdout_sealed | Stderr_sealed -> ()
      | Receipt_committed -> match change with
        | `Missing_stdout -> Unix.unlink (leaf fixture binding "stdout.bin")
        | `Receipt_bytes -> Unix.chmod receipt 0o600;
          Out_channel.with_open_gen [Open_wronly;Open_append;Open_binary] 0 receipt (fun oc -> output_string oc "\n");Unix.chmod receipt 0o400) in
    check "late output or exact receipt mutation never yields complete readiness" (Result.is_error result);
    let malformed=read receipt in
    let _,next=prepare store fixture "07" "printf independent; exit 8" in
    ignore (Eio.Switch.run (fun next_sw -> supervised ~sw:next_sw ~env fixture next |> S.await_result |> supervise));
    Alcotest.(check string) "failure preserves the exact current receipt evidence" malformed (read receipt)) ())
    [`Missing_stdout;`Receipt_bytes]

let no_child_original_authority_rejects_rebound_storage = fixture (fun ~env:_ ~sw ~store fixture ->
  let binding,proof=unlaunched_original ~sw ~store fixture ~known_launch:true () in
  let path=Filename.dirname (leaf fixture binding D.leaf) in
  Unix.rename path (path ^ ".evidence");Unix.mkdir path 0o700;
  check "no-child proof never adopts a replacement job with matching pathname"
    (Result.is_error (D.publish_unlaunched ~sw ~proof));
  Alcotest.(check int) "replacement storage receives no original output or receipt" 0 (Array.length (Sys.readdir path)))

let empty_output_or_bootstrap_code_cannot_invent_nonstart = fixture (fun ~env ~sw ~store fixture ->
  let binding,receipt=persisted_result ~env ~store fixture ": > activated; exit 7" in
  check "actual silent payload performed its marker" (Sys.file_exists (Filename.concat fixture.work "activated"));
  let record=R.load store ~binding |> registry in
  let cancelled=R.request_cancel record ~confirmed_admission_id:(id "04") |> registry in
  let storage=R.open_storage ~sw cancelled |> registry in
  let loaded=D.load ~sw ~storage ~expected_sha256:(Some receipt.sha256) |> result_read in
  let empty=P.Sealed {byte_length=0L;sha256=digest ""} in
  let original=P.original ~binding ~admission_id:(id "04") in
  List.iter (fun phase ->
    let status : P.response=P.Status {original;revision=R.revision cancelled;phase;cancel_requested=true;
      result=P.Result_pending;stdout=empty;stderr=empty} in
    check "actual activated gate rejects a fabricated non-start or mismatched raw physical status"
      (Result.is_error (D.encode ~status ~process:(D.process loaded))))
    [P.Not_started P.Cancelled_before_activation;P.Not_started P.Launch_rejected;P.Termination_observed (P.Exited 8)])
let recovered_bytes original stream byte_length =
  let buffer=Buffer.create 128 in
  let rec read offset=if offset=byte_length then Buffer.contents buffer else
    let chunk=D.read_output original ~stream ~offset ~max_bytes:max_int |> result_read in
    check "recovered original output makes actual range progress" (String.length chunk.data>0);
    Buffer.add_string buffer chunk.data;read (Int64.add offset (Int64.of_int (String.length chunk.data))) in
  read 0L
let terminal_result_reopens_after_owner_exit_and_boot_change = fixture (fun ~env ~sw ~store fixture ->
  let binding,receipt=persisted_result ~env ~store fixture (binary_script ^ "; exit 7") in
  let original=R.load store ~binding |> registry in
  let cancelled=R.request_cancel original ~confirmed_admission_id:(id "04") |> registry in
  let rebooted=R.open_registry ~sw ~fs:env#fs ~root_path:fixture.registry_path
    ~route:{route with boot_id=id "09"} ~owner ~payload_uid:fixture.uid |> registry in
  Eio.Switch.run (fun read_sw ->
    let storage=original_storage ~sw:read_sw rebooted binding in
    check "known host digest never silently adopts another result"
      (Result.is_error (D.load ~sw:read_sw ~storage ~expected_sha256:(Some (digest "different result"))));
    let restored=D.load ~sw:read_sw ~storage ~expected_sha256:(Some receipt.sha256) |> result_read in
    check "recovered receipt keeps its original exact digest and accepted stdin fact"
      (D.sha256 restored=receipt.sha256 && (result_child restored).input=D.Accepted 0L);
    let gate=(result_child restored).gate in
    check "raw gate evidence survives without reconstructing a kernel handle"
      (gate.preparation=D.Ready && gate.decision=G.Activate_requested && gate.control=D.Ended);
    (match D.inspect restored |> result_read with
     | P.Status {original;revision;phase=P.Termination_observed (P.Exited 7);cancel_requested=true;
         result=P.Result_ready hash;stdout=P.Sealed stdout;stderr=P.Sealed stderr} ->
       check "restored readiness retains original admission and later cancellation without changing receipt"
         (original.binding=binding && original.admission_id=id "04" && revision=R.revision cancelled && hash=receipt.sha256);
       let out=D.read_output restored ~stream:P.Stdout ~offset:0L ~max_bytes:max_int |> result_read in
       check "recovered binary range retains complete original extent" (out.extent=P.Sealed stdout);
       check "both recovered complete stream digests match original bytes"
         (stdout.sha256=digest (binary_bytes ()) && stderr.sha256=digest "e\000\255");
       Alcotest.(check string) "all original binary stdout bytes survive restart readback"
         (binary_bytes ()) (recovered_bytes restored P.Stdout stdout.byte_length);
       Alcotest.(check string) "all original stderr bytes survive independently"
         "e\000\255" (recovered_bytes restored P.Stderr stderr.byte_length)
     | P.Admitted _ | Status _ | Output _ | Released _ | Refused _ | Held _ -> Alcotest.fail "restart invented execution or lost its original terminal result");
    check "terminal readback cannot recreate an old-boot launch permit"
      (R.commit_launch (R.storage_record storage) ~confirmed_admission_id:(id "04") ~launch_id:(id "10")=Error R.Endpoint_replaced)))

let terminal_result_strictly_rejects_corrupt_records () =
  List.iter (fun change -> fixture (fun ~env ~sw ~store fixture ->
    let binding,_=persisted_result ~env ~store fixture "printf original; exit 7" in
    let path=leaf fixture binding S.result_leaf in
    let fields=match Yojson.Safe.from_file path with `Assoc fields -> fields
      | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ -> Alcotest.fail "actual receipt missing" in
    let update name f fields=List.map (fun (key,value) -> key,if key=name then f value else value) fields in
    let object_ f=function `Assoc values -> `Assoc (f values)
      | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ -> Alcotest.fail "actual receipt object missing" in
    let in_process f values=update "process" (object_ f) values in
    let payload_change values=match change with
      | `Unknown -> ("unexpected",`Bool true)::values
      | `Bad_input -> in_process (update "stdin" (fun _ -> `Assoc ["state",`String "written";"byte_length",`String "1"])) values
      | `Bad_launch -> in_process (update "launch_id" (fun _ -> `String (P.Id.to_string (id "12")))) values
      | `Wrong_admission -> update "status" (object_ (update "admission_id" (fun _ -> `String (P.Id.to_string (id "13"))))) values
      | `Old_revision -> update "status" (object_ (update "revision" (fun _ -> `String "1"))) values
      | `Duplicate_gate -> in_process (update "gate" (object_ (fun fields -> ("control",`String "ended")::fields))) values
      | `Physical_mismatch -> in_process (update "physical_status" (fun _ ->
          `Assoc ["kind",`String "exited";"code",`String "8"])) values
      | `Noncanonical_physical -> in_process (update "physical_status" (fun _ ->
          `Assoc ["kind",`String "exited";"code",`String "07"])) values
      | `Duplicate_physical -> in_process (update "physical_status" (object_ (fun fields -> ("kind",`String "exited")::fields))) values
      | `Missing_physical -> in_process (List.remove_assoc "physical_status") values
      | `Checksum -> update "status" (object_ (update "phase" (fun _ ->
          `Assoc ["state",`String "termination_observed";"physical_status",`Assoc ["kind",`String "exited";"code",`String "8"]]))) values
      | `Missing_version -> values in
    let fields=update "payload" (object_ payload_change) fields in
    (* A valid checksum on hostile structured input ensures rejection comes
       from original/schema validation, not only accidental byte corruption. *)
    let fields=if change=`Checksum then fields else
      let payload=List.assoc "payload" fields in
      let checksum=Agent_core_sha256.(to_hex (digest_string ("masc_endpoint_terminal_result_v1\000" ^ Yojson.Safe.to_string payload))) in
      update "payload_sha256" (fun _ -> `String checksum) fields in
    let fields=if change=`Missing_version then List.remove_assoc "version" fields else fields in
    Unix.chmod path 0o600;Yojson.Safe.to_file path (`Assoc fields);Unix.chmod path 0o400;
    let before=read path in
    let storage=original_storage ~sw store binding in
    check "corrupt original terminal receipt cannot become readiness" (Result.is_error (D.load ~sw ~storage ~expected_sha256:None));
    Alcotest.(check string) "read failure preserves exact malformed evidence without repair" before (read path);
    check "failed result recovery never grants another launch"
      (R.commit_launch (R.storage_record storage) ~confirmed_admission_id:(id "04") ~launch_id:(id "14")=Error R.Launch_already_requested);
    let _,next=prepare store fixture "07" "printf independent; exit 8" in
    ignore (Eio.Switch.run (fun next_sw -> supervised ~sw:next_sw ~env fixture next |> S.await_result |> supervise))) ())
    [`Unknown;`Bad_input;`Bad_launch;`Wrong_admission;`Old_revision;`Duplicate_gate;
     `Physical_mismatch;`Noncanonical_physical;`Duplicate_physical;`Missing_physical;`Checksum;`Missing_version]

let terminal_result_missing_data_never_becomes_empty () =
  List.iter (fun missing -> fixture (fun ~env ~sw ~store fixture ->
    let binding,receipt=persisted_result ~env ~store fixture "printf original; exit 7" in
    let path=leaf fixture binding (match missing with `Receipt -> S.result_leaf | `Output -> "stdout.bin") in
    let before=read path in
    (match missing with
     | `Receipt -> Unix.rename path (path ^ ".evidence")
     | `Output -> Out_channel.with_open_bin path (fun oc -> output_string oc "tampered"));
    let storage=original_storage ~sw store binding in
    check "unavailable receipt or mismatched output cannot certify a terminal result"
      (Result.is_error (D.load ~sw ~storage ~expected_sha256:(Some receipt.sha256)));
    (match missing with
     | `Receipt -> Alcotest.(check string) "missing canonical receipt retains its evidence" before (read (path ^ ".evidence"))
     | `Output -> Alcotest.(check string) "failed output hash preserves changed evidence" "tampered" (read path))) ()) [`Receipt;`Output]

let terminal_result_final_attachment_mutation_is_refused () =
  List.iter (fun target -> fixture (fun ~env ~sw ~store fixture ->
    let binding,receipt=persisted_result ~env ~store fixture "printf original; exit 7" in
    let storage=original_storage ~sw store binding in
    let path=leaf fixture binding (match target with `Receipt -> S.result_leaf | `Output -> "stdout.bin") in
    let original=read path in
    let result=D.For_testing.load ~sw ~storage ~expected_sha256:(Some receipt.sha256)
      ~after_receipt_read:(fun () -> ()) ~before_ready:(fun () ->
        Unix.rename path (path ^ ".evidence");
        Out_channel.with_open_bin path (fun oc -> output_string oc original);
        Unix.chmod path (match target with `Receipt -> 0o400 | `Output -> 0o600);
        let _,next=prepare store fixture "07" "exit 8" in
        ignore (Eio.Switch.run (fun next_sw -> supervised ~sw:next_sw ~env fixture next |> S.await_result |> supervise))) in
    check "final readiness cannot adopt a byte-identical later inode" (Result.is_error result);
    Alcotest.(check string) "final refusal preserves the exact original evidence" original (read (path ^ ".evidence"))) ()) [`Receipt;`Output]

let terminal_reader_cancel_and_scope_preserve_original = fixture (fun ~env ~sw:_ ~store fixture ->
  let binding,receipt=persisted_result ~env ~store fixture (binary_script ^ "; exit 7") in
  let entered,signal=Eio.Promise.create () and blocked,_=Eio.Promise.create () in
  let cancelled=ref false in
  Eio.Fiber.first
    (fun () -> try Eio.Switch.run (fun read_sw ->
      let storage=original_storage ~sw:read_sw store binding in
      ignore (D.For_testing.load ~sw:read_sw ~storage ~expected_sha256:(Some receipt.sha256)
        ~after_receipt_read:(fun () -> Eio.Promise.resolve signal ();Eio.Promise.await blocked)
        ~before_ready:(fun () -> ()) |> result_read);
      Alcotest.fail "cancelled reader exposed unchecked readiness")
      with Eio.Cancel.Cancelled _ as ex -> cancelled:=true;raise ex)
    (fun () -> Eio.Promise.await entered;
      let _,next=prepare store fixture "07" "exit 8" in
      ignore (Eio.Switch.run (fun next_sw -> supervised ~sw:next_sw ~env fixture next |> S.await_result |> supervise)));
  check "cancelled reader does not own the original process or receipt" !cancelled;
  let restored=Eio.Switch.run (fun read_sw ->
    let storage=original_storage ~sw:read_sw store binding in
    let loaded=D.load ~sw:read_sw ~storage ~expected_sha256:(Some receipt.sha256) |> result_read in
    let chunk=D.read_output loaded ~stream:P.Stdout ~offset:0L ~max_bytes:max_int |> result_read in
    check "fresh reader retains original binary bytes" (chunk.data=String.sub (binary_bytes ()) 0 (String.length chunk.data));
    loaded) in
  check "reader scope closure cannot leave usable dangling descriptors" (Result.is_error (D.inspect restored));
  check "cancelled/closed observers preserve the exact original receipt" (digest (read (leaf fixture binding S.result_leaf))=receipt.sha256))

let sealed_output_reopens_after_owner_exit_and_boot_change = fixture (fun ~env ~sw ~store fixture ->
  let binding,settled=completed_output ~env ~store fixture binary_script in
  exit 0 settled.physical_exit;
  let rebooted=R.open_registry ~sw ~fs:env#fs ~root_path:fixture.registry_path
    ~route:{route with boot_id=id "09"} ~owner ~payload_uid:fixture.uid |> registry in
  Eio.Switch.run (fun read_sw ->
    let storage=original_storage ~sw:read_sw rebooted binding in
    let stdout=O.reopen ~sw:read_sw ~storage ~stream:P.Stdout |> output in
    let stderr=O.reopen ~sw:read_sw ~storage ~stream:P.Stderr |> output in
    let out_seal=O.await_sealed stdout |> output and err_seal=O.await_sealed stderr |> output in
    check "reopened streams retain both original durable digests" (out_seal=settled.stdout && err_seal=settled.stderr);
    Alcotest.(check string) "every original binary stdout byte survives owner teardown and boot change"
      (binary_bytes ()) (all_output stdout out_seal);
    Alcotest.(check string) "stderr retains its independent original stream" "e\000\255" (all_output stderr err_seal);
    check "old boot output recovery never restores launch authority"
      (R.commit_launch (R.storage_record storage) ~confirmed_admission_id:(id "04") ~launch_id:(id "10")=Error R.Endpoint_replaced)))

let sealed_output_reopen_rejects_changed_evidence () =
  List.iter (fun change -> fixture (fun ~env ~sw ~store fixture ->
    let binding,_=completed_output ~env ~store fixture "printf original" in
    let spool=leaf fixture binding "stdout.bin" and manifest=leaf fixture binding "stdout.seal.json" in
    let rewrite_json update =
      let fields=match Yojson.Safe.from_file manifest with `Assoc fields -> fields
        | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ -> Alcotest.fail "actual seal missing" in
      Unix.chmod manifest 0o600;Yojson.Safe.to_file manifest (`Assoc (update fields));Unix.chmod manifest 0o400 in
    (match change with
     | `Bytes -> Out_channel.with_open_bin spool (fun oc -> output_string oc "tampered")
     | `Truncated -> Unix.truncate spool 3
     | `Spool_replaced -> Unix.rename spool (spool ^ ".evidence");
       Out_channel.with_open_bin spool (fun oc -> output_string oc "original");Unix.chmod spool 0o600
     | `Duplicate -> rewrite_json (fun fields -> ("version",`Int 1)::fields)
     | `Unknown -> rewrite_json (fun fields -> ("unrecognized",`Bool true)::fields)
     | `Wrong_stream -> rewrite_json (List.map (fun (key,value) -> key,if key="stream" then `String "stderr" else value))
     | `Wrong_original ->
       let wrong=P.request_to_json (P.Inspect (P.original ~binding ~admission_id:(id "11")))
         |> Result.map_error P.error_to_string |> require in
       rewrite_json (List.map (fun (key,value) -> key,if key="original" then wrong else value))
     | `Seal_symlink -> Unix.rename manifest (manifest ^ ".evidence");Unix.symlink (manifest ^ ".evidence") manifest
     | `Seal_link -> Unix.link manifest (manifest ^ ".evidence"));
    let before=read spool in
    let storage=original_storage ~sw store binding in
    check "changed original evidence cannot become sealed output" (Result.is_error (O.reopen ~sw ~storage ~stream:P.Stdout));
    Alcotest.(check string) "failed recovery preserves evidence without repair or replay" before (read spool);
    let _,next=prepare store fixture "07" "printf independent; exit 8" in
    let finished=Eio.Switch.run (fun next_sw -> supervised ~sw:next_sw ~env fixture next |> S.await_settled |> supervise) in
    exit 8 finished.physical_exit) ())
    [`Bytes;`Truncated;`Spool_replaced;`Duplicate;`Unknown;`Wrong_stream;`Wrong_original;`Seal_symlink;`Seal_link]

let sealed_output_hash_observer_cancellation_preserves_original = fixture (fun ~env ~sw ~store fixture ->
  let binding,settled=completed_output ~env ~store fixture binary_script in
  let entered,signal=Eio.Promise.create () and blocked,_=Eio.Promise.create () in
  let cancelled=ref false in
  Eio.Fiber.first
    (fun () -> try Eio.Switch.run (fun read_sw ->
      let storage=original_storage ~sw:read_sw store binding in
      ignore (O.For_testing.reopen ~sw:read_sw ~storage ~stream:P.Stdout
        ~before_sync:(fun ~leaf:_ _ -> ())
        ~after_stat:(fun ~leaf:_ -> ())
        ~after_chunk:(fun () -> Eio.Promise.resolve signal ();Eio.Promise.await blocked) |> output);
      Alcotest.fail "cancelled hash exposed an unchecked sealed reader")
      with Eio.Cancel.Cancelled _ as ex -> cancelled:=true;raise ex)
    (fun () -> Eio.Promise.await entered);
  check "hash observer cancellation propagates" !cancelled;
  let storage=original_storage ~sw store binding in
  let recovered=O.reopen ~sw ~storage ~stream:P.Stdout |> output in
  Alcotest.(check string) "fresh observer recovers the same complete original without recapture"
    (binary_bytes ()) (all_output recovered settled.stdout);
  check "original launch is still the same one after observer cancellation"
    (R.launch_state (R.storage_record storage)=R.Requested (id "06")))

let sealed_output_hash_releases_lock_and_preserves_cancel_progress = fixture (fun ~env ~sw ~store fixture ->
  let binding,settled=completed_output ~env ~store fixture binary_script in
  let storage=original_storage ~sw store binding in
  let entered,signal=Eio.Promise.create () and resume,release=Eio.Promise.create () in
  let done_,finish=Eio.Promise.create () in
  let first=ref true in
  let unblock ()=if Eio.Promise.peek resume=None then Eio.Promise.resolve release () in
  Fun.protect ~finally:unblock (fun () ->
    Eio.Fiber.fork ~sw (fun () ->
      let result=O.For_testing.reopen ~sw ~storage ~stream:P.Stdout ~before_sync:(fun ~leaf:_ _ -> ()) ~after_stat:(fun ~leaf:_ -> ()) ~after_chunk:(fun () ->
        if !first then (first:=false;Eio.Promise.resolve signal ();Eio.Promise.await resume)) in
      Eio.Promise.resolve finish result);
    Eio.Promise.await entered;
    let known=R.load store ~binding |> registry in
    let cancelled=R.request_cancel known ~confirmed_admission_id:(id "04") |> registry in
    check "actual source registry remains available during full spool hashing" (R.cancellation_state cancelled=R.Cancellation_requested);
    let _,next=prepare store fixture "07" "printf independent; exit 8" in
    let finished=Eio.Switch.run (fun next_sw -> supervised ~sw:next_sw ~env fixture next |> S.await_settled |> supervise) in
    exit 8 finished.physical_exit;
    check "another actual job settles before this original hash resumes" (Eio.Promise.peek done_=None);
    unblock ();
    let reopened=Eio.Promise.await done_ |> output in
    Alcotest.(check string) "legitimate same-launch cancellation leaves already complete original bytes readable"
      (binary_bytes ()) (all_output reopened settled.stdout)))

let sealed_output_range_read_rejects_later_replacement = fixture (fun ~env ~sw ~store fixture ->
  let binding,_=completed_output ~env ~store fixture "printf original" in
  let storage=original_storage ~sw store binding in
  let reopened=O.reopen ~sw ~storage ~stream:P.Stdout |> output in
  let spool=leaf fixture binding "stdout.bin" in
  Unix.rename spool (spool ^ ".evidence");
  Out_channel.with_open_bin spool (fun oc -> output_string oc "original");Unix.chmod spool 0o600;
  check "range reads refuse a later canonical replacement rather than adopting or silently reading detached evidence"
    (O.read reopened ~offset:0L ~max_bytes:8=Error O.Invalid_storage);
  Alcotest.(check string) "refused read preserves the detached original bytes" "original" (read (spool ^ ".evidence")))

let sealed_output_atomic_open_rejects_raced_special_leaf target change = fixture (fun ~env ~sw ~store fixture ->
  let binding,_=completed_output ~env ~store fixture "printf original" in
  let name=match target with `Seal -> "stdout.seal.json" | `Spool -> "stdout.bin" in
  let path=leaf fixture binding name in
  let evidence=path ^ ".evidence" and before=read path in
  let changed=ref false in
  let storage=original_storage ~sw store binding in
  let result=O.For_testing.reopen ~sw ~storage ~stream:P.Stdout ~after_chunk:(fun () -> ())
    ~before_sync:(fun ~leaf:_ _ -> ())
    ~after_stat:(fun ~leaf -> if leaf=name then (
      changed:=true;
      Unix.rename path evidence;
      match change with `Fifo -> Unix.mkfifo path 0o600 | `Symlink -> Unix.symlink evidence path)) in
  check "actual regular-file prestat preceded the special-leaf swap" !changed;
  (match result with Error O.Invalid_storage -> ()
   | Error _ | Ok _ -> Alcotest.fail "raced special leaf did not produce a typed original-storage refusal");
  check "refusal preserves the FIFO without any writer or the original symlink"
    ((Unix.lstat path).st_kind=(match change with `Fifo -> Unix.S_FIFO | `Symlink -> Unix.S_LNK));
  Alcotest.(check string) "failed atomic open preserves every original evidence byte" before (read evidence);
  let _,next=prepare store fixture "07" "printf independent; exit 8" in
  let finished=Eio.Switch.run (fun next_sw -> supervised ~sw:next_sw ~env fixture next |> S.await_settled |> supervise) in
  exit 8 finished.physical_exit)

let refusal = fixture (fun ~env ~sw ~store fixture ->
  let _,permit=prepare store fixture "05" ": > activated" in
  match L.launch_effect_workspace ~sw ~fs:env#fs ~cgroup_parent_path:"/sys/fs/cgroup"
      ~execution:fixture.execution ~stdin:fixture.input ~stdout:fixture.output ~stderr:fixture.output permit with
  | R.Performed {value=Error (L.Group_error G.Group.Unsupported);release_error=None}
  | R.Performed {value=Error (L.Group_error (G.Group.Refused G.Group.Controller_not_root));release_error=None} -> ()
  | R.Not_performed _ | R.Performed _ -> Alcotest.fail "unsupported platform or controller must refuse")
let digest_package_matches_known_sha256 () =
  let hex value=Agent_core_sha256.(digest_string value |> to_hex) in
  (* Expected values are SHA-256 from an independent implementation. *)
  Alcotest.(check string) "empty input" "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855" (hex "");
  Alcotest.(check string) "short ASCII" "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad" (hex "abc");
  Alcotest.(check string) "4 KiB of every byte value" "c8f5d0341d54d951a71b136e6e2afcb14d11ed8489a7ae126a8fee0df6ecf193"
    (hex (String.init 4096 (fun i -> Char.chr (i land 0xff))))
let failed_gate_channel_is_written_to_the_receipt () =
  let binding=P.binding ~route ~owner ~operation_id:(id "05") ~invocation_sha256:(digest "original invocation")
      ~spec_sha256:(digest "original spec") |> require in
  let sealed=P.Sealed {byte_length=0L;sha256=digest ""} in
  let status=P.Status {original=P.original ~binding ~admission_id:(id "04");revision=1L;
      phase=P.Termination_observed (P.Signaled 9);cancel_requested=false;result=P.Result_pending;
      stdout=sealed;stderr=sealed} in
  let gate : D.gate={preparation=D.Ready;decision=G.Activate_requested;
      control=D.Failed {diagnostic="control IO: Connection reset by peer"}} in
  (* encode reads its payload back, so Ok means the failed state decodes. *)
  let process=D.Child {physical_exit=P.Signaled 9;launch_id=id "06";input=D.Accepted 0L;gate} in
  let content=D.encode ~status ~process
    |> Result.map_error D.error_to_string |> require in
  let control=Yojson.Safe.Util.(Yojson.Safe.from_string content |> member "payload" |> member "process" |> member "gate" |> member "control") in
  (* The second value is the base64 of the diagnostic above. *)
  check "failed channel and its diagnostic are written"
    (control=`Assoc ["state",`String "failed";"diagnostic_b64",`String "Y29udHJvbCBJTzogQ29ubmVjdGlvbiByZXNldCBieSBwZWVy"])
let lifetime value=value |> Result.map_error C.error_to_string |> require
let owned_job ~sw ~env fixture permit =
  C.start_effect_workspace ~sw ~fs:env#fs ~cgroup_parent_path:"/sys/fs/cgroup"
    ~execution:fixture.execution permit
let held_owned_job ~sw ~env fixture permit ~before_sync =
  let first=Atomic.make true in
  let fault=Recovery_test.before_parent_sync_dispatch
    ~before_sync:(fun () -> if Atomic.compare_and_set first true false then before_sync ()) in
  Recovery_test.with_replace_dispatch_fault fault
    (fun () -> owned_job ~sw ~env fixture permit)

let endpoint_lifetime_survives_request_and_result_observer = fixture (fun ~env ~sw:_ ~store fixture ->
  Eio.Switch.run (fun endpoint ->
    let binding,permit=prepare store fixture "05" "printf original; printf x >> ran; exit 7" in
    let entered,signal=Eio.Promise.create () and resume,release=Eio.Promise.create () in
    let unblock ()=if Eio.Promise.peek resume=None then Eio.Promise.resolve release () in
    Fun.protect ~finally:unblock (fun () ->
      let job=Eio.Switch.run (fun _request ->
        held_owned_job ~sw:endpoint ~env fixture permit ~before_sync:(fun () ->
          Eio.Promise.resolve signal ();Eio.Promise.await resume)) in
      Eio.Promise.await entered;
      check "request scope ended without draining the endpoint's entered startup"
        (R.load store ~binding=Error R.Busy);
      let waiting,observe=Eio.Promise.create () in
      Eio.Fiber.first
        (fun () -> Eio.Promise.resolve observe ();ignore (C.await_result job |> lifetime);
          Alcotest.fail "blocked original unexpectedly completed")
        (fun () -> Eio.Promise.await waiting;
          let _,next=prepare store fixture "07" "printf independent; exit 8" in
          ignore (owned_job ~sw:endpoint ~env fixture next |> C.await_result |> lifetime));
      check "another job and cancelled result observer cannot release original startup"
        (Eio.Promise.peek resume=None);
      unblock ();
      let digest=C.await_result job |> lifetime in
      check "later event observers share the same original receipt" (C.await_result job=Ok digest);
      Eio.Switch.run (fun reader ->
        let loaded=C.load_result ~sw:reader job |> lifetime in
        check "full result loading binds the exact original publication digest" (D.sha256 loaded=digest);
        let output=D.read_output loaded ~stream:P.Stdout ~offset:0L ~max_bytes:64 |> result_read in
        Alcotest.(check string) "original output survives request and observer cancellation" "original" output.data);
      Alcotest.(check string) "original launch happened once" "x" (read (Filename.concat fixture.work "ran"));
      Out_channel.with_open_bin (leaf fixture binding "stdout.bin") (fun oc -> output_string oc "changed!");
      check "a historical result digest cannot replace fresh output integrity"
        (Eio.Switch.run (fun reader -> Result.is_error (C.load_result ~sw:reader job))))))

let endpoint_cancel_observer_survives_busy_startup = fixture (fun ~env ~sw:_ ~store fixture ->
  let fifo=Filename.concat fixture.work "wait-input" in Unix.mkfifo fifo 0o666;Unix.chmod fifo 0o666;
  let fifo_fd=Unix.openfile fifo [Unix.O_RDWR;Unix.O_NONBLOCK;Unix.O_CLOEXEC] 0 in
  Fun.protect ~finally:(fun () -> Unix.close fifo_fd) (fun () -> Eio.Switch.run (fun endpoint ->
    let binding,permit=prepare store fixture "05" "read token < wait-input; printf unexpected" in
    let entered,signal=Eio.Promise.create () and resume,release=Eio.Promise.create () in
    let unblock ()=if Eio.Promise.peek resume=None then Eio.Promise.resolve release () in
    Fun.protect ~finally:unblock (fun () ->
      let job=held_owned_job ~sw:endpoint ~env fixture permit ~before_sync:(fun () ->
        Eio.Promise.resolve signal ();Eio.Promise.await resume) in
      Eio.Promise.await entered;
      let observing,observe=Eio.Promise.create () in
      Eio.Fiber.first
        (fun () -> Eio.Promise.resolve observe ();ignore (C.cancel job |> lifetime);
          Alcotest.fail "busy startup cancellation returned before startup settled")
        (fun () -> Eio.Promise.await observing;
          let _,next=prepare store fixture "07" "exit 8" in
          ignore (owned_job ~sw:endpoint ~env fixture next |> C.await_result |> lifetime));
      check "cancel observer left the original entered callback intact" (R.load store ~binding=Error R.Busy);
      unblock ();
      let _=C.await_result job |> lifetime in
      let cancelled=R.load store ~binding |> registry in
      check "cancelled observer did not abort the endpoint-owned original cancellation"
        (R.cancellation_state cancelled=R.Cancellation_requested);
      let repeated=C.cancel job |> lifetime in
      check "later explicit cancellation preserves the same admission and revision"
        (R.admission_id repeated=R.admission_id cancelled && R.revision repeated=R.revision cancelled)))))

let while_holding_lease fixture binding body =
  match File_lock_eio.try_with_liveness_lock_observed ~lock_path:(leaf fixture binding "lease") body with
  | File_lock_eio.Lock_attempted (File_lock_eio.Body_completed {value;release_error=None}) -> value
  | File_lock_eio.Lock_attempted (File_lock_eio.Body_completed {release_error=Some error;_}) ->
      Alcotest.fail (File_lock_eio.durable_lock_error_to_string error)
  | File_lock_eio.Lock_attempted (File_lock_eio.Lock_not_acquired _) | File_lock_eio.Lock_held_elsewhere ->
      Alcotest.fail "test could not hold the original job lease"

(* Another holder keeps the lease, so the startup and the cancellation both
   lose the registry. The cancellation is requested before the startup runs, so
   the startup sees it pending and waits for it. Nothing was recorded, so the
   startup must not turn that failed cancellation into a cancelled result. *)
let endpoint_failed_cancellation_is_not_a_cancelled_result = fixture (fun ~env ~sw:_ ~store fixture ->
  Eio.Switch.run (fun endpoint ->
    let binding,permit=prepare store fixture "05" "printf x >> ran; exit 0" in
    let job=ref None in
    let cancelled,result=while_holding_lease fixture binding (fun () ->
      let started=owned_job ~sw:endpoint ~env fixture permit in
      job:=Some started;
      let cancelled=C.cancel started in
      cancelled,C.await_result started) in
    let job=match !job with Some started -> started | None -> Alcotest.fail "job was not started" in
    check "cancellation fails while another holder keeps the lease" (cancelled=Error (C.Registry_error R.Busy));
    check "a cancellation that was never recorded produces no result" (Result.is_error result);
    check "the failed cancellation left no durable cancellation"
      (R.cancellation_state (R.load store ~binding |> registry)=R.No_cancellation);
    check "no unlaunched receipt was published"
      (not (Sys.file_exists (leaf fixture binding (R.evidence_leaf R.Terminal_receipt))));
    check "the payload never started" (not (Sys.file_exists (Filename.concat fixture.work "ran")));
    let repeated=C.cancel job |> lifetime in
    check "a later cancellation is recorded once the lease is free"
      (R.cancellation_state repeated=R.Cancellation_requested)))

let endpoint_teardown_resolves_unentered_reservation = fixture (fun ~env ~sw ~store fixture ->
  let binding,permit=prepare store fixture "05" ": > must-not-run" in
  let job=Eio.Switch.run (fun endpoint -> owned_job ~sw:endpoint ~env fixture permit) in
  check "normal endpoint shutdown resolves a worker that never entered"
    (C.await_result job=Error C.Owner_stopped);
  check "unentered endpoint reservation performed no payload effect"
    (not (Sys.file_exists (Filename.concat fixture.work "must-not-run")));
  let original=R.load store ~binding |> registry in
  ignore (R.request_cancel original ~confirmed_admission_id:(R.admission_id original) |> registry);
  let proof=R.retire_cancelled_launch ~sw permit |> registry in
  ignore (D.publish_unlaunched ~sw ~proof |> result_read))

let endpoint_prechild_cancellation_publishes_actual_absence = fixture (fun ~env ~sw:_ ~store fixture ->
  Eio.Switch.run (fun endpoint ->
    let binding,permit=prepare store fixture "05" ": > must-not-run" in
    let original=R.launch_record permit in
    let cancelled=R.request_cancel original ~confirmed_admission_id:(R.admission_id original) |> registry in
    let job=owned_job ~sw:endpoint ~env fixture permit in
    ignore (C.await_result job |> lifetime);
    Eio.Switch.run (fun reader ->
      let loaded=C.load_result ~sw:reader job |> lifetime in
      check "actual unused original permit supplies the no-child result"
        (match D.process loaded with
         | D.Not_created {launch_id=Some launch} -> launch=id "06"
         | Not_created {launch_id=None} | Child _ -> false));
    check "known launch cancellation never ran the original payload"
      (not (Sys.file_exists (Filename.concat fixture.work "must-not-run")));
    let repeated=C.cancel job |> lifetime in
    check "no-child cancellation keeps the original source and revision"
      (R.binding repeated=binding && R.revision repeated=R.revision cancelled)))

let endpoint_failed_job_does_not_fail_other_jobs = fixture (fun ~env ~sw:_ ~store fixture ->
  Eio.Switch.run (fun endpoint ->
    let _,permit=prepare ~mode:Exec_ssh_protocol.Observe store fixture "05" ": > refused" in
    let failed=owned_job ~sw:endpoint ~env fixture permit in
    check "unsupported boundary remains a failed job result" (Result.is_error (C.await_result failed));
    check "unsupported boundary never ran the payload" (not (Sys.file_exists (Filename.concat fixture.work "refused")));
    let _,next=prepare store fixture "07" "printf independent; exit 8" in
    let next=owned_job ~sw:endpoint ~env fixture next in
    ignore (C.await_result next |> lifetime);
    Eio.Switch.run (fun reader ->
      let loaded=C.load_result ~sw:reader next |> lifetime in
      let output=D.read_output loaded ~stream:P.Stdout ~offset:0L ~max_bytes:64 |> result_read in
      Alcotest.(check string) "another actual job completes after the first refusal" "independent" output.data)))

type lifetime_publication = Startup_rendezvous | Startup_activation | Cancellation_claim
exception Endpoint_interrupted
let endpoint_teardown_finishes_entered_publication boundary normal_teardown =
  fixture (fun ~env ~sw ~store fixture ->
    let cancelling=match boundary with Cancellation_claim -> true | Startup_rendezvous | Startup_activation -> false in
    let open_fifo name=
      let path=Filename.concat fixture.work name in Unix.mkfifo path 0o666;Unix.chmod path 0o666;
      Unix.openfile path [Unix.O_RDWR;Unix.O_NONBLOCK;Unix.O_CLOEXEC] 0 in
    let ready=if cancelling then Some (open_fifo "ready") else None in
    let input=if cancelling then Some (open_fifo "wait-input") else None in
    Fun.protect ~finally:(fun () -> Option.iter Unix.close ready;Option.iter Unix.close input) (fun () ->
      let script=if cancelling then "printf R > ready; read token < wait-input; : > must-not-run"
        else ": > must-not-run; exit 7" in
      let binding,permit=prepare store fixture "05" script in
      let path=match boundary with
        | Startup_rendezvous -> leaf fixture binding L.rendezvous_leaf
        | Startup_activation -> leaf fixture binding L.activation_leaf
        | Cancellation_claim -> Filename.concat fixture.registry_path (P.Id.to_string binding.operation_id ^ ".claim.json") in
      let group=Filename.concat "/sys/fs/cgroup" ("masc-job-" ^ P.Id.to_string (id "06")) in
      let entered,signal=Eio.Promise.create () and resume,release=Eio.Promise.create () in
      let teardown,begin_teardown=Eio.Promise.create () and cancelled,notice_cancel=Eio.Promise.create () in
      let created,provide_job=Eio.Promise.create () and drained,finish_scope=Eio.Promise.create () in
      let observer_reason=ref None in
      let unblock ()=if Eio.Promise.peek resume=None then Eio.Promise.resolve release () in
      let first=Atomic.make true in
      let fault=Recovery_test.before_parent_sync_dispatch ~before_sync:(fun () ->
        if Sys.file_exists path && Atomic.compare_and_set first true false then (
          Eio.Promise.resolve signal ();Eio.Promise.await resume)) in
      Fun.protect ~finally:unblock (fun () ->
        Eio.Fiber.fork ~sw (fun () ->
          let original_completion=match Eio.Switch.run (fun endpoint ->
            let job=if cancelling then owned_job ~sw:endpoint ~env fixture permit else
              Recovery_test.with_replace_dispatch_fault fault (fun () -> owned_job ~sw:endpoint ~env fixture permit) in
            Eio.Fiber.fork_daemon ~sw:endpoint (fun () ->
              try Eio.Fiber.await_cancel () with Eio.Cancel.Cancelled reason as ex ->
                Eio.Promise.resolve notice_cancel reason;raise ex);
            (match ready with
             | None -> Eio.Fiber.fork_daemon ~sw:endpoint (fun () ->
                 match C.await_result job with
                 | Ok _ | Error _ -> `Stop_daemon
                 | exception (Eio.Cancel.Cancelled reason as ex) -> observer_reason:=Some reason;raise ex)
             | Some fd ->
               Eio_unix.await_readable fd;
               let marker=Bytes.create 1 in
               Alcotest.(check int) "actual activated child sends its readiness byte" 1 (Unix.read fd marker 0 1);
               Alcotest.(check string) "native child reached its original blocking input" "R" (Bytes.to_string marker);
               Eio.Fiber.fork_daemon ~sw:endpoint (fun () ->
                 match Recovery_test.with_replace_dispatch_fault fault (fun () -> C.cancel job) with
                 | Ok _ | Error _ -> `Stop_daemon
                 | exception (Eio.Cancel.Cancelled reason as ex) -> observer_reason:=Some reason;raise ex));
            Eio.Promise.resolve provide_job job;
            Eio.Promise.await teardown;
            if not normal_teardown then Eio.Switch.fail endpoint Endpoint_interrupted) with
            | () -> normal_teardown
            | exception Endpoint_interrupted -> not normal_teardown in
          Eio.Promise.resolve finish_scope original_completion);
        Eio.Promise.await entered;
        let job=Eio.Promise.await created in
        check "real startup owns its native tree before metadata teardown" (Sys.file_exists group);
        let inode=(Unix.lstat path).st_ino and bytes=read path in
        Eio.Promise.resolve begin_teardown ();
        let original_reason=Eio.Promise.await cancelled in
        check "endpoint drain waits for the actual entered Fs transaction" (Eio.Promise.peek drained=None);
        check "entered startup or cancellation keeps its original EX authority"
          (R.load store ~binding=Error R.Busy);
        let _,next=prepare store fixture "07" "printf independent; exit 8" in
        ignore (Eio.Switch.run (fun independent -> owned_job ~sw:independent ~env fixture next |> C.await_result |> lifetime));
        unblock ();
        check "normal endpoint completion or explicit interruption survives metadata drain" (Eio.Promise.await drained);
        check "observer retains the original cancellation cause"
          (match !observer_reason with Some reason -> reason==original_reason | None -> false);
        check "original native group is quiescent and released after endpoint drain" (not (Sys.file_exists group));
        check "stopped lifetime cannot claim a terminal publication" (C.await_result job=Error C.Owner_stopped);
        Alcotest.(check int) "entered metadata retains its original published inode" inode (Unix.lstat path).st_ino;
        Alcotest.(check string) "entered metadata retains its exact published bytes" bytes (read path);
        check "pending cancellation never reaches another payload effect"
          (not (Sys.file_exists (Filename.concat fixture.work "must-not-run")));
        let current=R.load store ~binding |> registry in
        check "drained metadata preserves the same original admission and known launch"
          (R.binding current=binding && R.admission_id current=id "04" && R.launch_state current=R.Requested (id "06"));
        check "only an entered original cancellation publishes cancellation intent"
          ((R.cancellation_state current=R.Cancellation_requested)=cancelling);
        (match R.with_launch ~sw permit (fun _ ~storage:_ -> Alcotest.fail "stopped original launch callback replayed") with
         | R.Not_performed error -> check "endpoint teardown keeps its original permit spent or cancelled"
             (error=R.Launch_intent_spent || error=R.Launch_cancelled)
         | Performed _ -> Alcotest.fail "endpoint teardown made its original permit reusable")))) ()

let () =
  if G.For_testing.linux_build && Unix.geteuid ()<>0 && Sys.getenv_opt "GITHUB_ACTIONS"=Some "true" then (
    let executable=Unix.realpath Sys.executable_name in
    Unix.execvp "sudo" (Array.concat [[|"sudo";"-n";"--";executable|];Array.sub Sys.argv 1 (Array.length Sys.argv-1)]));
  let cases=if not G.For_testing.linux_build || Unix.geteuid ()<>0 then
      ["platform/controller refusal (kernel integration not run)",refusal;
       "digest package matches known SHA-256 values",digest_package_matches_known_sha256;
       "unavailable boundaries never fall back to workspace execution",unavailable_boundaries;
       "failed gate channel is written to the receipt",failed_gate_channel_is_written_to_the_receipt]
    else ["digest package matches known SHA-256 values",digest_package_matches_known_sha256;
      "durable original rendezvous before activation",durable_before_activation;
      "publication failure preserves paused owner without replay",publication_failure_retains_paused_owner;
      "busy original startup leaves another actual job executable",busy_startup_leaves_other_job_executable;
      "wait cancellation and original authority before tree kill",wait_and_cancel_require_original_authority;
      "unavailable boundaries never fall back to workspace execution",unavailable_boundaries;
      "failed gate channel is written to the receipt",failed_gate_channel_is_written_to_the_receipt;
      "complete binary output is durably sealed and not overwritten",complete_binary_output_is_durably_sealed;
      "output metadata queues by actual owner and survives waiter cancellation",output_metadata_waits_only_for_its_original_owner;
      "output observer cancellation preserves later original bytes",output_observer_cancel_preserves_capture_and_child;
      "growing read rejects missing claim before read",growing_range_read_revalidates_original `Before Missing_claim;
      "growing read rejects missing claim after read",growing_range_read_revalidates_original `After Missing_claim;
      "growing read rejects rebound known launch before read",growing_range_read_revalidates_original `Before Rebound_claim;
      "growing read rejects rebound known launch after read",growing_range_read_revalidates_original `After Rebound_claim;
      "growing read rejects canonical spool replacement before read",growing_range_read_revalidates_original `Before Replaced_spool;
      "growing read rejects canonical spool replacement after read",growing_range_read_revalidates_original `After Replaced_spool;
      "growing read accepts an append ahead of its extent",growing_range_read_observer_keeps_original_capture Append_ahead_of_extent;
      "growing read observer cancellation leaves the original alive",growing_range_read_observer_keeps_original_capture Cancel_read_observer;
      "growing read refuses capture failure during the read",growing_range_read_observer_keeps_original_capture Capture_fails_during_read;
      "failed seal stays unavailable while another job progresses",failed_seal_is_not_completion_and_does_not_block_other_job;
      "moved and replaced original spool never seals",output_attachment_change_never_seals `Move_and_replace;
      "symlink to detached original spool never seals",output_attachment_change_never_seals `Symlink_to_original;
      "multiply linked original spool never seals",output_attachment_change_never_seals `Extra_link;
      "changed original spool mode never seals",output_attachment_change_never_seals `Changed_file_mode;
      "changed original storage mode never seals",output_attachment_change_never_seals `Changed_storage_mode;
      "owner teardown settles external output observers",output_owner_teardown_settles_external_observers;
      "supervisor owns exact original stdin and both output sources",supervisor_owns_original_input_and_both_outputs;
      "supervisor settles input when the original child already exited",supervisor_early_exit_does_not_wait_on_stdin;
      "supervisor reports failed output before a blocked child exits",supervisor_reports_capture_failure_before_blocked_child_exit;
      "supervisor teardown settles external observers",supervisor_teardown_settles_external_observers;
      "owner teardown finishes entered metadata then preserves cancellation",output_owner_teardown_finishes_entered_metadata;
      "sealed output reopens after original owner exit and boot change",sealed_output_reopens_after_owner_exit_and_boot_change;
      "sealed output recovery rejects changed original evidence",sealed_output_reopen_rejects_changed_evidence;
      "hash observer cancellation preserves the complete original",sealed_output_hash_observer_cancellation_preserves_original;
      "hashing releases original lock and preserves cancel progress",sealed_output_hash_releases_lock_and_preserves_cancel_progress;
      "reopened range reads reject later canonical replacement",sealed_output_range_read_rejects_later_replacement;
      "seal atomic open rejects post-stat FIFO without a writer",sealed_output_atomic_open_rejects_raced_special_leaf `Seal `Fifo;
      "seal atomic open rejects post-stat symlink",sealed_output_atomic_open_rejects_raced_special_leaf `Seal `Symlink;
      "spool atomic open rejects post-stat FIFO without a writer",sealed_output_atomic_open_rejects_raced_special_leaf `Spool `Fifo;
      "spool atomic open rejects post-stat symlink",sealed_output_atomic_open_rejects_raced_special_leaf `Spool `Symlink;
      "failed result publication preserves raw settlement and other progress",result_publication_failure_preserves_raw_settlement;
      "result waits for cancellation during original observation",result_waits_for_original_cancel S.For_testing.Observe_original ~after_publication:false ~change_stdout:false;
      "result waits for cancellation during storage open",result_waits_for_original_cancel S.For_testing.Open_storage ~after_publication:false ~change_stdout:false;
      "result waits for cancellation during stdout reopen",result_waits_for_original_cancel S.For_testing.Reopen_stdout ~after_publication:false ~change_stdout:false;
      "result waits for cancellation during stderr reopen",result_waits_for_original_cancel S.For_testing.Reopen_stderr ~after_publication:false ~change_stdout:false;
      "result waits for cancellation during stdout validation",result_waits_for_original_cancel S.For_testing.Validate_stdout ~after_publication:false ~change_stdout:false;
      "result waits for cancellation during stderr validation after publication",result_waits_for_original_cancel S.For_testing.Validate_stderr ~after_publication:true ~change_stdout:false;
      "result waits for cancellation during post-publication refresh",result_waits_for_original_cancel S.For_testing.Refresh_after_publication ~after_publication:true ~change_stdout:false;
      "result rechecks stdout after stderr contention",result_waits_for_original_cancel S.For_testing.Validate_stderr ~after_publication:true ~change_stdout:true;
      "busy result observer cancellation and owner teardown",result_busy_observer_and_owner_cancellation;
      "result observer cancellation preserves frozen receipt and source progress",result_observer_cancel_and_source_progress_preserve_publication;
      "owner teardown settles external terminal result observers",result_owner_teardown_settles_external_observers;
      "pre-publish moved spool refuses readiness",result_readiness_requires_current_original_files `Before `Move_spool;
      "pre-publish truncated spool refuses readiness",result_readiness_requires_current_original_files `Before `Truncate_spool;
      "pre-publish deleted seal refuses readiness",result_readiness_requires_current_original_files `Before `Delete_seal;
      "pre-publish replaced seal refuses readiness",result_readiness_requires_current_original_files `Before `Replace_seal;
      "pre-publish self-consistent stream cannot replace actual cached seal",result_readiness_requires_current_original_files `Before `Rebind_stream;
      "post-publish moved spool refuses readiness",result_readiness_requires_current_original_files `After `Move_spool;
      "post-publish truncated spool refuses readiness",result_readiness_requires_current_original_files `After `Truncate_spool;
      "post-publish deleted seal refuses readiness",result_readiness_requires_current_original_files `After `Delete_seal;
      "post-publish replaced seal refuses readiness",result_readiness_requires_current_original_files `After `Replace_seal;
      "post-publish deleted receipt refuses readiness",result_readiness_requires_current_original_files `After `Delete_receipt;
      "post-publish replaced receipt refuses readiness",result_readiness_requires_current_original_files `After `Replace_receipt;
      "same-byte replacement streams are synchronized before result readiness",result_syncs_byte_identical_replacement_before_readiness;
      "same-byte spool file sync failure stays unavailable",replacement_output_sync_failure_never_seals `Spool Fs_compat.Owned_reader_for_testing.Sync_file;
      "same-byte spool parent sync failure stays unavailable",replacement_output_sync_failure_never_seals `Spool Fs_compat.Owned_reader_for_testing.Sync_parent;
      "same-byte seal file sync failure stays unavailable",replacement_output_sync_failure_never_seals `Seal Fs_compat.Owned_reader_for_testing.Sync_file;
      "same-byte seal parent sync failure stays unavailable",replacement_output_sync_failure_never_seals `Seal Fs_compat.Owned_reader_for_testing.Sync_parent;
      "terminal receipt reopens across owner exit and boot change",terminal_result_reopens_after_owner_exit_and_boot_change;
      "terminal reader rejects corrupt schema, checksum and original coordinates",terminal_result_strictly_rejects_corrupt_records;
      "missing terminal receipt or changed output never becomes empty completion",terminal_result_missing_data_never_becomes_empty;
      "terminal readiness rejects later byte-identical inode replacement",terminal_result_final_attachment_mutation_is_refused;
      "terminal reader cancellation and scope preserve the original",terminal_reader_cancel_and_scope_preserve_original;
      "held startup stops original and durably proves non-start",held_startup_is_stopped_and_durably_proves_nonstart;
      "native rejection differs from an actual payload exit127",native_exec_rejection_is_distinct_from_payload_exit127;
      "held cleanup preserves unavailable output instead of readiness",held_cleanup_cannot_hide_unavailable_output;
      "held cleanup missing original authority never signals",held_cleanup_missing_authority_does_not_signal;
      "held cancellation waits for a contended original lease",held_cancel_waits_for_a_contended_original;
      "held result observer cancellation preserves cleanup and publication",held_result_observer_cancel_preserves_cleanup_publication;
      "silent actual payload or raw exit cannot invent non-start",empty_output_or_bootstrap_code_cannot_invent_nonstart;
      "snapshot never waits for a blocked original process",snapshot_does_not_wait_for_a_blocked_original;
      "snapshot distinguishes pending physical settlement and original publication",snapshot_keeps_settlement_publication_and_current_source_distinct;
      "missing snapshot authority neither poisons nor cancels the original",snapshot_missing_authority_does_not_poison_or_cancel_original;
      "snapshot observer cancellation leaves original and other jobs alive",snapshot_observer_cancel_leaves_original_alive;
      "no-child results preserve original modes, domains and restart evidence",no_child_results_preserve_modes_domains_and_restart;
      "interrupted no-child publication reconciles original evidence",no_child_partial_publication_cancel_reconciles_original;
      "missing no-child sealed evidence never becomes a fresh empty spool",no_child_missing_sealed_evidence_never_recreates_empty_data;
      "no-child receipt rejects invented OS, gate and input facts",no_child_receipt_rejects_invented_process_facts;
      "late no-child file mutation never becomes readiness",no_child_final_mutation_never_becomes_readiness;
      "no-child authority refuses rebound storage before publication",no_child_original_authority_rejects_rebound_storage;
      "endpoint jobs survive request scopes and result observer cancellation",endpoint_lifetime_survives_request_and_result_observer;
      "endpoint cancellation survives its observer and waits only original startup",endpoint_cancel_observer_survives_busy_startup;
      "endpoint failed cancellation is never a cancelled result",endpoint_failed_cancellation_is_not_a_cancelled_result;
      "endpoint teardown resolves a never-entered job reservation",endpoint_teardown_resolves_unentered_reservation;
      "endpoint pre-child cancellation publishes only opaque original absence",endpoint_prechild_cancellation_publishes_actual_absence;
      "one refused endpoint job does not fail another",endpoint_failed_job_does_not_fail_other_jobs;
      "normal endpoint drain finishes entered startup rendezvous",(fun () -> endpoint_teardown_finishes_entered_publication Startup_rendezvous true);
      "explicit endpoint cancellation finishes entered startup rendezvous",(fun () -> endpoint_teardown_finishes_entered_publication Startup_rendezvous false);
      "normal endpoint drain finishes entered activation metadata",(fun () -> endpoint_teardown_finishes_entered_publication Startup_activation true);
      "explicit endpoint cancellation finishes entered activation metadata",(fun () -> endpoint_teardown_finishes_entered_publication Startup_activation false);
      "normal endpoint drain finishes entered cancellation claim",(fun () -> endpoint_teardown_finishes_entered_publication Cancellation_claim true);
      "explicit endpoint cancellation finishes entered cancellation claim",(fun () -> endpoint_teardown_finishes_entered_publication Cancellation_claim false)] in
  Alcotest.run "Endpoint job launch" ["original supervisor",List.map
    (fun (name,test) -> Alcotest.test_case name `Quick test) cases]
