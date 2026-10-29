module Owner = Endpoint_job_owner
module P = Endpoint_job_protocol
module R = Endpoint_job_registry
module L = Endpoint_job_launch
module D = Endpoint_job_result
module G = Endpoint_process_gate
module Recovery_test = Fs_compat_test_support.Publication_recovery_for_testing

let require = function Ok value -> value | Error error -> Alcotest.fail error
let owner value = value |> Result.map_error Owner.error_to_string |> require
let registry value = value |> Result.map_error R.error_to_string |> require
let result_read value = value |> Result.map_error D.error_to_string |> require
let check label value = Alcotest.(check bool) label true value
let id n = P.Id.of_string (Printf.sprintf "019a0000-0000-7000-8000-%012x" n) |> require
let digest value = P.Sha256.of_string Agent_core_sha256.(digest_string value |> to_hex) |> require
let route : P.route = {backend=Remote_ssh;endpoint_incarnation=id 1;boot_id=id 2}
let owner_identity : P.owner = {workspace_id=id 3;keeper_name="original owner"}

let rec remove path =
  match Unix.lstat path with
  | {Unix.st_kind=Unix.S_DIR;_} ->
      Array.iter (fun name -> remove (Filename.concat path name)) (Sys.readdir path);
      Unix.rmdir path
  | _ -> Unix.unlink path
  | exception Unix.Unix_error (Unix.ENOENT,_,_) -> ()

type fixture = {
  root : string;
  work : string;
  registry_path : string;
  execution : L.execution;
  uid : int;
  next_id : int ref;
}

let fresh fixture () =
  let value = !(fixture.next_id) in
  incr fixture.next_id;
  id value

let with_fixture f () =
  let root=Filename.temp_file "masc-endpoint-owner-" "" in
  Unix.unlink root;
  Unix.mkdir root 0o711;
  let work=Filename.concat root "work" and registry_path=Filename.concat root "registry" in
  Unix.mkdir work 0o700;
  Unix.mkdir registry_path 0o700;
  let account=Unix.getpwnam "nobody" in
  let uid=if account.pw_uid>0 && account.pw_uid<>Unix.geteuid () then account.pw_uid else Unix.geteuid ()+1 in
  let gid=max 0 account.pw_gid in
  if Unix.geteuid ()=0 then Unix.chown work uid gid;
  let execution : L.execution =
    {executable="/bin/sh";env=["PATH=/usr/bin:/bin";"EXPLICIT=original"];cwd=work;payload_gid=gid}
  in
  let fixture={root;work;registry_path;execution;uid;next_id=ref 1000000} in
  Fun.protect ~finally:(fun () -> remove root) (fun () ->
    Eio_main.run (fun env ->
      Eio.Time.with_timeout_exn env#clock 120. (fun () ->
        Eio.Switch.run (fun sw ->
          let store=R.open_registry ~sw ~fs:env#fs ~root_path:registry_path ~route
            ~owner:owner_identity ~payload_uid:uid |> registry in
          f ~env ~sw ~store fixture))))

let controller_with ~resolve_execution ~sw ~env fixture store =
  Owner.create ~sw ~fs:env#fs ~registry:store ~cgroup_parent_path:"/sys/fs/cgroup"
    ~new_id:(fresh fixture) ~resolve_execution

let controller ~sw ~env fixture store =
  controller_with ~resolve_execution:(fun _ -> Ok fixture.execution) ~sw ~env fixture store

let prepare ?(mode=Exec_ssh_protocol.Effect) ?(domain=P.Workspace_process) fixture n script =
  let spec=P.spec ~domain ~argv:["/bin/sh";"-c";script] ~env:["EXPLICIT","original"]
    ~cwd:fixture.work ~remote_root:fixture.work ~stdin:"" ~mode ~network_policy_sha256:None |> require in
  let binding=P.binding ~route ~owner:owner_identity ~operation_id:(id n)
    ~invocation_sha256:(digest (string_of_int n)) ~spec_sha256:(P.spec_sha256 spec) |> require in
  binding,spec

let claim_path fixture binding =
  Filename.concat fixture.registry_path (P.Id.to_string binding.P.operation_id ^ ".claim.json")

let job_leaf fixture binding evidence =
  Filename.concat
    (Filename.concat fixture.registry_path (P.Id.to_string binding.P.operation_id ^ ".job"))
    (R.evidence_leaf evidence)

let read path = In_channel.with_open_bin path In_channel.input_all
let read_if_exists path = if Sys.file_exists path then read path else ""

let assert_no_child digest loaded =
  check "loaded result binds the observed publication" (D.sha256 loaded=digest);
  (match D.process loaded with
   | D.Not_created {launch_id=None} -> ()
   | D.Not_created {launch_id=Some _} | D.Child _ ->
       Alcotest.fail "registration-only cancellation invented an OS child or launch");
  match D.inspect loaded |> result_read with
  | P.Status {phase=P.Not_started P.Cancelled_before_activation;cancel_requested=true;
      result=P.Result_ready ready;stdout=P.Sealed {byte_length=0L;_};
      stderr=P.Sealed {byte_length=0L;_};_} ->
      check "ready status binds the exact immutable receipt" (ready=digest)
  | P.Admitted _ | P.Status _ | P.Output _ | P.Released _ | P.Refused _ | P.Held _ ->
      Alcotest.fail "registration-only cancellation did not produce a complete non-start result"

let cancel_and_load ~sw operation =
  let request=Owner.cancel operation in
  Owner.await_request request |> owner;
  let digest=Owner.await_result operation |> owner in
  let loaded=Owner.load_result ~sw ~expected_sha256:(Some digest) operation |> owner in
  digest,loaded

let admission_lookup_and_binding_conflicts_share_only_exact_originals =
  with_fixture (fun ~env ~sw ~store fixture ->
    let controller=controller ~sw ~env fixture store in
    let binding,spec=prepare fixture 100 ": > must-not-run" in
    let first_promise,first_resolver=Eio.Promise.create () in
    Eio.Fiber.fork ~sw (fun () ->
      Eio.Promise.resolve first_resolver (Owner.admit controller ~binding ~spec));
    let second=Owner.admit controller ~binding ~spec |> owner in
    let first=Eio.Promise.await first_promise |> owner in
    let looked=Owner.lookup controller (Owner.original first) |> owner in
    check "concurrent admission and original lookup share one controller operation"
      (first==second && first==looked);
    let inspected=Owner.inspect_original first |> owner in
    check "inspection preserves the exact original coordinates"
      (R.binding inspected=binding && R.admission_id inspected=(Owner.original first).admission_id);
    let changed=P.binding ~route ~owner:owner_identity ~operation_id:binding.operation_id
      ~invocation_sha256:(digest "changed invocation") ~spec_sha256:(P.spec_sha256 spec) |> require in
    (match Owner.admit controller ~binding:changed ~spec with
     | Error (Owner.Registry_error R.Binding_mismatch | Owner.Binding_mismatch) -> ()
     | Ok _ -> Alcotest.fail "changed binding reused the original operation"
     | Error error -> Alcotest.fail (Owner.error_to_string error));
    (match Owner.lookup controller (P.original ~binding ~admission_id:(id 999998)) with
     | Error Owner.Admission_mismatch -> ()
     | Ok _ -> Alcotest.fail "a different admission ID adopted the original operation"
     | Error error -> Alcotest.fail (Owner.error_to_string error));
    let missing_binding,_=prepare fixture 999999 ": > missing" in
    let missing=P.original ~binding:missing_binding ~admission_id:(id 999997) in
    (match Owner.lookup controller missing with
     | Error (Owner.Registry_error (R.Missing_original | R.Lock_failed _ | R.Authority_unavailable _)) -> ()
     | Ok _ -> Alcotest.fail "missing lookup created a new admission"
     | Error error -> Alcotest.fail (Owner.error_to_string error));
    check "missing lookup leaves no original claim" (not (Sys.file_exists (claim_path fixture missing_binding)));
    check "lookup and conflicts never run the payload"
      (not (Sys.file_exists (Filename.concat fixture.work "must-not-run"))))

let duplicate_cancel_shares_request_and_registration_only_result =
  with_fixture (fun ~env ~sw ~store fixture ->
    let controller=controller ~sw ~env fixture store in
    let binding,spec=prepare fixture 200 ": > must-not-run" in
    let operation=Owner.admit controller ~binding ~spec |> owner in
    let first=Owner.cancel operation in
    let second=Owner.cancel operation in
    check "concurrent cancellation shares its original request" (first==second);
    Owner.await_request first |> owner;
    Owner.await_request second |> owner;
    let digest=Owner.await_result operation |> owner in
    let loaded=Owner.load_result ~sw ~expected_sha256:(Some digest) operation |> owner in
    assert_no_child digest loaded;
    check "duplicate cancellation does not run the payload"
      (not (Sys.file_exists (Filename.concat fixture.work "must-not-run")));
    Eio.Fiber.yield ();
    let path=claim_path fixture binding and evidence=claim_path fixture binding ^ ".evidence" in
    Unix.rename path evidence;
    Fun.protect ~finally:(fun () -> Unix.rename evidence path) (fun () ->
      let later=Owner.cancel operation in
      check "a later explicit cancel is a fresh revalidation" (later!=first);
      match Owner.await_request later with
      | Error (Owner.Registry_error _) -> ()
      | Ok () -> Alcotest.fail "later cancellation replayed cached success without original authority"
      | Error error -> Alcotest.fail (Owner.error_to_string error));
    check "failed later observation does not replace the retained result"
      (Owner.await_result operation=Ok digest))

let pending_cancellation_precedes_activation_and_publishes_no_child =
  with_fixture (fun ~env ~sw ~store fixture ->
    let resolutions=ref 0 in
    let controller=controller_with ~sw ~env fixture store ~resolve_execution:(fun _ ->
      incr resolutions;
      Ok fixture.execution) in
    let binding,spec=prepare fixture 300 ": > must-not-run" in
    let operation=Owner.admit controller ~binding ~spec |> owner in
    let activation=Owner.activate operation in
    let cancellation=Owner.cancel operation in
    Owner.await_request cancellation |> owner;
    (match Owner.await_request activation with
     | Error (Owner.Registry_error R.Launch_cancelled) -> ()
     | Ok () -> Alcotest.fail "pending activation defeated the original cancellation"
     | Error error -> Alcotest.fail (Owner.error_to_string error));
    let digest=Owner.await_result operation |> owner in
    let loaded=Owner.load_result ~sw ~expected_sha256:(Some digest) operation |> owner in
    assert_no_child digest loaded;
    check "pending cancellation wins before trusted execution resolution" (!resolutions=0);
    check "pending cancellation prevents launch intent"
      (R.launch_state (Owner.inspect_original operation |> owner)=R.Not_requested);
    check "pending cancellation prevents payload effects"
      (not (Sys.file_exists (Filename.concat fixture.work "must-not-run"))))

let activation_hold_is_visible_and_explicit_cancel_can_settle_result =
  with_fixture (fun ~env ~sw ~store fixture ->
    let resolutions=ref 0 in
    let controller=controller_with ~sw ~env fixture store ~resolve_execution:(fun _ ->
      incr resolutions;
      Error "policy unavailable") in
    let binding,spec=prepare ~mode:Exec_ssh_protocol.Observe fixture 400 ": > must-not-run" in
    let unsupported=Owner.admit controller ~binding ~spec |> owner in
    (match Owner.await_request (Owner.activate unsupported) with
     | Error (Owner.Launch_error L.Scope_unavailable) -> ()
     | Ok () -> Alcotest.fail "unsupported execution domain became active"
     | Error error -> Alcotest.fail (Owner.error_to_string error));
    (match Owner.await_result unsupported with
     | Error (Owner.Launch_error L.Scope_unavailable) -> ()
     | Ok _ -> Alcotest.fail "unsupported execution domain became a result"
     | Error error -> Alcotest.fail (Owner.error_to_string error));
    check "unsupported domain never reaches the resolver or launch" (!resolutions=0);
    check "unsupported domain leaves no launch intent"
      (R.launch_state (Owner.inspect_original unsupported |> owner)=R.Not_requested);
    let digest,loaded=cancel_and_load ~sw unsupported in
    assert_no_child digest loaded;
    let binding,spec=prepare fixture 401 ": > must-not-run" in
    let held=Owner.admit controller ~binding ~spec |> owner in
    let first=Owner.activate held in
    (match Owner.await_request first with
     | Error (Owner.Execution_unavailable "policy unavailable") -> ()
     | Ok () -> Alcotest.fail "unavailable trusted execution became active"
     | Error error -> Alcotest.fail (Owner.error_to_string error));
    (match Owner.await_result held with
     | Error (Owner.Execution_unavailable "policy unavailable") -> ()
     | Ok _ -> Alcotest.fail "execution hold became a terminal result"
     | Error error -> Alcotest.fail (Owner.error_to_string error));
    Eio.Fiber.yield ();
    check "activation hold has no implicit retry" (!resolutions=1);
    let second=Owner.activate held in
    check "a later explicit activation revalidates the hold" (second!=first);
    (match Owner.await_request second with
     | Error (Owner.Execution_unavailable "policy unavailable") -> ()
     | Ok () -> Alcotest.fail "the second activation hid the still unavailable policy"
     | Error error -> Alcotest.fail (Owner.error_to_string error));
    check "the second explicit activation actually revalidates" (!resolutions=2);
    let digest,loaded=cancel_and_load ~sw held in
    assert_no_child digest loaded)

let cold_known_launch_never_replays =
  with_fixture (fun ~env ~sw ~store fixture ->
    let binding,spec=prepare fixture 500 ": > must-not-run" in
    let admission_id=fresh fixture () in
    let record=R.admit store ~new_admission_id:admission_id ~binding ~spec |> registry in
    let launch_id=fresh fixture () in
    let _permit=R.commit_launch record ~confirmed_admission_id:admission_id ~launch_id |> registry in
    let controller=controller ~sw ~env fixture store in
    let operation=Owner.lookup controller (P.original ~binding ~admission_id) |> owner in
    check "cold known launch is immediately distinct from a live result"
      (Owner.await_result operation=Error Owner.Launch_unknown);
    (match Owner.await_request (Owner.activate operation) with
     | Error Owner.Launch_unknown -> ()
     | Ok () -> Alcotest.fail "cold known launch acquired a replacement native lifetime"
     | Error error -> Alcotest.fail (Owner.error_to_string error));
    (match Owner.load_result ~sw ~expected_sha256:None operation with
     | Error (Owner.Result_error _) | Error (Owner.Registry_error _) -> ()
     | Ok _ -> Alcotest.fail "cold known launch invented a stored result"
     | Error error -> Alcotest.fail (Owner.error_to_string error));
    check "cold activation preserves the original known launch"
      (R.launch_state (Owner.inspect_original operation |> owner)=R.Requested launch_id);
    check "cold activation never runs a replacement payload"
      (not (Sys.file_exists (Filename.concat fixture.work "must-not-run"))))

let observer_cancel_and_failed_activation_leave_independent_operations_serviceable =
  with_fixture (fun ~env ~sw ~store fixture ->
    let controller=controller_with ~sw ~env fixture store ~resolve_execution:(fun _ ->
      Error "policy unavailable") in
    let first_binding,first_spec=prepare fixture 600 ": > first-must-not-run" in
    let first=Owner.admit controller ~binding:first_binding ~spec:first_spec |> owner in
    let second_binding,second_spec=prepare fixture 601 ": > second-must-not-run" in
    let second=Owner.admit controller ~binding:second_binding ~spec:second_spec |> owner in
    let entered,signal=Eio.Promise.create () in
    let cancelled=ref false in
    Eio.Fiber.first
      (fun () ->
        try
          Eio.Promise.resolve signal ();
          ignore (Owner.await_result second |> owner);
          Alcotest.fail "pending result completed before an original control"
        with Eio.Cancel.Cancelled _ as ex -> cancelled:=true;raise ex)
      (fun () -> Eio.Promise.await entered);
    check "result observer cancellation reaches only the observer" !cancelled;
    (match Owner.await_request (Owner.activate first) with
     | Error (Owner.Execution_unavailable _) -> ()
     | Ok () -> Alcotest.fail "unavailable first execution became active"
     | Error error -> Alcotest.fail (Owner.error_to_string error));
    let second_digest,second_loaded=cancel_and_load ~sw second in
    assert_no_child second_digest second_loaded;
    let first_digest,first_loaded=cancel_and_load ~sw first in
    assert_no_child first_digest first_loaded;
    check "independent no-child results are not interchangeable" (first_digest<>second_digest))

let endpoint_teardown_settles_unentered_controls_and_result_observers =
  with_fixture (fun ~env ~sw:_ ~store fixture ->
    let binding,spec=prepare fixture 700 ": > must-not-run" in
    let operation,activation,cancellation=Eio.Switch.run (fun endpoint ->
      let controller=controller ~sw:endpoint ~env fixture store in
      let operation=Owner.admit controller ~binding ~spec |> owner in
      let activation=Owner.activate operation in
      let cancellation=Owner.cancel operation in
      operation,activation,cancellation) in
    check "unentered activation resolves at endpoint teardown"
      (Owner.await_request activation=Error Owner.Owner_stopped);
    check "unentered cancellation resolves at endpoint teardown"
      (Owner.await_request cancellation=Error Owner.Owner_stopped);
    check "unentered result observer resolves at endpoint teardown"
      (Owner.await_result operation=Error Owner.Owner_stopped);
    check "unentered endpoint controls never run the payload"
      (not (Sys.file_exists (Filename.concat fixture.work "must-not-run"))))

let three_hundred_registrations_keep_control_slots_bounded =
  with_fixture (fun ~env ~sw ~store fixture ->
    let controller=controller ~sw ~env fixture store in
    let completed=List.init 300 (fun index ->
      let n=10000+index in
      let binding,spec=prepare fixture n ": > must-not-run" in
      let operation=Owner.admit controller ~binding ~spec |> owner in
      let looked=Owner.lookup controller (Owner.original operation) |> owner in
      check "each logical cohort lookup shares its original" (looked==operation);
      let request=Owner.cancel operation in
      Owner.await_request request |> owner;
      let digest=Owner.await_result operation |> owner in
      operation,binding,digest) in
    List.iter (fun (operation,binding,digest) ->
      check "logical cohort retains its exact original binding" ((Owner.original operation).binding=binding);
      check "logical cohort retains its exact result digest" (Owner.await_result operation=Ok digest)) completed;
    check "three hundred no-child operations never run their payload"
      (not (Sys.file_exists (Filename.concat fixture.work "must-not-run"))))

let assert_cancelled_result digest loaded =
  match D.inspect loaded |> result_read with
  | P.Status {cancel_requested=true;result=P.Result_ready ready;_} ->
      check "cancelled result binds the exact receipt" (ready=digest && D.sha256 loaded=digest)
  | P.Admitted _ | P.Status _ | P.Output _ | P.Released _ | P.Refused _ | P.Held _ ->
      Alcotest.fail "cancelled original did not produce a complete exact result"

let duplicate_activation_runs_one_original_and_shares_exact_result =
  with_fixture (fun ~env ~sw ~store fixture ->
    let controller=controller ~sw ~env fixture store in
    let binding,spec=prepare fixture 800 "printf x >> ran; printf original; exit 7" in
    let operation=Owner.admit controller ~binding ~spec |> owner in
    let first=Owner.activate operation in
    let second=Owner.activate operation in
    check "duplicate activation shares its original request" (first==second);
    Owner.await_request first |> owner;
    Owner.await_request second |> owner;
    let first_digest=Owner.await_result operation |> owner in
    let second_digest=Owner.await_result operation |> owner in
    check "duplicate result observers share one digest" (first_digest=second_digest);
    let loaded=Owner.load_result ~sw ~expected_sha256:(Some first_digest) operation |> owner in
    (match D.inspect loaded |> result_read with
     | P.Status {phase=P.Termination_observed (P.Exited 7);result=P.Result_ready ready;_} ->
         check "native result binds its exact physical observation" (ready=first_digest)
     | P.Admitted _ | P.Status _ | P.Output _ | P.Released _ | P.Refused _ | P.Held _ ->
         Alcotest.fail "native result did not retain the original exit");
    let output=D.read_output loaded ~stream:P.Stdout ~offset:0L ~max_bytes:64 |> result_read in
    Alcotest.(check string) "duplicate activation retains original output" "original" output.data;
    Alcotest.(check string) "original payload ran exactly once" "x" (read (Filename.concat fixture.work "ran"));
    Owner.await_request (Owner.activate operation) |> owner;
    Alcotest.(check string) "later activation revalidates without replay" "x"
      (read (Filename.concat fixture.work "ran"));
    (match Owner.load_result ~sw ~expected_sha256:(Some (digest "wrong host digest")) operation with
     | Error Owner.Result_digest_mismatch -> ()
     | Ok _ -> Alcotest.fail "a host digest substituted another original result"
     | Error error -> Alcotest.fail (Owner.error_to_string error));
    let reloaded=Owner.load_result ~sw ~expected_sha256:(Some first_digest) operation |> owner in
    check "the original result remains readable after digest refusal" (D.sha256 reloaded=first_digest))

let blocked_original_does_not_head_of_line_block_another =
  with_fixture (fun ~env ~sw ~store fixture ->
    let open_fifo name =
      let path=Filename.concat fixture.work name in
      Unix.mkfifo path 0o666;
      Unix.chmod path 0o666;
      Unix.openfile path [Unix.O_RDWR;Unix.O_NONBLOCK;Unix.O_CLOEXEC] 0
    in
    let ready=open_fifo "ready" and input=open_fifo "wait-input" in
    Fun.protect ~finally:(fun () -> List.iter Unix.close [ready;input]) (fun () ->
      let controller=controller ~sw ~env fixture store in
      let first_binding,first_spec=prepare fixture 810
        "printf R > ready; read token < wait-input; printf unexpected > first-ran; exec /bin/cat" in
      let first=Owner.admit controller ~binding:first_binding ~spec:first_spec |> owner in
      Owner.await_request (Owner.activate first) |> owner;
      Eio_unix.await_readable ready;
      let ready_byte=Bytes.create 1 in
      let read_ready=Eio_unix.run_in_systhread (fun () -> Unix.read ready ready_byte 0 1) in
      check "first original actually reached its blocking input" (read_ready=1 && Bytes.to_string ready_byte="R");
      let second_binding,second_spec=prepare fixture 811 "printf independent; exit 8" in
      let second=Owner.admit controller ~binding:second_binding ~spec:second_spec |> owner in
      Owner.await_request (Owner.activate second) |> owner;
      let second_digest=Owner.await_result second |> owner in
      let second_loaded=Owner.load_result ~sw ~expected_sha256:(Some second_digest) second |> owner in
      let second_output=D.read_output second_loaded ~stream:P.Stdout ~offset:0L ~max_bytes:64 |> result_read in
      Alcotest.(check string) "another original completes while the first is blocked" "independent" second_output.data;
      check "blocked original did not run past its input" (not (Sys.file_exists (Filename.concat fixture.work "first-ran")));
      let entered,signal=Eio.Promise.create () in
      let cancelled=ref false in
      Eio.Fiber.first
        (fun () ->
          try
            Eio.Promise.resolve signal ();
            ignore (Owner.await_result first |> owner);
            Alcotest.fail "blocked original completed before cancellation"
          with Eio.Cancel.Cancelled _ as ex -> cancelled:=true;raise ex)
        (fun () -> Eio.Promise.await entered);
      check "blocked result observer cancellation leaves the original alive" !cancelled;
      Owner.await_request (Owner.cancel first) |> owner;
      let first_digest=Owner.await_result first |> owner in
      let first_loaded=Owner.load_result ~sw ~expected_sha256:(Some first_digest) first |> owner in
      assert_cancelled_result first_digest first_loaded;
      (match D.process first_loaded with
       | D.Child _ -> ()
       | D.Not_created _ -> Alcotest.fail "a payload that reported readiness was erased from the receipt");
      check "cancelled blocked original never ran past its input"
        (not (Sys.file_exists (Filename.concat fixture.work "first-ran")))))

let cancel_during_original_startup_never_replays_or_signals_a_replacement =
  with_fixture (fun ~env ~sw ~store fixture ->
    let controller=controller ~sw ~env fixture store in
    let binding,spec=prepare fixture 820 "printf x >> startup-ran; exec /bin/cat" in
    let operation=Owner.admit controller ~binding ~spec |> owner in
    Owner.await_request (Owner.activate operation) |> owner;
    Owner.await_request (Owner.cancel operation) |> owner;
    let digest=match Owner.await_result operation with
      | Ok digest -> digest
      | Error (Owner.Lifetime_error _ as error) -> Alcotest.failf "lifetime: %s" (Owner.error_to_string error)
      | Error (Owner.Registry_error _ as error) -> Alcotest.failf "owner registry: %s" (Owner.error_to_string error)
      | Error (Owner.Result_error _ as error) -> Alcotest.failf "result load: %s" (Owner.error_to_string error)
      | Error error -> Alcotest.fail (Owner.error_to_string error)
    in
    let loaded=Owner.load_result ~sw ~expected_sha256:(Some digest) operation |> owner in
    assert_cancelled_result digest loaded;
    let record=Owner.inspect_original operation |> owner in
    let launch_id=match R.launch_state record with
      | R.Requested launch_id -> launch_id
      | R.Not_requested -> Alcotest.fail "accepted activation lost its original launch intent"
    in
    check "startup cancellation retains intent and exact launch"
      (R.cancellation_state record=R.Cancellation_requested);
    (match D.process loaded with
     | D.Not_created {launch_id=Some actual} -> check "proven non-start retains the original launch" (actual=launch_id)
     | D.Not_created {launch_id=None} -> Alcotest.fail "accepted activation became an unlaunched registration"
     | D.Child child -> check "physical result retains the original launch" (child.launch_id=launch_id));
    let runs=read_if_exists (Filename.concat fixture.work "startup-ran") in
    check "startup cancellation never duplicates the payload" (runs="" || runs="x");
    Owner.await_request (Owner.activate operation) |> owner;
    Alcotest.(check string) "later activation cannot replay the cancelled original" runs
      (read_if_exists (Filename.concat fixture.work "startup-ran")))

let cold_result_read_does_not_restore_launch_authority =
  with_fixture (fun ~env ~sw ~store:_ fixture ->
    let binding,spec=prepare fixture 830 "printf x >> cold-ran; printf original; exit 7" in
    let operation,digest,launch_id=Eio.Switch.run (fun endpoint ->
      let store=R.open_registry ~sw:endpoint ~fs:env#fs ~root_path:fixture.registry_path ~route
        ~owner:owner_identity ~payload_uid:fixture.uid |> registry in
      let controller=controller ~sw:endpoint ~env fixture store in
      let operation=Owner.admit controller ~binding ~spec |> owner in
      Owner.await_request (Owner.activate operation) |> owner;
      let digest=Owner.await_result operation |> owner in
      let launch_id=match R.launch_state (Owner.inspect_original operation |> owner) with
        | R.Requested launch_id -> launch_id
        | R.Not_requested -> Alcotest.fail "native activation lost its launch before cold recovery"
      in
      operation,digest,launch_id) in
    Eio.Switch.run (fun cold_sw ->
      let rebooted_route={route with boot_id=id 900} in
      let store=R.open_registry ~sw:cold_sw ~fs:env#fs ~root_path:fixture.registry_path
        ~route:rebooted_route ~owner:owner_identity ~payload_uid:fixture.uid |> registry in
      let controller=controller ~sw:cold_sw ~env fixture store in
      let cold=Owner.lookup controller (Owner.original operation) |> owner in
      check "cold known launch has no invented live future" (Owner.await_result cold=Error Owner.Launch_unknown);
      (match Owner.await_request (Owner.activate cold) with
       | Error Owner.Launch_unknown -> ()
       | Ok () -> Alcotest.fail "cold result read restored launch authority"
       | Error error -> Alcotest.fail (Owner.error_to_string error));
      let loaded=Owner.load_result ~sw:cold_sw ~expected_sha256:None cold |> owner in
      check "cold read binds the original durable result" (D.sha256 loaded=digest);
      let output=D.read_output loaded ~stream:P.Stdout ~offset:0L ~max_bytes:64 |> result_read in
      Alcotest.(check string) "cold read returns the exact original output" "original" output.data;
      (match D.process loaded with
       | D.Child child -> check "cold read retains the original launch" (child.launch_id=launch_id)
       | D.Not_created _ -> Alcotest.fail "completed native output became a no-child result");
      (match Owner.await_request (Owner.cancel cold) with
       | Error (Owner.Registry_error R.Endpoint_replaced) -> ()
       | Ok () -> Alcotest.fail "replaced endpoint granted a new cancellation effect"
       | Error error -> Alcotest.fail (Owner.error_to_string error));
      check "cold controls never replay or signal a replacement"
        (read (Filename.concat fixture.work "cold-ran")="x");
      check "cold inspection preserves the original known launch"
        (R.launch_state (Owner.inspect_original cold |> owner)=R.Requested launch_id)))

let failed_native_owner_does_not_fail_other_controller_operations =
  with_fixture (fun ~env ~sw ~store fixture ->
    let controller=controller ~sw ~env fixture store in
    let first_binding,first_spec=prepare fixture 840 "printf original; exit 0" in
    let first=Owner.admit controller ~binding:first_binding ~spec:first_spec |> owner in
    let receipt=job_leaf fixture first_binding R.Terminal_receipt in
    Out_channel.with_open_bin receipt (fun channel -> output_string channel "conflicting original result");
    Unix.chmod receipt 0o400;
    Owner.await_request (Owner.activate first) |> owner;
    (match Owner.await_result first with
     | Error (Owner.Lifetime_error _ | Owner.Result_error _ | Owner.Registry_error _) -> ()
     | Ok _ -> Alcotest.fail "conflicting native result publication became readiness"
     | Error error -> Alcotest.fail (Owner.error_to_string error));
    Alcotest.(check string) "failed publication preserves conflicting evidence" "conflicting original result" (read receipt);
    Alcotest.(check string) "failed publication still ran and captured the actual original" "original"
      (read (job_leaf fixture first_binding (R.Stream_data P.Stdout)));
    let second_binding,second_spec=prepare fixture 841 "printf independent; exit 8" in
    let second=Owner.admit controller ~binding:second_binding ~spec:second_spec |> owner in
    Owner.await_request (Owner.activate second) |> owner;
    let digest=Owner.await_result second |> owner in
    let loaded=Owner.load_result ~sw ~expected_sha256:(Some digest) second |> owner in
    let output=D.read_output loaded ~stream:P.Stdout ~offset:0L ~max_bytes:64 |> result_read in
    Alcotest.(check string) "failed original does not poison another operation" "independent" output.data)

let queued_cancel_after_activation_hold_gets_new_result_generation =
  with_fixture (fun ~env ~sw ~store fixture ->
    let entered,signal=Eio.Promise.create () and resume,release=Eio.Promise.create () in
    let unblock ()=if Eio.Promise.peek resume=None then Eio.Promise.resolve release () in
    let controller=controller_with ~sw ~env fixture store ~resolve_execution:(fun _ ->
      Eio.Promise.resolve signal ();
      Eio.Promise.await resume;
      Error "policy unavailable") in
    let binding,spec=prepare fixture 850 ": > must-not-run" in
    let operation=Owner.admit controller ~binding ~spec |> owner in
    Fun.protect ~finally:unblock (fun () ->
      let activation=Owner.activate operation in
      Eio.Promise.await entered;
      let cancellation=Owner.cancel operation in
      unblock ();
      (match Owner.await_request activation with
       | Error (Owner.Execution_unavailable "policy unavailable") -> ()
       | Ok () -> Alcotest.fail "blocked resolver unexpectedly activated"
       | Error error -> Alcotest.fail (Owner.error_to_string error));
      Owner.await_request cancellation |> owner;
      let digest=Owner.await_result operation |> owner in
      let loaded=Owner.load_result ~sw ~expected_sha256:(Some digest) operation |> owner in
      assert_no_child digest loaded))

exception Injected_admission_failure

let conflicting_pending_admission fail_initial =
  with_fixture (fun ~env ~sw ~store fixture ->
    let controller=controller ~sw ~env fixture store in
    let binding,spec=prepare fixture 860 ": > must-not-run" in
    let changed=P.binding ~route ~owner:owner_identity ~operation_id:binding.operation_id
      ~invocation_sha256:(digest "conflicting invocation") ~spec_sha256:(P.spec_sha256 spec) |> require in
    let entered,signal=Eio.Promise.create () and resume,release=Eio.Promise.create () in
    let unblock ()=if Eio.Promise.peek resume=None then Eio.Promise.resolve release () in
    let first=Atomic.make true in
    let fault=Recovery_test.before_parent_sync_dispatch ~before_sync:(fun () ->
      if Atomic.compare_and_set first true false then (
        Eio.Promise.resolve signal ();
        Eio.Promise.await resume;
        if fail_initial then raise Injected_admission_failure)) in
    let initial,initial_resolver=Eio.Promise.create () in
    Eio.Fiber.fork ~sw (fun () ->
      let outcome=Recovery_test.with_replace_dispatch_fault fault (fun () ->
        try Owner.admit controller ~binding ~spec with
        | Injected_admission_failure as error -> Error (Owner.Controller_failed error)) in
      Eio.Promise.resolve initial_resolver outcome);
    Eio.Promise.await entered;
    Fun.protect ~finally:unblock (fun () ->
      let conflict,conflict_resolver=Eio.Promise.create () in
      Eio.Fiber.fork ~sw (fun () ->
        Eio.Promise.resolve conflict_resolver (Owner.admit controller ~binding:changed ~spec));
      let lookup,lookup_resolver=Eio.Promise.create () in
      Eio.Fiber.fork ~sw (fun () ->
        Eio.Promise.resolve lookup_resolver
          (Owner.lookup controller (P.original ~binding:changed ~admission_id:(id 999999))));
      Eio.Fiber.yield ();
      let expect_immediate label promise =
        match Eio.Promise.peek promise with
        | Some (Error (Owner.Binding_mismatch | Owner.Registry_error R.Binding_mismatch)) -> ()
        | Some (Ok _) -> Alcotest.fail (label ^ " adopted a conflicting original")
        | Some (Error error) -> Alcotest.fail (label ^ ": " ^ Owner.error_to_string error)
        | None -> Alcotest.fail (label ^ " joined the pending admission instead of rejecting its conflict")
      in
      expect_immediate "conflicting admission" conflict;
      expect_immediate "conflicting lookup" lookup;
      unblock ();
      let initial_outcome=Eio.Promise.await initial in
      if fail_initial then
        (match initial_outcome with
         | Error (Owner.Controller_failed Injected_admission_failure | Owner.Registry_error (R.Publication_failed _)) -> ()
         | Ok _ -> Alcotest.fail "injected admission failure became success"
         | Error error -> Alcotest.fail (Owner.error_to_string error))
      else
        let operation=owner initial_outcome in
        let looked=Owner.lookup controller (Owner.original operation) |> owner in
        check "exact original remains serviceable after conflicting pending attempts" (looked==operation)))

let conflicting_pending_admissions_do_not_join_or_contaminate () =
  List.iter (fun fail_initial -> conflicting_pending_admission fail_initial ()) [false;true]

let second_activation_during_native_startup_preserves_original_result =
  with_fixture (fun ~env ~sw ~store fixture ->
    let controller=controller ~sw ~env fixture store in
    let binding,spec=prepare fixture 870 "printf original; exit 7" in
    let rendezvous=Filename.concat
      (Filename.concat fixture.registry_path (P.Id.to_string binding.P.operation_id ^ ".job"))
      L.rendezvous_leaf in
    let entered,signal=Eio.Promise.create () and resume,release=Eio.Promise.create () in
    let unblock ()=if Eio.Promise.peek resume=None then Eio.Promise.resolve release () in
    let first=Atomic.make true in
    let fault=Recovery_test.before_parent_sync_dispatch ~before_sync:(fun () ->
      if Sys.file_exists rendezvous && Atomic.compare_and_set first true false then (
        Eio.Promise.resolve signal ();
        Eio.Promise.await resume)) in
    Fun.protect ~finally:unblock (fun () ->
      Recovery_test.with_replace_dispatch_fault fault (fun () ->
        let operation=Owner.admit controller ~binding ~spec |> owner in
        Owner.await_request (Owner.activate operation) |> owner;
        Eio.Promise.await entered;
        (match Owner.await_request (Owner.activate operation) with
         | Error (Owner.Registry_error R.Busy) -> ()
         | Ok () -> Alcotest.fail "second activation did not observe the held original startup"
         | Error error -> Alcotest.fail (Owner.error_to_string error));
        unblock ();
        let digest=Owner.await_result operation |> owner in
        let loaded=Owner.load_result ~sw ~expected_sha256:(Some digest) operation |> owner in
        let output=D.read_output loaded ~stream:P.Stdout ~offset:0L ~max_bytes:64 |> result_read in
        Alcotest.(check string) "second activation error cannot replace the original result" "original" output.data)))

let native_publication_failure_remains_observable_after_revalidation =
  with_fixture (fun ~env ~sw ~store fixture ->
    let controller=controller ~sw ~env fixture store in
    let binding,spec=prepare fixture 880 "printf original; exit 0" in
    let operation=Owner.admit controller ~binding ~spec |> owner in
    let receipt=job_leaf fixture binding R.Terminal_receipt in
    Out_channel.with_open_bin receipt (fun channel -> output_string channel "conflicting original result");
    Unix.chmod receipt 0o400;
    Owner.await_request (Owner.activate operation) |> owner;
    (match Owner.await_result operation with
     | Error (Owner.Lifetime_error _ | Owner.Result_error _ | Owner.Registry_error _) -> ()
     | Ok _ -> Alcotest.fail "conflicting native publication became readiness"
     | Error error -> Alcotest.fail (Owner.error_to_string error));
    Owner.await_request (Owner.activate operation) |> owner;
    let waiting,notice=Eio.Promise.create () in
    Eio.Fiber.fork ~sw (fun () -> Eio.Promise.resolve notice (Owner.await_result operation));
    Eio.Fiber.yield ();
    (match Eio.Promise.peek waiting with
     | Some (Error (Owner.Lifetime_error _ | Owner.Result_error _ | Owner.Registry_error _)) -> ()
     | Some (Ok _) -> Alcotest.fail "native publication failure became a replacement result"
     | Some (Error error) -> Alcotest.fail (Owner.error_to_string error)
     | None -> Alcotest.fail "native publication failure was reset to an unobservable pending future");
    Alcotest.(check string) "native publication failure preserves original evidence" "conflicting original result" (read receipt))

let portable_cases=[
  "admission lookup and binding conflicts",admission_lookup_and_binding_conflicts_share_only_exact_originals;
  "duplicate cancel and registration-only result",duplicate_cancel_shares_request_and_registration_only_result;
  "pending cancellation precedes activation",pending_cancellation_precedes_activation_and_publishes_no_child;
  "activation hold and explicit later result",activation_hold_is_visible_and_explicit_cancel_can_settle_result;
  "cold known launch never replays",cold_known_launch_never_replays;
  "observer cancellation and independent progress",observer_cancel_and_failed_activation_leave_independent_operations_serviceable;
  "endpoint teardown settles unentered observers",endpoint_teardown_settles_unentered_controls_and_result_observers;
  "three hundred logical original operations",three_hundred_registrations_keep_control_slots_bounded;
  "queued cancellation gets a fresh result generation",queued_cancel_after_activation_hold_gets_new_result_generation;
  "conflicting pending admissions do not join",conflicting_pending_admissions_do_not_join_or_contaminate;
]

let native_cases=[
  "duplicate activation runs one original",duplicate_activation_runs_one_original_and_shares_exact_result;
  "blocked original does not block another",blocked_original_does_not_head_of_line_block_another;
  "startup cancellation preserves original launch",cancel_during_original_startup_never_replays_or_signals_a_replacement;
  "cold result read preserves no-launch authority",cold_result_read_does_not_restore_launch_authority;
  "failed native owner leaves another healthy",failed_native_owner_does_not_fail_other_controller_operations;
  "second activation preserves native result",second_activation_during_native_startup_preserves_original_result;
  "native publication failure remains observable",native_publication_failure_remains_observable_after_revalidation;
]

let () =
  let native=if G.For_testing.linux_build && Unix.geteuid ()=0 then native_cases else [] in
  Alcotest.run "Endpoint job owner"
    ["original controller",List.map (fun (name,test) -> Alcotest.test_case name `Quick test) (portable_cases @ native)]

