module Owner = Endpoint_job_owner
module P = Endpoint_job_protocol
module R = Endpoint_job_registry
module L = Endpoint_job_launch
module D = Endpoint_job_result
module G = Endpoint_process_gate
module S = Endpoint_job_supervisor
module C = Endpoint_job_lifetime
module Recovery_test = Fs_compat_test_support.Publication_recovery_for_testing

let require = function Ok value -> value | Error error -> Alcotest.fail error
let owner value = value |> Result.map_error Owner.error_to_string |> require
let registry value = value |> Result.map_error R.error_to_string |> require
let result_read value = value |> Result.map_error D.error_to_string |> require
let await_native_startup operation =
  let outcome=match Owner.For_testing.await_startup operation with
    | Some outcome -> owner outcome
    | None -> Alcotest.fail "native lifetime was not reserved"
  in
  match outcome with
  | S.Not_performed {error;pipe_cleanup_errors=_} -> Alcotest.fail (S.error_to_string error)
  | S.Performed {value;registry_release_error;pipe_cleanup_errors} ->
      (match registry_release_error with
       | None -> ()
       | Some _ -> Alcotest.fail "native startup did not release original registry authority");
      (match pipe_cleanup_errors with
       | [] -> ()
       | _::_ -> Alcotest.fail "native startup did not close its unused pipe ends");
      let native=value |> Result.map_error S.error_to_string |> require in
      S.availability native |> Result.map_error S.error_to_string |> require
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
      check "cold snapshot does not invent live ownership"
        ((Owner.snapshot cold |> owner).progress=Owner.Ownership_unknown);
      let discovered=Owner.read_output ~sw:cold_sw cold ~stream:P.Stdout ~offset:0L ~max_bytes:64 |> owner in
      (match discovered with
       | Some chunk -> Alcotest.(check string) "cold output discovery reads actual original bytes" "original" chunk.data
       | None -> Alcotest.fail "retained cold output was replaced by pending");
      check "cold output discovery does not adopt a live lifetime"
        ((Owner.snapshot cold |> owner).progress=Owner.Ownership_unknown);
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

exception Injected_controller_failure

let request_exception_does_not_poison_later_original_controls =
  with_fixture (fun ~env ~sw ~store fixture ->
    let resolutions=ref 0 in
    let controller=controller_with ~sw ~env fixture store ~resolve_execution:(fun _ ->
      incr resolutions;
      raise Injected_controller_failure) in
    let binding,spec=prepare fixture 900 ": > must-not-run" in
    let operation=Owner.admit controller ~binding ~spec |> owner in
    (match Owner.await_request (Owner.activate operation) with
     | Error (Owner.Controller_failed Injected_controller_failure) -> ()
     | Ok () -> Alcotest.fail "a resolver exception became activation success"
     | Error error -> Alcotest.fail (Owner.error_to_string error));
    (match Owner.await_result operation with
     | Error (Owner.Controller_failed Injected_controller_failure) -> ()
     | Ok _ -> Alcotest.fail "a resolver exception became a job result"
     | Error error -> Alcotest.fail (Owner.error_to_string error));
    let original=Owner.original operation in
    let digest,loaded=cancel_and_load ~sw operation in
    assert_no_child digest loaded;
    check "later cancellation keeps the same captured original" (Owner.original operation=original);
    check "cancellation never reruns the failed resolver" (!resolutions=1);
    check "resolver failure never launched the payload"
      (not (Sys.file_exists (Filename.concat fixture.work "must-not-run")));
    let other_binding,other_spec=prepare fixture 901 ": > other-must-not-run" in
    let other=Owner.admit controller ~binding:other_binding ~spec:other_spec |> owner in
    let digest,loaded=cancel_and_load ~sw other in
    assert_no_child digest loaded)

let failed_actor_resumes_only_an_explicit_new_control =
  with_fixture (fun ~env ~sw ~store fixture ->
    let entered=ref 0 and fail_next=ref true in
    let controller=Owner.For_testing.create ~sw ~fs:env#fs ~registry:store
      ~after_commit:(fun () -> ())
      ~cgroup_parent_path:"/sys/fs/cgroup" ~new_id:(fresh fixture)
      ~resolve_execution:(fun _ -> Alcotest.fail "cancelled original resolved execution")
      ~before_request:(fun () ->
        incr entered;
        if !fail_next then (fail_next:=false;raise Injected_controller_failure)) in
    let binding,spec=prepare fixture 902 ": > must-not-run" in
    let operation=Owner.admit controller ~binding ~spec |> owner in
    let original=Owner.original operation in
    let activation=Owner.activate operation in
    let cancellation=Owner.cancel operation in
    List.iter (fun request -> match Owner.await_request request with
      | Error (Owner.Controller_failed Injected_controller_failure) -> ()
      | Ok () -> Alcotest.fail "actor failure replayed or accepted an unentered control"
      | Error error -> Alcotest.fail (Owner.error_to_string error)) [activation;cancellation];
    let looked=Owner.lookup controller original |> owner in
    check "lookup retains the failed original object" (looked==operation);
    check "lookup never restarts the failed controls" (!entered=1);
    let digest,loaded=cancel_and_load ~sw operation in
    assert_no_child digest loaded;
    check "only the later explicit control ran" (!entered=2);
    check "recovery keeps original admission" (Owner.original operation=original);
    check "old failed tickets retain their outcome"
      (Owner.await_request activation=Error (Owner.Controller_failed Injected_controller_failure));
    check "recovery does not launch the cancelled original"
      (not (Sys.file_exists (Filename.concat fixture.work "must-not-run"))))

let failed_actor_keeps_native_cancellation_and_historical_result =
  with_fixture (fun ~env ~sw ~store fixture ->
    let open_fifo name =
      let path=Filename.concat fixture.work name in
      Unix.mkfifo path 0o666;
      Unix.chmod path 0o666;
      Unix.openfile path [Unix.O_RDWR;Unix.O_NONBLOCK;Unix.O_CLOEXEC] 0
    in
    let ready=open_fifo "recovery-ready" and input=open_fifo "recovery-input" in
    Fun.protect ~finally:(fun () -> List.iter Unix.close [ready;input]) (fun () ->
      let operation,digest=Eio.Switch.run (fun endpoint ->
        let fail_next=ref false and resolutions=ref 0 in
        let controller=Owner.For_testing.create ~sw:endpoint ~fs:env#fs ~registry:store
          ~after_commit:(fun () -> ())
          ~cgroup_parent_path:"/sys/fs/cgroup" ~new_id:(fresh fixture)
          ~resolve_execution:(fun _ -> incr resolutions;Ok fixture.execution)
          ~before_request:(fun () ->
            if !fail_next then (fail_next:=false;raise Injected_controller_failure)) in
        let binding,spec=prepare fixture 903
          "printf x >> recovery-ran; printf R > recovery-ready; read token < recovery-input; printf L > recovery-ready; read token < recovery-input; printf unexpected > recovery-past-input" in
        let operation=Owner.admit controller ~binding ~spec |> owner in
        let original=Owner.original operation in
        let result_waiter,result_resolver=Eio.Promise.create () in
        Eio.Fiber.fork ~sw (fun () -> Eio.Promise.resolve result_resolver (Owner.await_result operation));
        Owner.await_request (Owner.activate operation) |> owner;
        Eio_unix.await_readable ready;
        let ready_byte=Bytes.create 1 in
        let count=Eio_unix.run_in_systhread (fun () -> Unix.read ready ready_byte 0 1) in
        check "original native child is blocked on its first input"
          (count=1 && Bytes.to_string ready_byte="R");
        await_native_startup operation;
        fail_next:=true;
        let failed=Owner.cancel operation in
        (match Owner.await_request failed with
         | Error (Owner.Controller_failed Injected_controller_failure) -> ()
         | Ok () -> Alcotest.fail "the injected actor failure accepted cancellation"
         | Error error -> Alcotest.fail (Owner.error_to_string error));
        (match Eio.Promise.peek result_waiter with
         | None -> ()
         | Some _ -> Alcotest.fail "controller failure replaced the live native result");
        let claim=claim_path fixture binding in
        let job=Filename.concat fixture.registry_path (P.Id.to_string binding.operation_id ^ ".job") in
        let saved_claim=claim ^ ".saved" and saved_job=job ^ ".saved" in
        Unix.rename claim saved_claim;
        Unix.rename job saved_job;
        Fun.protect ~finally:(fun () -> Unix.rename saved_claim claim;Unix.rename saved_job job) (fun () ->
          (match Owner.await_request (Owner.cancel operation) with
           | Error (Owner.Registry_error _) -> ()
           | Ok () -> Alcotest.fail "recovered cancellation accepted missing original authority"
           | Error error -> Alcotest.fail (Owner.error_to_string error));
          let token=Bytes.of_string "x\n" in
          let count=Eio_unix.run_in_systhread (fun () -> Unix.write input token 0 2) in
          check "original child input accepts the liveness probe" (count=2);
          Eio_unix.await_readable ready;
          let count=Eio_unix.run_in_systhread (fun () -> Unix.read ready ready_byte 0 1) in
          check "missing authority sent no signal to the original child"
            (count=1 && Bytes.to_string ready_byte="L");
          check "missing authority created no replacement original"
            (not (Sys.file_exists claim) && not (Sys.file_exists job)));
        let other_binding,other_spec=prepare fixture 904 "printf independent; exit 8" in
        let other=Owner.admit controller ~binding:other_binding ~spec:other_spec |> owner in
        Owner.await_request (Owner.activate other) |> owner;
        let other_digest=Owner.await_result other |> owner in
        let other_loaded=Owner.load_result ~sw ~expected_sha256:(Some other_digest) other |> owner in
        let output=D.read_output other_loaded ~stream:P.Stdout ~offset:0L ~max_bytes:64 |> result_read in
        Alcotest.(check string) "independent job finishes while failed actor's job blocks" "independent" output.data;
        let cancellation=Owner.cancel operation in
        check "concurrent recovery cancellation shares one new request"
          (cancellation==Owner.cancel operation && cancellation!=failed);
        Owner.await_request cancellation |> owner;
        let digest=Owner.await_result operation |> owner in
        check "pre-activation observer receives the same original native result"
          (Eio.Promise.await result_waiter=Ok digest);
        let loaded=Owner.load_result ~sw ~expected_sha256:(Some digest) operation |> owner in
        assert_cancelled_result digest loaded;
        (match D.process loaded with
         | D.Child _ -> ()
         | D.Not_created _ -> Alcotest.fail "recovery erased the original running child");
        check "recovery retains the original admission" (Owner.original operation=original);
        check "recovery never resolves another execution" (!resolutions=2);
        Alcotest.(check string) "recovery never reruns the original payload" "x"
          (read (Filename.concat fixture.work "recovery-ran"));
        check "recovery cancels the original before it passes blocked input"
          (not (Sys.file_exists (Filename.concat fixture.work "recovery-past-input")));
        operation,digest) in
      check "endpoint teardown preserves the already published native digest"
        (Owner.await_result operation=Ok digest);
      check "endpoint teardown cannot restart cancellation"
        (Owner.await_request (Owner.cancel operation)=Error Owner.Owner_stopped);
      let loaded=Owner.load_result ~sw ~expected_sha256:(Some digest) operation |> owner in
      assert_cancelled_result digest loaded))


type replacement = Missing_original | Replaced_job | Replaced_launch

let captured_original_survives_missing_or_replaced_files ~owned replacement =
  with_fixture (fun ~env ~sw ~store fixture ->
    let ready_path=Filename.concat fixture.work "authority-ready" in
    let wait_path=Filename.concat fixture.work "authority-wait" in
    List.iter (fun path -> Unix.mkfifo path 0o666;Unix.chmod path 0o666) [ready_path;wait_path];
    let ready=Unix.openfile ready_path [Unix.O_RDWR;Unix.O_NONBLOCK;Unix.O_CLOEXEC] 0 in
    let wait=Unix.openfile wait_path [Unix.O_RDWR;Unix.O_NONBLOCK;Unix.O_CLOEXEC] 0 in
    Fun.protect ~finally:(fun () -> Unix.close ready;Unix.close wait) (fun () ->
      let controller=controller ~sw ~env fixture store in
      let binding,spec=prepare fixture 890
        "printf x >> authority-ran; printf R > authority-ready; read token < authority-wait; printf unexpected > authority-past-wait" in
      let operation=Owner.admit controller ~binding ~spec |> owner in
      if owned then (
        Owner.await_request (Owner.activate operation) |> owner;
        Eio_unix.await_readable ready;
        let byte=Bytes.create 1 in
        let length=Eio_unix.run_in_systhread (fun () -> Unix.read ready byte 0 1) in
        check "original native owner reached its actual blocking input" (length=1 && Bytes.to_string byte="R"));
      if owned then await_native_startup operation;
      let captured=Owner.inspect_original operation |> owner in
      let original=Owner.original operation in
      let claim=claim_path fixture binding in
      let job=Filename.dirname (job_leaf fixture binding R.Terminal_receipt) in
      let saved_claim=claim ^ ".captured" and saved_job=job ^ ".captured" in
      let original_bytes=read claim and original_stat=Unix.lstat job in
      Unix.rename claim saved_claim;
      Unix.rename job saved_job;
      let restore () =
        if Sys.file_exists saved_claim then (
          if Sys.file_exists claim then remove claim;
          if Sys.file_exists job then remove job;
          Unix.rename saved_job job;
          Unix.rename saved_claim claim)
      in
      Fun.protect ~finally:restore (fun () ->
        (match replacement with
         | Missing_original -> ()
         | Replaced_job | Replaced_launch ->
           let rebound=R.admit store ~new_admission_id:original.admission_id ~binding ~spec |> registry in
           (match replacement with
            | Missing_original | Replaced_job -> ()
            | Replaced_launch ->
              ignore (R.commit_launch rebound ~confirmed_admission_id:original.admission_id
                ~launch_id:(id 999990) |> registry)));
        let replacement_claim=if Sys.file_exists claim then Some (read claim) else None in
        let job_identity () =
          if Sys.file_exists job then let stat=Unix.lstat job in Some (stat.st_dev,stat.st_ino)
          else None
        in
        let replacement_job=job_identity () in
        let next_id= !(fixture.next_id) in
        let expect_refused = function
          | Error (Owner.Registry_error _) -> ()
          | Ok _ -> Alcotest.fail "matching coordinates replaced captured physical authority"
          | Error error -> Alcotest.fail (Owner.error_to_string error)
        in
        expect_refused (Owner.lookup controller original);
        expect_refused (Owner.admit controller ~binding ~spec);
        expect_refused (Owner.inspect_original operation);
        check "known original refusal generates no admission or launch ID" (next_id= !(fixture.next_id));
        check "refusal leaves replacement claim bytes or absence untouched"
          ((if Sys.file_exists claim then Some (read claim) else None)=replacement_claim);
        check "refusal leaves replacement job identity or absence untouched"
          (job_identity ()=replacement_job);
        check "captured original bytes and directory survive failed controls"
          (read saved_claim=original_bytes &&
           let saved=Unix.lstat saved_job in saved.st_dev=original_stat.st_dev && saved.st_ino=original_stat.st_ino);
        let other_binding,other_spec=prepare fixture 891 ": > independent-must-not-run" in
        let other=Owner.admit controller ~binding:other_binding ~spec:other_spec |> owner in
        let digest,loaded=cancel_and_load ~sw other in
        assert_no_child digest loaded;
        restore ());
      check "restored lookup retains the same original operation and native owner"
        ((Owner.lookup controller original |> owner)==operation);
      check "restored admission retains the same original operation"
        ((Owner.admit controller ~binding ~spec |> owner)==operation);
      let restored=Owner.inspect_original operation |> owner in
      check "restoration preserves captured known launch" (R.launch_state restored=R.launch_state captured);
      let digest,loaded=cancel_and_load ~sw operation in
      if owned then (
        assert_cancelled_result digest loaded;
        (match D.process loaded with
         | D.Child _ -> ()
         | D.Not_created _ -> Alcotest.fail "restored native owner lost its physical original");
        Alcotest.(check string) "retained native owner never replays" "x"
          (read (Filename.concat fixture.work "authority-ran")))
      else assert_no_child digest loaded;
      check "original cancellation never passes blocked payload input"
        (not (Sys.file_exists (Filename.concat fixture.work "authority-past-wait")))))

let delayed_refresh_cannot_erase_known_launch =
  with_fixture (fun ~env ~sw ~store fixture ->
    let controller=controller ~sw ~env fixture store in
    let binding,spec=prepare fixture 892 ": > must-not-run" in
    let operation=Owner.admit controller ~binding ~spec |> owner in
    let source=Owner.inspect_original operation |> owner in
    let entered,signal=Eio.Promise.create () and resume,release=Eio.Promise.create () in
    let unblock ()=if Eio.Promise.peek resume=None then Eio.Promise.resolve release () in
    let delayed,resolve=Eio.Promise.create () in
    Eio.Fiber.fork ~sw (fun () ->
      Eio.Promise.resolve resolve (Owner.For_testing.inspect_original operation ~after_refresh:(fun () ->
        Eio.Promise.resolve signal ();Eio.Promise.await resume)));
    Eio.Promise.await entered;
    Fun.protect ~finally:unblock (fun () ->
      let launch_id=id 999991 in
      ignore (R.commit_launch source ~confirmed_admission_id:(R.admission_id source) ~launch_id |> registry);
      let advanced=Owner.inspect_original operation |> owner in
      check "actual committed launch is captured while the old read is delayed"
        (R.launch_state advanced=R.Requested launch_id);
      unblock ();
      (match Eio.Promise.await delayed with
       | Error (Owner.Registry_error error) -> check "stale read is explicit" (error=R.Stale_record)
       | Ok _ -> Alcotest.fail "delayed old read overwrote the known launch"
       | Error error -> Alcotest.fail (Owner.error_to_string error));
      let claim=claim_path fixture binding in
      let bytes=read claim in
      let original=Owner.original operation in
      let json=Yojson.Safe.from_string bytes in
      let fields=match json with `Assoc fields -> fields | _ -> Alcotest.fail "claim object missing" in
      let changed=`Assoc (List.map (fun (name,value) ->
        name,(if name="launch_id" then `String (P.Id.to_string (id 999992)) else value)) fields) in
      Out_channel.with_open_bin claim (fun channel -> output_string channel (Yojson.Safe.to_string changed));
      Fun.protect ~finally:(fun () -> Out_channel.with_open_bin claim (fun channel -> output_string channel bytes)) (fun () ->
        let valid_rebound=R.load store ~binding |> registry in
        check "rebound claim is independently valid for a binding-only reader"
          (R.launch_state valid_rebound=R.Requested (id 999992));
        let expect_stale = function
          | Error (Owner.Registry_error error) -> check "known launch refuses rebound" (error=R.Stale_record)
          | Ok _ -> Alcotest.fail "known launch pin was discarded by a delayed refresh"
          | Error error -> Alcotest.fail (Owner.error_to_string error)
        in
        expect_stale (Owner.lookup controller original);
        expect_stale (Owner.admit controller ~binding ~spec)));
    check "restored source still pins the actual original launch"
      (R.launch_state (Owner.inspect_original operation |> owner)=R.Requested (id 999991)))

let pending_original_admission_joins_exact_lookup_without_republication =
  with_fixture (fun ~env ~sw ~store fixture ->
    let controller=controller ~sw ~env fixture store in
    let other_binding,other_spec=prepare fixture 893 ": > other" in
    let other=Owner.admit controller ~binding:other_binding ~spec:other_spec |> owner in
    let binding,spec=prepare fixture 894 ": > must-not-run" in
    let original_next_id= !(fixture.next_id) in
    let admission_id=id original_next_id in
    let entered,signal=Eio.Promise.create () and resume,release=Eio.Promise.create () in
    let unblock ()=if Eio.Promise.peek resume=None then Eio.Promise.resolve release () in
    let once=Atomic.make true in
    let fault=Recovery_test.before_parent_sync_dispatch ~before_sync:(fun () ->
      if Atomic.compare_and_set once true false then (Eio.Promise.resolve signal ();Eio.Promise.await resume)) in
    let initial,resolve=Eio.Promise.create () in
    Eio.Fiber.fork ~sw (fun () -> Eio.Promise.resolve resolve
      (Recovery_test.with_replace_dispatch_fault fault (fun () -> Owner.admit controller ~binding ~spec)));
    Eio.Promise.await entered;
    Fun.protect ~finally:unblock (fun () ->
      let duplicate,resolve_duplicate=Eio.Promise.create () and lookup,resolve_lookup=Eio.Promise.create () in
      Eio.Fiber.fork ~sw (fun () -> Eio.Promise.resolve resolve_duplicate (Owner.admit controller ~binding ~spec));
      Eio.Fiber.fork ~sw (fun () -> Eio.Promise.resolve resolve_lookup
        (Owner.lookup controller (P.original ~binding ~admission_id)));
      Eio.Fiber.yield ();
      check "exact duplicate and lookup wait for the captured admission"
        (Eio.Promise.peek duplicate=None && Eio.Promise.peek lookup=None);
      check "pending admission consumes only its original fresh ID" (!(fixture.next_id)=original_next_id+1);
      ignore (Owner.inspect_original other |> owner);
      unblock ();
      let operation=Eio.Promise.await initial |> owner in
      let second=Eio.Promise.await duplicate |> owner and looked=Eio.Promise.await lookup |> owner in
      check "all pending observers share the same captured operation" (operation==second && operation==looked);
      check "joining never generates another admission ID" (!(fixture.next_id)=original_next_id+1)))

let own_committed_launch_keeps_pre_activation_observers =
  with_fixture (fun ~env ~sw ~store fixture ->
    let entered,signal=Eio.Promise.create () and resume,release=Eio.Promise.create () in
    let unblock ()=if Eio.Promise.peek resume=None then Eio.Promise.resolve release () in
    let controller=Owner.For_testing.create ~sw ~fs:env#fs ~registry:store
      ~cgroup_parent_path:"/sys/fs/cgroup" ~new_id:(fresh fixture)
      ~resolve_execution:(fun _ -> Ok fixture.execution) ~before_request:(fun () -> ())
      ~after_commit:(fun () -> Eio.Promise.resolve signal ();Eio.Promise.await resume) in
    let binding,spec=prepare fixture 905 "printf x >> handoff-ran; printf original; exit 7" in
    let operation=Owner.admit controller ~binding ~spec |> owner in
    let waiting,resolve=Eio.Promise.create () in
    Eio.Fiber.fork ~sw (fun () -> Eio.Promise.resolve resolve (Owner.await_result operation));
    Fun.protect ~finally:unblock (fun () ->
      let activation=Owner.activate operation in
      Eio.Promise.await entered;
      let committed=Owner.inspect_original operation |> owner in
      (match R.launch_state committed with
       | R.Requested _ -> ()
       | R.Not_requested -> Alcotest.fail "handoff interleave did not commit its original launch");
      check "own committed launch does not become a cold-launch error"
        (Eio.Promise.peek waiting=None);
      check "activation remains pending before native handoff"
        (not (Sys.file_exists (Filename.concat fixture.work "handoff-ran")));
      unblock ();
      Owner.await_request activation |> owner;
      let digest=Owner.await_result operation |> owner in
      check "pre-activation waiter receives the original publication"
        (Eio.Promise.await waiting=Ok digest);
      let loaded=Owner.load_result ~sw ~expected_sha256:(Some digest) operation |> owner in
      let output=D.read_output loaded ~stream:P.Stdout ~offset:0L ~max_bytes:64 |> result_read in
      Alcotest.(check string) "handoff preserves original output" "original" output.data;
      Alcotest.(check string) "handoff runs the original once" "x"
        (read (Filename.concat fixture.work "handoff-ran"))))

let cancellation_during_handoff_preserves_pin rollback =
  with_fixture (fun ~env ~sw ~store fixture ->
    let entered,signal=Eio.Promise.create () and resume,release=Eio.Promise.create () in
    let unblock ()=if Eio.Promise.peek resume=None then Eio.Promise.resolve release () in
    let controller=Owner.For_testing.create ~sw ~fs:env#fs ~registry:store
      ~cgroup_parent_path:"/sys/fs/cgroup" ~new_id:(fresh fixture)
      ~resolve_execution:(fun _ -> Ok fixture.execution) ~before_request:(fun () -> ())
      ~after_commit:(fun () -> Eio.Promise.resolve signal ();Eio.Promise.await resume) in
    let binding,spec=prepare fixture 906 "printf x >> handoff-cancel-ran" in
    let operation=Owner.admit controller ~binding ~spec |> owner in
    Fun.protect ~finally:unblock (fun () ->
      let activation=Owner.activate operation in
      Eio.Promise.await entered;
      let committed=Owner.inspect_original operation |> owner in
      let launch_id=match R.launch_state committed with
        | R.Requested id -> id
        | R.Not_requested -> Alcotest.fail "launch was not committed before handoff" in
      let claim=claim_path fixture binding in
      let launch_bytes=read claim in
      ignore (R.request_cancel committed ~confirmed_admission_id:(R.admission_id committed) |> registry);
      let cancelled=Owner.inspect_original operation |> owner in
      check "concurrent observer captured the original cancellation"
        (R.cancellation_state cancelled=R.Cancellation_requested);
      let saved=claim ^ ".cancelled" in
      if rollback then (
        Unix.rename claim saved;
        Out_channel.with_open_bin claim (fun channel -> output_string channel launch_bytes);
        Unix.chmod claim 0o400);
      Fun.protect ~finally:(fun () -> if rollback then Unix.rename saved claim) (fun () ->
        unblock ();
        Owner.await_request activation |> owner;
        if rollback then (
          (match Owner.await_result operation with
           | Error (Owner.Lifetime_error (Owner.C.Supervisor_error (S.Registry_error R.Stale_record))) -> ()
           | Ok _ -> Alcotest.fail "rolled-back launch produced a result"
           | Error error -> Alcotest.fail (Owner.error_to_string error));
          (match Owner.inspect_original operation with
           | Error (Owner.Registry_error R.Stale_record) -> ()
           | Ok _ -> Alcotest.fail "handoff erased the observed cancellation"
           | Error error -> Alcotest.fail (Owner.error_to_string error));
          check "stale authority never creates a terminal receipt"
            (not (Sys.file_exists (job_leaf fixture binding R.Terminal_receipt))))
        else (
          let digest=Owner.await_result operation |> owner in
          let loaded=Owner.load_result ~sw ~expected_sha256:(Some digest) operation |> owner in
          (match D.process loaded with
           | D.Not_created {launch_id=Some actual} -> check "no-child receipt retains launch" (actual=launch_id)
           | D.Not_created {launch_id=None} | D.Child _ ->
             Alcotest.fail "cancelled handoff did not publish the original no-child receipt"));
        check "cancelled handoff never runs the payload"
          (not (Sys.file_exists (Filename.concat fixture.work "handoff-cancel-ran"))))))

let uncertain_cancel_can_reconcile_the_held_original =
  with_fixture (fun ~env ~sw ~store fixture ->
    let entered,signal=Eio.Promise.create () and resume,release=Eio.Promise.create () in
    let unblock ()=if Eio.Promise.peek resume=None then Eio.Promise.resolve release () in
    let fail_next=ref false in
    let controller=Owner.For_testing.create ~sw ~fs:env#fs ~registry:store
      ~cgroup_parent_path:"/sys/fs/cgroup" ~new_id:(fresh fixture)
      ~resolve_execution:(fun _ -> Ok fixture.execution)
      ~before_request:(fun () -> if !fail_next then (fail_next:=false;raise Injected_controller_failure))
      ~after_commit:(fun () -> Eio.Promise.resolve signal ();Eio.Promise.await resume) in
    let binding,spec=prepare fixture 907 "printf x >> uncertain-ran" in
    let operation=Owner.admit controller ~binding ~spec |> owner in
    Fun.protect ~finally:unblock (fun () ->
      let activation=Owner.activate operation in
      Eio.Promise.await entered;
      let committed=Owner.inspect_original operation |> owner in
      let launch_id=match R.launch_state committed with
        | R.Requested id -> id
        | R.Not_requested -> Alcotest.fail "launch was not committed before handoff" in
      let claim=claim_path fixture binding in
      let launch_bytes=read claim in
      let fault=match Recovery_test.lane_scope_release_fault
          ~owner:(P.Id.to_string binding.operation_id) ~exception_:(Failure "injected lane release") with
        | Ok fault -> fault
        | Error _ -> Alcotest.fail "invalid fault owner" in
      (match Recovery_test.with_lane_scope_release_fault fault (fun () ->
          R.request_cancel committed ~confirmed_admission_id:(R.admission_id committed)) with
       | Error (R.Commit_unconfirmed _) -> ()
       | Error error -> Alcotest.fail (R.error_to_string error)
       | Ok _ -> Alcotest.fail "failed cancellation release was acknowledged");
      Unix.rename claim (claim ^ ".uncertain");
      Out_channel.with_open_bin claim (fun channel -> output_string channel launch_bytes);
      Unix.chmod claim 0o400;
      let unchanged=Recovery_test.replace_dispatch_fault ~stage:Recovery_test.Before_publish_replace
        ~exception_:(Unix.Unix_error (Unix.EIO,"rename","cancel claim")) in
      (match Recovery_test.with_replace_dispatch_fault unchanged (fun () ->
          R.request_cancel committed ~confirmed_admission_id:(R.admission_id committed)) with
       | Error (R.Publication_failed failure) ->
         check "a later failed cancellation did not change the claim"
           (failure.target_effect=Fs_compat.Target_unchanged)
       | Error error -> Alcotest.fail (R.error_to_string error)
       | Ok _ -> Alcotest.fail "failed second cancellation was acknowledged");
      (match Owner.inspect_original operation with
       | Error (Owner.Registry_error R.Cancel_reconciliation_required) -> ()
       | Error error -> Alcotest.fail (Owner.error_to_string error)
       | Ok _ -> Alcotest.fail "uncertain cancellation appeared as a current original");
      let original=Owner.original operation in
      let looked=Owner.lookup controller original |> owner in
      check "held lookup returns the same original operation" (looked==operation);
      let expect_uncertain_view () =
        (match Owner.snapshot looked with
         | Error (Owner.Registry_error R.Cancel_reconciliation_required) -> ()
         | Error error -> Alcotest.fail (Owner.error_to_string error)
         | Ok _ -> Alcotest.fail "held snapshot hid uncertain original authority");
        (match Owner.read_output ~sw looked ~stream:P.Stdout ~offset:0L ~max_bytes:64 with
         | Error (Owner.Registry_error R.Cancel_reconciliation_required) -> ()
         | Error error -> Alcotest.fail (Owner.error_to_string error)
         | Ok _ -> Alcotest.fail "held output became available or pending without original authority") in
      expect_uncertain_view ();
      let wrong=P.original ~binding ~admission_id:(id 999994) in
      (match Owner.lookup controller wrong with
       | Error Owner.Admission_mismatch -> ()
       | Error error -> Alcotest.fail (Owner.error_to_string error)
       | Ok _ -> Alcotest.fail "held lookup adopted another admission");
      let missing=claim ^ ".lookup-missing" in
      Unix.rename claim missing;
      Fun.protect ~finally:(fun () -> Unix.rename missing claim) (fun () ->
        match Owner.lookup controller original with
        | Error (Owner.Registry_error R.Missing_original) -> ()
        | Error error -> Alcotest.fail (Owner.error_to_string error)
        | Ok _ -> Alcotest.fail "held lookup accepted missing original authority");
      let waiting,resolve=Eio.Promise.create () in
      Eio.Fiber.fork ~sw (fun () -> Eio.Promise.resolve resolve (Owner.await_result operation));
      unblock ();
      Owner.await_request activation |> owner;
      (match Owner.For_testing.await_startup operation with
       | Some (Ok (S.Not_performed {error=S.Registry_error R.Cancel_reconciliation_required;pipe_cleanup_errors=_})) -> ()
       | Some (Ok _) -> Alcotest.fail "uncertain original entered native startup"
       | Some (Error error) -> Alcotest.fail (Owner.error_to_string error)
       | None -> Alcotest.fail "held original lost its native lifetime");
      check "held result remains pending for explicit reconciliation" (Eio.Promise.peek waiting=None);
      expect_uncertain_view ();
      (match Owner.await_request (Owner.activate looked) with
       | Error (Owner.Registry_error R.Cancel_reconciliation_required) -> ()
       | Error error -> Alcotest.fail (Owner.error_to_string error)
       | Ok () -> Alcotest.fail "held lookup restored launch authority");
      check "failed activation cannot settle the held original" (Eio.Promise.peek waiting=None);
      fail_next:=true;
      (match Owner.await_request (Owner.cancel looked) with
       | Error (Owner.Controller_failed Injected_controller_failure) -> ()
       | Error error -> Alcotest.fail (Owner.error_to_string error)
       | Ok () -> Alcotest.fail "injected owner failure became successful cancellation");
      check "owner failure does not replace the held result" (Eio.Promise.peek waiting=None);
      let receipt=job_leaf fixture binding R.Terminal_receipt in
      Out_channel.with_open_bin receipt (fun channel -> output_string channel "conflicting receipt");
      Unix.chmod receipt 0o400;
      (match Owner.await_request (Owner.cancel looked) with
       | Error (Owner.Result_error _) -> ()
       | Error error -> Alcotest.fail (Owner.error_to_string error)
       | Ok () -> Alcotest.fail "conflicting receipt was reported as successful reconciliation");
      check "failed publication retains the pending original result" (Eio.Promise.peek waiting=None);
      let observed=Owner.snapshot looked |> owner in
      (match observed.progress with
       | Owner.Owned_lifetime (C.No_supervisor (S.Registry_error R.Cancel_reconciliation_required)) -> ()
       | Owner.Owned_lifetime _ | Owner.Registered | Owner.Activation_pending
       | Owner.Publication_known _ | Owner.Ownership_unknown ->
         Alcotest.fail "confirmed cancellation lost its held startup diagnostic");
      check "confirmed cancellation retains the original launch"
        (R.launch_state observed.record=R.Requested launch_id
         && R.cancellation_state observed.record=R.Cancellation_requested);
      check "held cancellation has no invented output before publication"
        (Owner.read_output ~sw looked ~stream:P.Stdout ~offset:0L ~max_bytes:64 |> owner = None);
      Unix.unlink receipt;
      Owner.await_request (Owner.cancel looked) |> owner;
      let digest=Owner.await_result operation |> owner in
      check "preexisting result observer receives reconciled receipt" (Eio.Promise.await waiting=Ok digest);
      let loaded=Owner.load_result ~sw ~expected_sha256:(Some digest) operation |> owner in
      (match D.process loaded with
       | D.Not_created {launch_id=Some actual} -> check "receipt retains the original launch" (actual=launch_id)
       | D.Not_created {launch_id=None} | D.Child _ ->
         Alcotest.fail "reconciled original did not publish its actual no-child receipt");
      let published=Owner.snapshot looked |> owner in
      check "reconciled view reports the actual publication digest"
        (published.progress=Owner.Owned_lifetime (C.Publication_known digest)
         && R.launch_state published.record=R.Requested launch_id);
      (match Owner.read_output ~sw looked ~stream:P.Stdout ~offset:0L ~max_bytes:64 |> owner with
       | Some chunk ->
         check "reconciled output is the verified empty sealed original"
           (chunk.data="" && match chunk.extent with
            | P.Sealed {byte_length=0L;_} -> true
            | P.Growing _ | P.Sealed _ -> false)
       | None -> Alcotest.fail "published no-child output remained pending");
      check "reconciliation never runs the payload"
        (not (Sys.file_exists (Filename.concat fixture.work "uncertain-ran")))))

let pending_and_published_output_are_distinct_original_observations =
  with_fixture (fun ~env ~sw ~store fixture ->
    let controller=controller ~sw ~env fixture store in
    let binding,spec=prepare fixture 910 ": > must-not-run" in
    let operation=Owner.admit controller ~binding ~spec |> owner in
    check "registered view does not wait for activation"
      ((Owner.snapshot operation |> owner).progress=Owner.Registered);
    check "no capture is pending rather than invented empty output"
      (Owner.read_output ~sw operation ~stream:P.Stdout ~offset:0L ~max_bytes:64 |> owner = None);
    (match Owner.read_output ~sw operation ~stream:P.Stdout ~offset:0L ~max_bytes:0 with
     | Error error -> check "invalid pending read retains its actual range error"
         (error=Owner.Result_error (D.Output_error {stream=P.Stdout;cause=Owner.O.Invalid_range}))
     | Ok _ -> Alcotest.fail "an invalid read became a pending request");
    let claim=claim_path fixture binding in
    let saved=claim ^ ".saved" in
    Unix.rename claim saved;
    Fun.protect ~finally:(fun () -> Unix.rename saved claim) (fun () ->
      (match Owner.snapshot operation with
       | Error (Owner.Registry_error _) -> ()
       | Error error -> Alcotest.fail (Owner.error_to_string error)
       | Ok _ -> Alcotest.fail "missing original became a pending snapshot");
      match Owner.read_output ~sw operation ~stream:P.Stdout ~offset:0L ~max_bytes:64 with
      | Error (Owner.Registry_error _) -> ()
      | Error error -> Alcotest.fail (Owner.error_to_string error)
      | Ok _ -> Alcotest.fail "missing authority became pending or empty output");
    let digest,loaded=cancel_and_load ~sw operation in
    assert_no_child digest loaded;
    check "non-start publication is historical rather than fabricated readiness"
      ((Owner.snapshot operation |> owner).progress=Owner.Publication_known digest);
    (match Owner.read_output ~sw operation ~stream:P.Stdout ~offset:0L ~max_bytes:64 |> owner with
     | Some chunk -> check "verified no-child output is actually empty and sealed"
         (chunk.data="" && match chunk.extent with P.Sealed {byte_length=0L;_} -> true | P.Growing _ | P.Sealed _ -> false)
     | None -> Alcotest.fail "published no-child output became pending");
    let receipt=job_leaf fixture binding R.Terminal_receipt in
    let original_bytes=read receipt in
    let mutate_receipt bytes =
      Unix.chmod receipt 0o600;
      Fun.protect ~finally:(fun () -> Unix.chmod receipt 0o400) (fun () ->
        Out_channel.with_open_bin receipt (fun channel -> output_string channel bytes))
    in
    mutate_receipt "invalid original receipt";
    Fun.protect ~finally:(fun () -> mutate_receipt original_bytes) (fun () ->
      check "historical publication digest does not claim fresh integrity"
        ((Owner.snapshot operation |> owner).progress=Owner.Publication_known digest);
      match Owner.read_output ~sw operation ~stream:P.Stdout ~offset:0L ~max_bytes:64 with
      | Error (Owner.Result_error _) -> ()
      | Error error -> Alcotest.fail (Owner.error_to_string error)
      | Ok _ -> Alcotest.fail "corrupt published receipt became valid or pending output");
    check "original observation never launches the registered payload"
      (not (Sys.file_exists (Filename.concat fixture.work "must-not-run"))))

let live_views_do_not_join_startup_or_blocked_process_and_survive_teardown =
  with_fixture (fun ~env ~sw ~store fixture ->
    let open_fifo name =
      let path=Filename.concat fixture.work name in
      Unix.mkfifo path 0o666;
      Unix.chmod path 0o666;
      Unix.openfile path [Unix.O_RDWR;Unix.O_NONBLOCK;Unix.O_CLOEXEC] 0
    in
    let ready=open_fifo "live-ready" and input=open_fifo "live-input" in
    Fun.protect ~finally:(fun () -> List.iter Unix.close [ready;input]) (fun () ->
      let operation,digest=Eio.Switch.run (fun endpoint ->
        let entered,signal=Eio.Promise.create () and resume,release=Eio.Promise.create () in
        let unblock ()=if Eio.Promise.peek resume=None then Eio.Promise.resolve release () in
        let controller=Owner.For_testing.create ~sw:endpoint ~fs:env#fs ~registry:store
          ~cgroup_parent_path:"/sys/fs/cgroup" ~new_id:(fresh fixture)
          ~resolve_execution:(fun _ -> Ok fixture.execution) ~before_request:(fun () -> ())
          ~after_commit:(fun () -> Eio.Promise.resolve signal ();Eio.Promise.await resume) in
        let binding,spec=prepare fixture 911
          "printf prefix; printf R > live-ready; read token < live-input; printf unexpected > live-past-input" in
        let operation=Owner.admit controller ~binding ~spec |> owner in
        Fun.protect ~finally:unblock (fun () ->
          let activation=Owner.activate operation in
          Eio.Promise.await entered;
          check "view returns during this controller's suspended launch handoff"
            ((Owner.snapshot operation |> owner).progress=Owner.Activation_pending);
          check "output view does not wait for native startup"
            (Owner.read_output ~sw operation ~stream:P.Stdout ~offset:0L ~max_bytes:64 |> owner = None);
          check "pending observation creates no output spool"
            (not (Sys.file_exists (job_leaf fixture binding (R.Stream_data P.Stdout))));
          let other_binding,other_spec=prepare fixture 912 ": > other-must-not-run" in
          let other=Owner.admit controller ~binding:other_binding ~spec:other_spec |> owner in
          let digest,loaded=cancel_and_load ~sw other in
          assert_no_child digest loaded;
          unblock ();
          Owner.await_request activation |> owner);
        Eio_unix.await_readable ready;
        await_native_startup operation;
        let observed=Owner.snapshot operation |> owner in
        (match observed.progress with
         | Owner.Owned_lifetime progress ->
           (match progress with
            | C.Supervised native_progress ->
              (match native_progress with
               | S.Awaiting_settlement {stdout;stderr} ->
                 List.iter (function
                   | P.Growing _ -> ()
                   | P.Sealed _ -> Alcotest.fail "open original output became sealed") [stdout;stderr]
               | S.Physically_settled _ | S.Publication_known _ ->
                   Alcotest.fail "blocked native process became settled or published")
            | C.Startup_pending | C.No_supervisor _ | C.Publication_known _ ->
                Alcotest.fail "settled startup did not retain its original native supervisor")
         | Owner.Registered | Owner.Activation_pending | Owner.Publication_known _ | Owner.Ownership_unknown ->
             Alcotest.fail "live snapshot lost its native lifetime");
        (match Owner.read_output ~sw operation ~stream:P.Stdout ~offset:0L ~max_bytes:64 |> owner with
         | Some chunk ->
           Alcotest.(check string) "live read returns only the retained original prefix"
             (String.sub "prefix" 0 (String.length chunk.data)) chunk.data;
           (match chunk.extent with
            | P.Growing _ -> ()
            | P.Sealed _ -> Alcotest.fail "open child output became sealed before its EOF")
         | None -> Alcotest.fail "actual initialized native capture became pending");
        check "views do not run the blocked payload past its input"
          (not (Sys.file_exists (Filename.concat fixture.work "live-past-input")));
        Owner.await_request (Owner.cancel operation) |> owner;
        let digest=Owner.await_result operation |> owner in
        operation,digest) in
      check "post-teardown snapshot retains its historical original publication"
        ((Owner.snapshot operation |> owner).progress=Owner.Owned_lifetime (C.Publication_known digest));
      match Owner.read_output ~sw operation ~stream:P.Stdout ~offset:0L ~max_bytes:64 |> owner with
      | Some chunk ->
        Alcotest.(check string) "post-teardown view opens the actual retained output" "prefix" chunk.data;
        (match chunk.extent with
         | P.Sealed {byte_length=6L;_} -> ()
         | P.Sealed _ | P.Growing _ -> Alcotest.fail "retained output lost its exact complete seal")
      | None -> Alcotest.fail "published output after native teardown became pending"))

let portable_cases=[
  "missing original never readmits",(fun () -> captured_original_survives_missing_or_replaced_files ~owned:false Missing_original ());
  "replacement job never rebinds",(fun () -> captured_original_survives_missing_or_replaced_files ~owned:false Replaced_job ());
  "replacement launch never rebinds",(fun () -> captured_original_survives_missing_or_replaced_files ~owned:false Replaced_launch ());
  "delayed source refresh preserves known launch",delayed_refresh_cannot_erase_known_launch;
  "exact pending admission and lookup share original",pending_original_admission_joins_exact_lookup_without_republication;
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
  "request exception leaves original controls serviceable",request_exception_does_not_poison_later_original_controls;
  "failed actor resumes only an explicit control",failed_actor_resumes_only_an_explicit_new_control;
  "pending and published output remain distinct",pending_and_published_output_are_distinct_original_observations;
]

let native_cases=[
  "missing live original never readmits",(fun () -> captured_original_survives_missing_or_replaced_files ~owned:true Missing_original ());
  "replacement live job never rebinds",(fun () -> captured_original_survives_missing_or_replaced_files ~owned:true Replaced_job ());
  "replacement live launch never rebinds",(fun () -> captured_original_survives_missing_or_replaced_files ~owned:true Replaced_launch ());
  "duplicate activation runs one original",duplicate_activation_runs_one_original_and_shares_exact_result;
  "blocked original does not block another",blocked_original_does_not_head_of_line_block_another;
  "startup cancellation preserves original launch",cancel_during_original_startup_never_replays_or_signals_a_replacement;
  "cold result read preserves no-launch authority",cold_result_read_does_not_restore_launch_authority;
  "failed native owner leaves another healthy",failed_native_owner_does_not_fail_other_controller_operations;
  "second activation preserves native result",second_activation_during_native_startup_preserves_original_result;
  "native publication failure remains observable",native_publication_failure_remains_observable_after_revalidation;
  "failed actor retains native cancellation and result",failed_actor_keeps_native_cancellation_and_historical_result;
  "own committed launch preserves pre-activation observers",own_committed_launch_keeps_pre_activation_observers;
  "handoff preserves a concurrent cancellation",(fun () -> cancellation_during_handoff_preserves_pin false ());
  "handoff refuses rollback after observed cancellation",(fun () -> cancellation_during_handoff_preserves_pin true ());
  "uncertain cancellation reconciles the held original",uncertain_cancel_can_reconcile_the_held_original;
  "live views do not join process and survive teardown",live_views_do_not_join_startup_or_blocked_process_and_survive_teardown;
]

let () =
  if G.For_testing.linux_build && Unix.geteuid ()<>0 && Sys.getenv_opt "GITHUB_ACTIONS"=Some "true" then (
    let executable=Unix.realpath Sys.executable_name in
    Unix.execvp "sudo" (Array.concat
      [[|"sudo";"-n";"--preserve-env=EIO_BACKEND";"--";executable|];
       Array.sub Sys.argv 1 (Array.length Sys.argv-1)]));
  let native=if G.For_testing.linux_build && Unix.geteuid ()=0 then native_cases else [] in
  Alcotest.run "Endpoint job owner"
    ["original controller",List.map (fun (name,test) -> Alcotest.test_case name `Quick test) (portable_cases @ native)]

