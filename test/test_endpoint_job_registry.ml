open Alcotest
module P = Endpoint_job_protocol
module R = Endpoint_job_registry
module Recovery_test = Fs_compat_test_support.Publication_recovery_for_testing
let require = function Ok value -> value | Error e -> fail e
let get = function Ok value -> value | Error e -> fail (R.error_to_string e)
let id suffix = P.Id.of_string ("019a0000-0000-7000-8000-0000000000" ^ suffix) |> require
let digest value = P.Sha256.of_string Agent_core_sha256.(digest_string value |> to_hex) |> require
let route : P.route = {backend=Remote_ssh;endpoint_incarnation=id "01";boot_id=id "02"}
let owner : P.owner = {workspace_id=id "03";keeper_name="original keeper"}
let spec = P.spec ~domain:P.Workspace_process ~argv:["/bin/echo";"original\255argument"]
  ~env:["VALUE","private value"] ~cwd:"/work/original" ~remote_root:"/work"
  ~stdin:"original\000stdin\255" ~mode:Exec_ssh_protocol.Guest_local ~network_policy_sha256:None |> require
let binding operation_id = P.binding ~route ~owner ~operation_id
  ~invocation_sha256:(digest (P.Id.to_string operation_id)) ~spec_sha256:(P.spec_sha256 spec) |> require
let chosen_payload_uid () = if Unix.geteuid ()=0 then 1 else Unix.geteuid ()+1
let claim_path root b = Filename.concat root (P.Id.to_string b.P.operation_id ^ ".claim.json")
let job_path root b = Filename.concat root (P.Id.to_string b.P.operation_id ^ ".job")
let rec remove path =
  match Unix.lstat path with
  | {Unix.st_kind=Unix.S_DIR;_} -> Array.iter (fun name -> remove (Filename.concat path name)) (Sys.readdir path);Unix.rmdir path
  | _ -> Unix.unlink path
  | exception Unix.Unix_error (Unix.ENOENT,_,_) -> ()
let fixture f =
  let root=Filename.temp_file "masc-endpoint-registry-" "" in
  Unix.unlink root;Unix.mkdir root 0o700;
  Fun.protect ~finally:(fun () -> remove root) (fun () ->
    Eio_main.run (fun env -> Eio.Switch.run (fun sw ->
      let open_root ?(route=route) ?(payload_uid=chosen_payload_uid ()) () =
        R.open_registry ~sw ~fs:env#fs ~root_path:root ~route ~owner ~payload_uid in
      let registry=open_root () |> get in f ~env ~sw ~root ~registry ~open_root)))
let admitted registry b = R.admit registry ~new_admission_id:(id "04") ~binding:b ~spec |> get
let commit record = R.commit_launch record ~confirmed_admission_id:(R.admission_id record) ~launch_id:(id "06") |> get
let completed = function
  | R.Performed {value;release_error=None} -> value
  | R.Performed {release_error=Some e;_} -> fail (File_lock_eio.durable_lock_error_to_string e)
  | R.Not_performed e -> fail (R.error_to_string e)
let rejected label value = check bool label true (Result.is_error value)

let test_original_admission_survives_reopen () = fixture (fun ~env:_ ~sw:_ ~root ~registry ~open_root ->
  let b=binding (id "05") in let first=admitted registry b in
  check int64 "admission is durably ready before return" 1L (R.revision first);
  check bool "complete binary launch data is retained" true (R.specification first=spec);
  check bool "admission itself grants no launch" true (R.launch_state first=R.Not_requested);
  let claim=Yojson.Safe.from_file (claim_path root b) in
  check int "new claims use outer format v2" 2 Yojson.Safe.Util.(claim |> member "version" |> to_int);
  check string "new claims retain the reconciliation operation" "reconcile_admission"
    Yojson.Safe.Util.(claim |> member "original" |> member "operation" |> to_string);
  let repeated=R.admit registry ~new_admission_id:(id "99") ~binding:b ~spec |> get in
  check bool "duplicate caller does not replace the original admission identity" true (R.admission_id first=R.admission_id repeated);
  let reopened=open_root () |> get in let recovered=R.load reopened ~binding:b |> get in
  check bool "restart read preserves original owner, invocation and launch bytes" true
    (R.binding recovered=b && R.specification recovered=spec && R.admission_id recovered=id "04");
  check int "payload identity remains original" (chosen_payload_uid ()) (R.payload_uid recovered))

let test_legacy_claim_version_is_rejected_before_decode label historical_kind () =
  fixture (fun ~env:_ ~sw:_ ~root ~registry ~open_root ->
    let b=binding (id "05") in let original=admitted registry b in
    let claim=claim_path root b in
    let fields=match Yojson.Safe.from_file claim with
      | `Assoc fields -> fields | _ -> fail "fixture claim is not an object" in
    let current_original=List.assoc "original" fields in
    let historical_original=match historical_kind with
      | `Inspect ->
        let binding=match current_original with
          | `Assoc fields -> List.assoc "binding" fields
          | _ -> fail "fixture original is not an object" in
        `Assoc ["protocol",`String "masc_endpoint_jobs";"version",`Int 1;
          "operation",`String "inspect";"binding",binding]
      | `Reconcile_admission -> current_original in
    let replace key value fields=(key,value)::List.remove_assoc key fields in
    let historical=`Assoc (fields |> replace "version" (`Int 1) |> replace "original" historical_original) in
    Unix.chmod claim 0o600;Yojson.Safe.to_file claim historical;Unix.chmod claim 0o400;
    let job=job_path root b in
    let admission_path=Filename.concat job "admission_id" in
    let original_path=Filename.concat job "original.json" in
    let claim_before=In_channel.with_open_bin claim In_channel.input_all in
    let admission_before=In_channel.with_open_bin admission_path In_channel.input_all in
    let original_before=In_channel.with_open_bin original_path In_channel.input_all in
    let job_inode=(Unix.lstat job).st_ino in
    let expected=Error (R.Unsupported_version {expected=2;actual=1}) in
    let reopened=open_root () |> get in
    let check_unchanged operation =
      check string (label ^ ": " ^ operation ^ " leaves claim bytes unchanged") claim_before
        (In_channel.with_open_bin claim In_channel.input_all);
      check string (label ^ ": " ^ operation ^ " leaves admission identity unchanged") admission_before
        (In_channel.with_open_bin admission_path In_channel.input_all);
      check string (label ^ ": " ^ operation ^ " leaves original bytes unchanged") original_before
        (In_channel.with_open_bin original_path In_channel.input_all);
      check int (label ^ ": " ^ operation ^ " does not replace the job") job_inode (Unix.lstat job).st_ino in
    check bool (label ^ ": public load rejects outer v1") true (R.load reopened ~binding:b=expected);
    check_unchanged "load";
    check bool (label ^ ": public admit rejects outer v1") true
      (R.admit reopened ~new_admission_id:(id "99") ~binding:b ~spec=expected);
    check_unchanged "admit";
    check string (label ^ ": fixture retains the original admission") (P.Id.to_string (R.admission_id original)) admission_before)

exception Interrupted
let test_preparing_boundaries_resume_original () =
  List.iter (fun boundary -> fixture (fun ~env:_ ~sw:_ ~root ~registry ~open_root ->
    let b=binding (id "05") in
    let stop () = raise Interrupted in
    (match R.For_testing.admit ~after_missing_job:(fun () -> ()) ~after_claim:(if boundary=`Claim then stop else fun () -> ())
        ~after_job:(if boundary=`Job then stop else fun () -> ())
        ~after_original:(if boundary=`Original then stop else fun () -> ()) registry
        ~new_admission_id:(id "04") ~binding:b ~spec with
     | exception Interrupted -> ()
     | Ok _ | Error _ -> fail "interruption boundary was not reached");
    let before=if boundary<>`Claim then Some (Unix.lstat (job_path root b)).st_ino else None in
    let recovered=R.admit (open_root () |> get) ~new_admission_id:(id "99") ~binding:b ~spec |> get in
    check bool "interrupted preparation resumes its same original admission" true (R.admission_id recovered=id "04");
    check bool "recovery never changes the original input" true (R.specification recovered=spec);
    Option.iter (fun inode -> check int "published original directory is not replaced" inode
      (Unix.lstat (job_path root b)).st_ino) before;
    check bool "preparation recovery still has no launch permission" true (R.launch_state recovered=R.Not_requested)))
    [`Claim;`Job;`Original]

let test_competing_directory_publication_preserves_original () = fixture (fun ~env:_ ~sw:_ ~root ~registry ~open_root:_ ->
  let b=binding (id "05") in
  let published=ref None in
  let outer=R.For_testing.admit ~after_claim:(fun () -> ())
      ~after_missing_job:(fun () ->
        let inner=R.admit registry ~new_admission_id:(id "99") ~binding:b ~spec |> get in
        published:=Some (R.admission_id inner,(Unix.lstat (job_path root b)).st_ino))
      ~after_job:(fun () -> ()) ~after_original:(fun () -> ()) registry
      ~new_admission_id:(id "04") ~binding:b ~spec |> get in
  match !published with
  | None -> fail "competing directory publication boundary was not reached"
  | Some (admission,inode) ->
    check bool "both admissions preserve the same original claim" true
      (admission=id "04" && R.admission_id outer=admission && R.specification outer=spec);
    check int "the winning original directory is never replaced" inode (Unix.lstat (job_path root b)).st_ino;
    check bool "directory contention never grants launch permission" true (R.launch_state outer=R.Not_requested))

let test_launch_confirmation_and_one_use () = fixture (fun ~env:_ ~sw ~root:_ ~registry ~open_root ->
  let b=binding (id "05") in let record=admitted registry b in
  check bool "another admission cannot confirm this launch" true
    (R.commit_launch record ~confirmed_admission_id:(id "99") ~launch_id:(id "06")=Error R.Binding_mismatch);
  let permit=commit record in
  let recovered=R.load (open_root () |> get) ~binding:b |> get in
  check int64 "intent is durable before any launch callback" 2L (R.revision recovered);
  check bool "original launch ID survives reopening" true (R.launch_state recovered=R.Requested (id "06"));
  check bool "stale caller cannot obtain another launch permit" true
    (R.commit_launch record ~confirmed_admission_id:(id "04") ~launch_id:(id "07")=Error R.Launch_already_requested);
  check bool "recovered committed intent cannot authorize fresh launch" true
    (R.commit_launch recovered ~confirmed_admission_id:(id "04") ~launch_id:(id "07")=Error R.Launch_already_requested);
  let count=ref 0 in
  let value=R.with_launch ~sw permit (fun target ~storage:_ -> incr count;
    check bool "callback receives exact original endpoint admission" true
      (target.R.binding=b && target.spec=spec && target.admission_id=id "04" && target.launch_id=id "06");
    check int "the stored execution identity reaches the supervisor boundary" (chosen_payload_uid ()) target.payload_uid;
    "original launch result") |> completed in
  check string "callback result remains authoritative" "original launch result" value;
  (match R.with_launch ~sw permit (fun _ ~storage:_ -> incr count) with
   | R.Not_performed R.Launch_intent_spent -> ()
   | R.Not_performed _ | R.Performed _ -> fail "spent permit executed again");
  check int "exactly one actual callback entry" 1 !count)

let test_lost_launch_reply_and_callback_exception () =
  fixture (fun ~env:_ ~sw ~root:_ ~registry ~open_root ->
    let b=binding (id "05") in let record=admitted registry b in
    (match R.For_testing.commit_launch ~after_publication:(fun () -> raise Interrupted)
        record ~confirmed_admission_id:(id "04") ~launch_id:(id "06") with
     | exception Interrupted -> ()
     | Ok _ | Error _ -> fail "lost-reply boundary was not reached");
    let recovered=R.load (open_root () |> get) ~binding:b |> get in
    check bool "lost reply retains original durable launch intent" true (R.launch_state recovered=R.Requested (id "06"));
    check bool "lost reply is reconciliation, never a new launch permit" true
      (R.commit_launch recovered ~confirmed_admission_id:(id "04") ~launch_id:(id "07")=Error R.Launch_already_requested));
  fixture (fun ~env:_ ~sw ~root:_ ~registry ~open_root:_ ->
    let permit=admitted registry (binding (id "05")) |> commit in let count=ref 0 in
    (match R.with_launch ~sw permit (fun _ ~storage:_ -> incr count;raise Interrupted) with
     | exception Interrupted -> ()
     | R.Not_performed _ | R.Performed _ -> fail "launch exception did not propagate");
    (match R.with_launch ~sw permit (fun _ ~storage:_ -> incr count) with
     | R.Not_performed R.Launch_intent_spent -> ()
     | R.Not_performed _ | R.Performed _ -> fail "an exception replayed the consumed launch");
    check int "an uncertain callback outcome cannot execute twice" 1 !count)

let test_busy_owner_does_not_block_other_owner () = fixture (fun ~env ~sw ~root:_ ~registry ~open_root:_ ->
  Eio.Time.with_timeout_exn env#clock 10. (fun () ->
    let b=binding (id "05") in let permit=admitted registry b |> commit in
    let entered,signal=Eio.Promise.create () in let release_startup,unblock=Eio.Promise.create () in
    let finished,finish=Eio.Promise.create () in
    let release ()=if Eio.Promise.peek release_startup=None then Eio.Promise.resolve unblock () in
    Fun.protect ~finally:release (fun () ->
      Eio.Fiber.fork ~sw (fun () -> Eio.Promise.resolve finish
        (R.with_launch ~sw permit (fun _ ~storage:_ -> Eio.Promise.resolve signal ();Eio.Promise.await release_startup;"first")));
      Eio.Promise.await entered;
      check bool "same operation is observed busy without waiting" true (R.load registry ~binding:b=Error R.Busy);
      let other=admitted registry (binding (id "07")) |> commit in
      check string "an independent operation progresses before the first startup releases" "independent"
        (R.with_launch ~sw other (fun _ ~storage:_ -> "independent") |> completed);
      check bool "first callback is genuinely still active" true (Eio.Promise.peek finished=None);
      release ();
      check string "original callback settles after its own release" "first" (Eio.Promise.await finished |> completed))))

let test_missing_or_corrupt_original_does_not_reconstruct () =
  List.iter (fun fault -> fixture (fun ~env:_ ~sw ~root ~registry ~open_root:_ ->
    let b=binding (id "05") in ignore (admitted registry b);
    let job=job_path root b and claim=claim_path root b in
    (match fault with
     | `Job_missing -> Unix.rename job (job ^ ".evidence")
     | `Original_missing -> Unix.unlink (Filename.concat job "original.json")
     | `Claim_corrupt -> Unix.chmod claim 0o600;Out_channel.with_open_bin claim (fun oc -> output_string oc "{truncated");Unix.chmod claim 0o400
     | `Job_replaced ->
       Unix.rename job (job ^ ".evidence");Unix.mkdir job 0o700;
       List.iter (fun name ->
         let content=In_channel.with_open_bin (Filename.concat (job ^ ".evidence") name) In_channel.input_all in
         let path=Filename.concat job name in Out_channel.with_open_bin path (fun oc -> output_string oc content);
         Unix.chmod path (if name="lease" then 0o600 else 0o400)) ["original.json";"admission_id";"lease"]);
    rejected "damaged original cannot be treated as another Start"
      (R.admit registry ~new_admission_id:(id "99") ~binding:b ~spec);
    (match fault with
     | `Job_missing -> check bool "missing Ready job is never recreated" false (Sys.file_exists job)
     | `Original_missing -> check bool "lost original payload is never reconstructed" false (Sys.file_exists (Filename.concat job "original.json"))
     | `Claim_corrupt | `Job_replaced -> ());
    let healthy=admitted registry (binding (id "07")) |> commit in
    check string "corruption is confined to its original operation" "healthy"
      (R.with_launch ~sw healthy (fun _ ~storage:_ -> "healthy") |> completed)))
    [`Job_missing;`Original_missing;`Claim_corrupt;`Job_replaced]

let test_owner_boot_and_execution_identity_cannot_retarget () = fixture (fun ~env:_ ~sw:_ ~root:_ ~registry ~open_root ->
  let b=binding (id "05") in ignore (admitted registry b);
  let other_spec=P.spec ~domain:P.Workspace_process ~argv:["/bin/echo";"replacement"] ~env:[]
    ~cwd:"/work/original" ~remote_root:"/work" ~stdin:"" ~mode:Effect ~network_policy_sha256:None |> require in
  let other=P.binding ~route ~owner ~operation_id:b.operation_id ~invocation_sha256:b.invocation_sha256
    ~spec_sha256:(P.spec_sha256 other_spec) |> require in
  check bool "same operation ID cannot carry a changed original specification" true
    (R.admit registry ~new_admission_id:(id "99") ~binding:other ~spec:other_spec=Error R.Binding_mismatch);
  let rebooted=open_root ~route:{route with boot_id=id "08"} () |> get in
  let original=R.load rebooted ~binding:b |> get in
  check bool "old boot can be inspected without moving its binding" true (R.binding original=b);
  check bool "new boot never launches the old operation" true
    (R.commit_launch original ~confirmed_admission_id:(id "04") ~launch_id:(id "06")=Error R.Endpoint_replaced);
  let changed=open_root ~payload_uid:(chosen_payload_uid ()+1) () |> get in
  let original=R.load changed ~binding:b |> get in
  check bool "config cannot silently change the original payload identity" true
    (R.commit_launch original ~confirmed_admission_id:(id "04") ~launch_id:(id "06")=Error R.Execution_identity_changed))

let test_private_authority_and_filesystem_aliases () =
  fixture (fun ~env ~sw ~root ~registry:_ ~open_root ->
    rejected "same UID directory is not protection" (open_root ~payload_uid:(Unix.geteuid ()) ());
    rejected "root payload needs an actual namespace boundary" (open_root ~payload_uid:0 ());
    Unix.chmod root 0o755;rejected "control root cannot be public" (open_root ());Unix.chmod root 0o700;
    let alias=root ^ ".alias" in Unix.symlink root alias;
    Fun.protect ~finally:(fun () -> Unix.unlink alias) (fun () ->
      rejected "root leaf symlink never supplies control authority"
        (R.open_registry ~sw ~fs:env#fs ~root_path:alias ~route ~owner ~payload_uid:(chosen_payload_uid ()))));
  List.iter (fun attack -> fixture (fun ~env:_ ~sw:_ ~root ~registry ~open_root:_ ->
    let b=binding (id "05") in ignore (admitted registry b);
    let original=Filename.concat (job_path root b) "original.json" in
    let outside=Filename.concat root "outside-evidence" in
    let content=In_channel.with_open_bin original In_channel.input_all in
    Out_channel.with_open_bin outside (fun oc -> output_string oc content);Unix.chmod outside 0o400;
    Unix.unlink original;
    (match attack with `Symlink -> Unix.symlink outside original | `Hardlink -> Unix.link outside original);
    rejected "symlink and multiply linked originals refuse" (R.load registry ~binding:b);
    check string "outside evidence is never modified by failed recovery" content
      (In_channel.with_open_bin outside In_channel.input_all))) [`Symlink;`Hardlink]

let cancel record =
  R.request_cancel record ~confirmed_admission_id:(R.admission_id record) |> get

let test_cancel_before_launch_preserves_original_and_blocks_admission () =
  fixture (fun ~env:_ ~sw:_ ~root:_ ~registry ~open_root ->
    let b=binding (id "05") in let original=admitted registry b in
    check bool "another admission cannot cancel this operation" true
      (R.request_cancel original ~confirmed_admission_id:(id "99")=Error R.Binding_mismatch);
    let cancelled=cancel original in
    check int64 "cancellation advances the ready head once" 2L (R.revision cancelled);
    check bool "cancellation is retained before any callback" true
      (R.cancellation_state cancelled=R.Cancellation_requested && R.launch_state cancelled=R.Not_requested);
    let recovered=R.load (open_root () |> get) ~binding:b |> get in
    check bool "reopen preserves the same cancelled input and admission" true
      (R.cancellation_state recovered=R.Cancellation_requested && R.specification recovered=spec
       && R.admission_id recovered=R.admission_id original);
    let duplicate=cancel original in
    check int64 "duplicate cancellation does not create another revision" (R.revision recovered) (R.revision duplicate);
    let repeated=R.admit registry ~new_admission_id:(id "99") ~binding:b ~spec |> get in
    check bool "repeating Start cannot resurrect a cancelled original" true
      (R.cancellation_state repeated=R.Cancellation_requested && R.admission_id repeated=R.admission_id original);
    check bool "the stale ready record cannot obtain a launch permit" true
      (R.commit_launch original ~confirmed_admission_id:(id "04") ~launch_id:(id "06")=Error R.Launch_cancelled);
    check bool "the recovered cancellation cannot obtain a launch permit" true
      (R.commit_launch recovered ~confirmed_admission_id:(id "04") ~launch_id:(id "06")=Error R.Launch_cancelled))

let test_cancel_wins_over_an_unconsumed_launch_permit () =
  fixture (fun ~env:_ ~sw ~root:_ ~registry ~open_root ->
    let b=binding (id "05") in let original=admitted registry b in
    let permit=commit original in
    let cancelled=cancel original in
    check int64 "cancellation follows the original launch intent" 3L (R.revision cancelled);
    check bool "the cancelled record preserves the original launch ID" true
      (R.launch_state cancelled=R.Requested (id "06") && R.cancellation_state cancelled=R.Cancellation_requested);
    let count=ref 0 in
    (match R.with_launch ~sw permit (fun _ ~storage:_ -> incr count) with
     | R.Not_performed R.Launch_cancelled -> ()
     | R.Not_performed _ | R.Performed _ -> fail "a cancelled issued permit entered its callback");
    check int "no payload startup callback ran" 0 !count;
    let recovered=R.load (open_root () |> get) ~binding:b |> get in
    check bool "recovered cancellation still identifies the same launch" true
      (R.launch_state recovered=R.Requested (id "06") && R.cancellation_state recovered=R.Cancellation_requested);
    check int64 "duplicate cancel of a launched intent remains idempotent" 3L (R.revision (cancel original)))

let test_lost_cancel_reply_is_reconciled_without_republication () =
  List.iter (fun launch_requested -> fixture (fun ~env:_ ~sw:_ ~root:_ ~registry ~open_root ->
    let b=binding (id "05") in let original=admitted registry b in
    if launch_requested then ignore (commit original);
    (match R.For_testing.request_cancel ~after_publication:(fun () -> raise Interrupted)
        original ~confirmed_admission_id:(id "04") with
     | exception Interrupted -> ()
     | Ok _ | Error _ -> fail "lost cancellation reply boundary was not reached");
    let reopened=open_root () |> get in
    let recovered=R.load reopened ~binding:b |> get in
    check bool "lost reply does not lose cancellation intent" true
      (R.cancellation_state recovered=R.Cancellation_requested);
    let again=R.For_testing.request_cancel ~after_publication:(fun () -> fail "duplicate cancel published again")
        recovered ~confirmed_admission_id:(id "04") |> get in
    check int64 "retry acknowledges the original cancellation revision" (R.revision recovered) (R.revision again);
    check bool "retry cannot rewrite the original launch identity" true
      (R.launch_state recovered=R.launch_state again && R.admission_id recovered=R.admission_id again)))
    [false;true]

let test_cancel_race_with_active_startup_leaves_other_jobs_progressing () =
  fixture (fun ~env ~sw ~root:_ ~registry ~open_root:_ ->
    Eio.Time.with_timeout_exn env#clock 10. (fun () ->
      let original=admitted registry (binding (id "05")) in let permit=commit original in
      let entered,signal=Eio.Promise.create () in let release_startup,unblock=Eio.Promise.create () in
      let finished,finish=Eio.Promise.create () in
      let release ()=if Eio.Promise.peek release_startup=None then Eio.Promise.resolve unblock () in
      Fun.protect ~finally:release (fun () ->
        Eio.Fiber.fork ~sw (fun () -> Eio.Promise.resolve finish
          (R.with_launch ~sw permit (fun _ ~storage:_ -> Eio.Promise.resolve signal ();Eio.Promise.await release_startup;"started")));
        Eio.Promise.await entered;
        check bool "cancel does not wait while that startup is active" true
          (R.request_cancel original ~confirmed_admission_id:(id "04")=Error R.Busy);
        let other=admitted registry (binding (id "07")) in let other_cancelled=cancel other in
        check bool "independent cancellation commits before the first startup releases" true
          (R.cancellation_state other_cancelled=R.Cancellation_requested && Eio.Promise.peek finished=None);
        release ();
        check string "the actual startup result survives the concurrent request" "started"
          (Eio.Promise.await finished |> completed);
        let cancelled=cancel original in
        check bool "the same original can be cancelled after its startup settles" true
          (R.cancellation_state cancelled=R.Cancellation_requested && R.launch_state cancelled=R.Requested (id "06")))))

let test_cancel_keeps_boot_and_payload_identity_authority () =
  fixture (fun ~env:_ ~sw ~root:_ ~registry ~open_root ->
    let b=binding (id "05") in ignore (admitted registry b);
    let rebooted=open_root ~route:{route with boot_id=id "08"} () |> get in
    let old=R.load rebooted ~binding:b |> get in
    check bool "a replaced endpoint cannot cancel its old boot" true
      (R.request_cancel old ~confirmed_admission_id:(id "04")=Error R.Endpoint_replaced);
    let changed=open_root ~payload_uid:(chosen_payload_uid ()+1) () |> get in
    let old=R.load changed ~binding:b |> get in
    check bool "changed payload configuration cannot retarget cancellation" true
      (R.request_cancel old ~confirmed_admission_id:(id "04")=Error R.Execution_identity_changed);
    let original=R.load registry ~binding:b |> get in
    check bool "rejected cancellation leaves the original executable" true
      (R.cancellation_state original=R.No_cancellation);
    check string "the original identity still owns its permitted startup" "original"
      (R.with_launch ~sw (commit original) (fun _ ~storage:_ -> "original") |> completed))

let test_uncertain_cancel_requires_successful_original_resync () =
  List.iter (fun launch_requested -> fixture (fun ~env:_ ~sw:_ ~root ~registry ~open_root ->
    let b=binding (id "05") in let original=admitted registry b in
    if launch_requested then ignore (commit original);
    let fault=Recovery_test.parent_sync_dispatch_fault
        ~exception_:(Sys_error "injected cancellation parent sync failure") in
    (match Recovery_test.with_replace_dispatch_fault fault (fun () ->
        R.request_cancel original ~confirmed_admission_id:(id "04")) with
     | Error (R.Publication_failed failure) ->
       check bool "the real cancellation rename completed before failure" true
         (failure.target_effect=Fs_compat.Target_replaced);
       (match failure.primary_failure with
        | Fs_compat.Write_primary_failure failed ->
          check bool "publication parent sync actually failed" true (failed.stage=Fs_compat.Sync_parent)
        | Fs_compat.Recovery_primary_failure _ | Fs_compat.Recovery_access_primary_failure _ ->
          fail "the injected failure did not reach the publication parent sync");
       check bool "cleanup could not confirm the parent sync either" true
         (List.exists (function
           | Fs_compat.Write_cleanup_failure failed -> failed.stage=Fs_compat.Cleanup_sync_parent
           | Fs_compat.Recovery_cleanup_failure _ -> false) failure.cleanup_failures)
     | Error error -> fail (R.error_to_string error)
     | Ok _ -> fail "an uncertain cancellation publication was acknowledged");
    let reopened=open_root () |> get in
    let pending=R.load reopened ~binding:b |> get in
    check bool "visible cancellation still names the exact original" true
      (R.cancellation_state pending=R.Cancellation_requested && R.binding pending=b
       && R.admission_id pending=id "04" && R.specification pending=spec);
    let claim=claim_path root b in
    let inode=(Unix.lstat claim).st_ino in
    let bytes=In_channel.with_open_bin claim In_channel.input_all in
    let sync_attempts=ref 0 in
    let no_publication ()=fail "a duplicate cancellation republished its claim" in
    (match R.For_testing.request_cancel
        ~before_resync_parent:(fun () -> incr sync_attempts;raise (Unix.Unix_error (Unix.EIO,"fsync","cancel parent")))
        ~after_publication:no_publication pending ~confirmed_admission_id:(id "04") with
     | Error (R.Authority_unavailable _) -> ()
     | Error error -> fail (R.error_to_string error)
     | Ok _ -> fail "a duplicate cancellation acknowledged a failed resync");
    check int "failed retry entered the real parent sync boundary" 1 !sync_attempts;
    let unchanged=R.load reopened ~binding:b |> get in
    check int64 "failed resync leaves the same cancellation revision" (R.revision pending) (R.revision unchanged);
    let confirmed=R.For_testing.request_cancel
        ~before_resync_parent:(fun () -> incr sync_attempts)
        ~after_publication:no_publication unchanged ~confirmed_admission_id:(id "04") |> get in
    check int "successful retry also settles the actual parent sync" 2 !sync_attempts;
    check int64 "durable duplicate ACK preserves the original revision" (R.revision pending) (R.revision confirmed);
    check bool "durable duplicate ACK preserves admission, input and launch coordinates" true
      (R.binding confirmed=b && R.admission_id confirmed=R.admission_id pending
       && R.specification confirmed=R.specification pending && R.payload_uid confirmed=R.payload_uid pending
       && R.launch_state confirmed=R.launch_state pending && R.cancellation_state confirmed=R.Cancellation_requested);
    check int "resync never replaces the original cancellation inode" inode (Unix.lstat claim).st_ino;
    check string "resync never rewrites the original cancellation bytes" bytes
      (In_channel.with_open_bin claim In_channel.input_all))) [false;true]

let test_cancel_rejects_rebound_job_and_known_launch_coordinates () =
  List.iter (fun fault -> fixture (fun ~env:_ ~sw ~root ~registry ~open_root:_ ->
    let b=binding (id "05") in let ready=admitted registry b in
    let permit,original=match fault with
      | `Job_rebound -> None,ready
      | `Known_launch_rebound | `Cancelled_launch_rebound ->
        let permit=commit ready in
        Some permit,(R.load registry ~binding:b |> get)
      | `Cancelled_ready_resurrected -> None,cancel ready in
    if fault=`Cancelled_launch_rebound then ignore (cancel original);
    let claim=claim_path root b in
    let json=Yojson.Safe.from_file claim in
    let fields=match json with `Assoc fields -> fields | _ -> fail "fixture claim is not an object" in
    let replace key value fields = (key,value)::List.remove_assoc key fields in
    let fields=match fault with
      | `Job_rebound ->
        let job=job_path root b in Unix.rename job (job ^ ".evidence");Unix.mkdir job 0o700;
        List.iter (fun name ->
          let content=In_channel.with_open_bin (Filename.concat (job ^ ".evidence") name) In_channel.input_all in
          let target=Filename.concat job name in Out_channel.with_open_bin target (fun oc -> output_string oc content);
          Unix.chmod target (if name="lease" then 0o600 else 0o400)) ["admission_id";"original.json";"lease"];
        let stat=Unix.lstat job in
        fields |> replace "job_device" (`String (string_of_int stat.st_dev))
          |> replace "job_inode" (`String (string_of_int stat.st_ino))
      | `Known_launch_rebound | `Cancelled_launch_rebound ->
        replace "launch_id" (`String (P.Id.to_string (id "07"))) fields
      | `Cancelled_ready_resurrected ->
        fields |> replace "state" (`String "launch_requested")
          |> replace "launch_id" (`String (P.Id.to_string (id "07"))) in
    Unix.chmod claim 0o600;
    Yojson.Safe.to_file claim (`Assoc fields);Unix.chmod claim 0o400;
    let before=In_channel.with_open_bin claim In_channel.input_all in
    ignore (R.load registry ~binding:b |> get);
    check bool "stale original never cancels rebound execution coordinates" true
      (R.request_cancel original ~confirmed_admission_id:(id "04")=Error R.Stale_record);
    check string "rejection publishes no cancellation over the rebound claim" before
      (In_channel.with_open_bin claim In_channel.input_all);
    Option.iter (fun permit ->
      let entered=ref false in
      (match R.with_launch ~sw permit (fun _ ~storage:_ -> entered:=true) with
       | R.Not_performed R.Stale_record -> ()
       | R.Not_performed _ | R.Performed _ -> fail "rebound original was not rejected before cancellation/launch");
      check bool "no rebound startup callback ran" false !entered) permit))
    [`Job_rebound;`Known_launch_rebound;`Cancelled_launch_rebound;`Cancelled_ready_resurrected]

let test_launch_storage_is_original_and_job_owned () = fixture (fun ~env ~sw:_ ~root ~registry ~open_root:_ ->
  let b=binding (id "05") in let permit=admitted registry b |> commit in
  let storage=Eio.Switch.run (fun job_sw ->
    let storage=R.with_launch ~sw:job_sw permit (fun _ ~storage ->
      let stat=Eio.Path.stat ~follow:true storage in
      let target=Fs_compat.capability_publication_target
        ~allowed_root_path:(job_path root b) ~allowed_root_device:stat.dev ~allowed_root_inode:stat.ino
        ~parent_components:[] ~target_leaf:"supervisor.json" ~permissions:0o400
        |> Result.map_error Fs_compat.capability_publication_target_error_to_string |> require in
      let recovery=Fs_compat.Publication_recovery.open_registry ~sw:job_sw ~fs:env#fs ~registry_root:storage
        |> Result.map_error Fs_compat.Publication_recovery.registry_error_to_string |> require in
      let published=Fs_compat.Publication_recovery.with_lane ~registry:recovery ~owner:"supervisor" (fun recovery ->
        Fs_compat.create_capability_file_exclusive ~recovery ~parent:storage ~target "original rendezvous"
        |> Result.map_error Fs_compat.capability_write_error_to_string |> require)
        |> Result.map_error Fs_compat.Publication_recovery.lane_open_error_to_string |> require in
      (match published with
       | Lane_released () -> ()
       | Lane_release_failed {release_failure;_} -> fail
           (Fs_compat.Publication_recovery.lane_release_failure_to_string release_failure));
      storage) |> completed in
    check string "storage survives callback return for output/result publication" "original rendezvous"
      (Eio.Path.load Eio.Path.(storage / "supervisor.json"));
    let job=job_path root b in Unix.rename job (job ^ ".evidence");Unix.mkdir job 0o700;
    Out_channel.with_open_bin (Filename.concat job "supervisor.json") (fun oc -> output_string oc "replacement");
    check string "opened capability never follows the replacement pathname" "original rendezvous"
      (Eio.Path.load Eio.Path.(storage / "supervisor.json"));
    storage) in
  let unavailable=match Eio.Path.load Eio.Path.(storage / "supervisor.json") with
    | _ -> false
    | exception Invalid_argument _ -> true
    | exception Eio.Io _ -> true in
  check bool "ending the per-job switch actually revokes original storage I/O" true unavailable)

let test_launch_rejects_storage_swap_before_effect () = fixture (fun ~env:_ ~sw ~root ~registry ~open_root:_ ->
  let b=binding (id "05") in let permit=admitted registry b |> commit in
  let job=job_path root b and entered=ref false in
  let result=R.For_testing.with_launch ~sw ~after_original:(fun () ->
      Unix.rename job (job ^ ".evidence");Unix.mkdir job 0o700)
      permit (fun _ ~storage:_ -> entered:=true) in
  (match result with
   | R.Not_performed (R.Corrupt_original _) -> ()
   | R.Not_performed _ | R.Performed _ -> fail "replacement storage reached launch callback");
  check bool "no payload or supervisor callback effect ran" false !entered;
  Unix.rmdir job;Unix.rename (job ^ ".evidence") job;
  (match R.with_launch ~sw permit (fun _ ~storage:_ -> entered:=true) with
   | R.Not_performed R.Launch_intent_spent -> ()
   | R.Not_performed _ | R.Performed _ -> fail "failed storage validation replayed launch permission");
  check bool "restoring original authority does not unspend permission" false !entered)

let test_cancelled_job_scope_never_enters_launch () = fixture (fun ~env:_ ~sw ~root:_ ~registry ~open_root:_ ->
  let permit=admitted registry (binding (id "05")) |> commit in let entered=ref false in
  (match Eio.Switch.run (fun job_sw ->
     Eio.Switch.fail job_sw Interrupted;
     ignore (R.with_launch ~sw:job_sw permit (fun _ ~storage:_ -> entered:=true))) with
   | exception Interrupted -> ()
   | () -> fail "cancelled supervisor resource scope did not propagate");
  check bool "cancelled supervisor acquired no launch effect" false !entered;
  check string "pre-entry cancellation did not consume the original permit" "original"
    (R.with_launch ~sw permit (fun _ ~storage:_ -> "original") |> completed))

let test_original_storage_read_survives_boot_without_launch () = fixture (fun ~env:_ ~sw ~root:_ ~registry ~open_root ->
  let b=binding (id "05") in let first=admitted registry b in
  let rebooted=open_root ~route:{route with boot_id=id "08"} () |> get in
  let original=R.load rebooted ~binding:b |> get in
  let storage=R.open_storage ~sw original |> get in
  let stored=Eio.Path.load Eio.Path.(R.storage_path storage / "original.json") in
  let request=P.request_of_json (Yojson.Safe.from_string stored) |> Result.map_error P.error_to_string |> require in
  check bool "old boot reads the exact immutable original through its owned capability" true
    (request=P.Start {binding=b;spec});
  check bool "storage read never promotes registration into a launch" true
    (R.launch_state (R.storage_record storage)=R.Not_requested && R.revision first=1L);
  let refreshed=R.refresh (R.storage_record storage) |> get in
  check bool "refresh retains its original admission and boot" true
    (R.binding refreshed=b && R.admission_id refreshed=id "04");
  check bool "old boot read does not restore an effect permit" true
    (R.commit_launch refreshed ~confirmed_admission_id:(id "04") ~launch_id:(id "06")=Error R.Endpoint_replaced))

let test_open_storage_pins_actual_registry_and_rejects_rebound_job () = fixture (fun ~env ~sw ~root ~registry ~open_root:_ ->
  let b=binding (id "05") in let original=admitted registry b in
  let other_root=Filename.concat root "alternate" in Unix.mkdir other_root 0o700;
  let other=R.open_registry ~sw ~fs:env#fs ~root_path:other_root ~route ~owner ~payload_uid:(chosen_payload_uid ()) |> get in
  let alternate=admitted other b in
  check bool "alternate registry deliberately has identical public coordinates" true
    (R.binding original=R.binding alternate && R.admission_id original=R.admission_id alternate
      && R.specification original=R.specification alternate && R.revision original=R.revision alternate);
  let write_marker job text=Out_channel.with_open_bin (Filename.concat job "marker") (fun oc -> output_string oc text) in
  let job=job_path root b in
  write_marker job "actual original";write_marker (job_path other_root b) "matching alternate";
  let storage=R.open_storage ~sw original |> get in
  check string "source record selects its actual registry, not a matching one" "actual original"
    (Eio.Path.load Eio.Path.(R.storage_path storage / "marker"));
  Unix.rename job (job ^ ".evidence");Unix.mkdir job 0o700;
  List.iter (fun name ->
    let content=In_channel.with_open_bin (Filename.concat (job ^ ".evidence") name) In_channel.input_all in
    let path=Filename.concat job name in Out_channel.with_open_bin path (fun oc -> output_string oc content);
    Unix.chmod path (if name="lease" then 0o600 else 0o400)) ["admission_id";"original.json";"lease"];
  write_marker job "replacement";
  let claim=claim_path root b in
  let fields=match Yojson.Safe.from_file claim with `Assoc fields -> fields
    | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ -> fail "claim object missing" in
  let stat=Unix.lstat job in
  let fields=List.map (fun (key,value) -> key,match key with
    | "job_device" -> `String (string_of_int stat.st_dev)
    | "job_inode" -> `String (string_of_int stat.st_ino)
    | _ -> value) fields in
  Unix.chmod claim 0o600;Yojson.Safe.to_file claim (`Assoc fields);Unix.chmod claim 0o400;
  ignore (R.load registry ~binding:b |> get);
  check bool "opaque original rejects a self-consistent replacement job" true (R.refresh original=Error R.Stale_record);
  check bool "reopening does not adopt the replacement job" true (R.open_storage ~sw original=Error R.Stale_record);
  check string "already opened capability still reads the original inode" "actual original"
    (Eio.Path.load Eio.Path.(R.storage_path storage / "marker")))

let test_storage_contention_and_known_launch_revalidation () = fixture (fun ~env ~sw ~root ~registry ~open_root:_ ->
  Eio.Time.with_timeout_exn env#clock 10. (fun () ->
    let b=binding (id "05") in let original=admitted registry b in let permit=commit original in
    let entered,signal=Eio.Promise.create () and resume,release=Eio.Promise.create () in
    let done_,finish=Eio.Promise.create () in
    let unblock ()=if Eio.Promise.peek resume=None then Eio.Promise.resolve release () in
    Fun.protect ~finally:unblock (fun () ->
      Eio.Fiber.fork ~sw (fun () -> Eio.Promise.resolve finish
        (R.with_launch ~sw permit (fun _ ~storage:_ -> Eio.Promise.resolve signal ();Eio.Promise.await resume)));
      Eio.Promise.await entered;
      check bool "original storage reports startup busy without waiting" true (R.open_storage ~sw original=Error R.Busy);
      let next=admitted registry (binding (id "07")) in
      ignore (R.open_storage ~sw next |> get);
      check bool "another original storage opened before the first startup released" true (Eio.Promise.peek done_=None);
      unblock ();ignore (Eio.Promise.await done_ |> completed));
    let storage=R.open_storage ~sw original |> get in let known=R.storage_record storage in
    check bool "read capability captures the actual already-issued launch" true (R.launch_state known=R.Requested (id "06"));
    let cancelled=R.request_cancel known ~confirmed_admission_id:(id "04") |> get in
    let refreshed=R.refresh known |> get in
    check bool "refresh observes legitimate durable cancellation of the same launch" true
      (R.cancellation_state refreshed=R.Cancellation_requested && R.revision refreshed=R.revision cancelled);
    let path=claim_path root b in
    let fields=match Yojson.Safe.from_file path with `Assoc fields -> fields
      | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ -> fail "claim object missing" in
    let fields=List.map (fun (key,value) -> key,(if key="launch_id" then `String (P.Id.to_string (id "09")) else value)) fields in
    Unix.chmod path 0o600;Yojson.Safe.to_file path (`Assoc fields);Unix.chmod path 0o400;
    ignore (R.load registry ~binding:b |> get);
    check bool "refresh never adopts another known launch with matching admission" true (R.refresh known=Error R.Stale_record);
    check bool "storage open never adopts another known launch" true (R.open_storage ~sw known=Error R.Stale_record)))

let test_original_readers_overlap_without_admitting_writers () = fixture (fun ~env:_ ~sw ~root:_ ~registry ~open_root:_ ->
  let b=binding (id "05") in let original=admitted registry b in
  let entered,signal=Eio.Promise.create () and done_,finish=Eio.Promise.create () in
  Eio.Fiber.fork ~sw (fun () ->
    let interrupted=match Eio.Switch.run (fun reader_sw ->
      ignore (R.For_testing.refresh original ~after_lock:(fun () ->
        Eio.Promise.resolve signal reader_sw;Eio.Fiber.await_cancel ()) |> get)) with
      | () -> false
      | exception Interrupted -> true in
    Eio.Promise.resolve finish interrupted);
  let first_scope=Eio.Promise.await entered in
  let second=R.For_testing.refresh original ~after_lock:(fun () ->
    let loaded=R.load registry ~binding:b |> get in
    let refreshed=R.refresh original |> get in
    let storage=R.open_storage ~sw original |> get in
    check bool "overlapping original readers preserve the same exact source" true
      (R.admission_id loaded=R.admission_id original && R.revision refreshed=R.revision original
        && R.specification (R.storage_record storage)=R.specification original);
    check bool "both shared readers remain admitted together" true (Eio.Promise.peek done_=None);
    check bool "launch intent refuses active original readers without waiting" true
      (R.commit_launch original ~confirmed_admission_id:(id "04") ~launch_id:(id "06")=Error R.Busy);
    check bool "cancellation refuses active original readers without waiting" true
      (R.request_cancel original ~confirmed_admission_id:(id "04")=Error R.Busy);
    let independent=admitted registry (binding (id "07")) in
    let permit=commit independent in
    ignore (R.with_launch ~sw permit (fun _ ~storage:_ -> ()) |> completed);
    check bool "independent job commits and enters its original launch while readers remain" true
      (Eio.Promise.peek done_=None);
    Eio.Switch.fail first_scope Interrupted;
    check bool "reader cancellation preserves its original exception and closes its lease" true
      (Eio.Promise.await done_);
    check bool "closing one reader never releases the other reader's shared lease" true
      (R.request_cancel original ~confirmed_admission_id:(id "04")=Error R.Busy)) |> get in
  check bool "the remaining reader still returns the original unchanged record" true
    (R.revision second=R.revision original && R.cancellation_state second=R.No_cancellation);
  let cancelled=R.request_cancel original ~confirmed_admission_id:(id "04") |> get in
  check bool "exclusive original mutation succeeds after every shared reader releases" true
    (R.cancellation_state cancelled=R.Cancellation_requested && R.revision cancelled=2L))

let test_cancelled_admission_proves_no_known_launch () = fixture (fun ~env:_ ~sw ~root:_ ~registry ~open_root ->
  let b=binding (id "05") in let original=admitted registry b in
  check bool "uncancelled admission grants no non-start proof" true
    (R.settle_cancelled_admission ~sw original=Error R.Stale_record);
  let cancelled=R.request_cancel original ~confirmed_admission_id:(id "04") |> get in
  let proof=R.settle_cancelled_admission ~sw original |> get in
  let source=R.unlaunched_storage proof |> R.storage_record in
  check bool "no-launch proof preserves exact cancelled input and original admission" true
    (R.specification source=spec && R.admission_id source=id "04"
      && R.cancellation_state source=R.Cancellation_requested && R.launch_state source=R.Not_requested);
  check bool "non-start proof grants no launch permission" true
    (R.commit_launch cancelled ~confirmed_admission_id:(id "04") ~launch_id:(id "06")=Error R.Launch_cancelled);
  let rebooted=open_root ~route:{route with boot_id=id "08"} () |> get in
  let historical=R.load rebooted ~binding:b |> get |> R.settle_cancelled_admission ~sw |> get in
  check bool "durable cancellation before any launch remains historical proof after boot change" true
    (R.unlaunched_storage historical |> R.storage_record |> R.launch_state=R.Not_requested))

let test_retire_only_unused_cancelled_original_permit () = fixture (fun ~env:_ ~sw ~root ~registry ~open_root:_ ->
  let b=binding (id "05") in let original=admitted registry b in let permit=commit original in
  check bool "uncancelled permit cannot be retired as non-start" true
    (R.retire_cancelled_launch ~sw permit=Error R.Stale_record);
  let current=R.request_cancel original ~confirmed_admission_id:(id "04") |> get in
  check bool "known launch is never proven absent from its cancellation flag" true
    (R.settle_cancelled_admission ~sw current=Error R.Launch_already_requested);
  let invoked=ref false in
  (match R.with_launch ~sw permit (fun _ ~storage:_ -> invoked:=true) with
   | R.Not_performed R.Launch_cancelled -> ()
   | Not_performed _ | Performed _ -> fail "durable cancellation did not win callback admission");
  let claim=claim_path root b in
  Unix.rename claim (claim ^ ".evidence");
  check bool "missing original cancellation authority cannot retire a permit" true
    (R.retire_cancelled_launch ~sw permit=Error R.Missing_original);
  Unix.rename (claim ^ ".evidence") claim;
  let proof=R.retire_cancelled_launch ~sw permit |> get in
  let again=R.retire_cancelled_launch ~sw permit |> get in
  let original_storage=R.unlaunched_storage proof and reopened=R.unlaunched_storage again in
  check bool "retirement retains only the same original known launch" true
    (R.launch_state (R.storage_record original_storage)=R.Requested (id "06")
      && R.specification (R.storage_record reopened)=spec);
  let first=Eio.Path.stat ~follow:true (R.storage_path original_storage)
  and second=Eio.Path.stat ~follow:true (R.storage_path reopened) in
  check bool "repeated retirement reopens the same original storage" true (first.dev=second.dev && first.ino=second.ino);
  check bool "proof retirement never invokes the original callback" false !invoked)

let test_used_permit_never_becomes_nonstart_after_cancellation () = fixture (fun ~env:_ ~sw ~root ~registry ~open_root:_ ->
  let b=binding (id "05") in let original=admitted registry b in let permit=commit original in
  let marker=Filename.concat root "original-callback-effect" in
  ignore (R.with_launch ~sw permit (fun _ ~storage:_ ->
    Out_channel.with_open_bin marker (fun oc -> output_string oc "original effect")) |> completed);
  ignore (R.request_cancel original ~confirmed_admission_id:(id "04") |> get);
  (match R.with_launch ~sw permit (fun _ ~storage:_ -> fail "spent callback replayed") with
   | R.Not_performed R.Launch_cancelled -> ()
   | Not_performed _ | Performed _ -> fail "actual cancellation-before-spent-check boundary changed");
  check bool "cancelled outcome cannot retire a previously reserved original permit" true
    (R.retire_cancelled_launch ~sw permit=Error R.Launch_intent_spent);
  check string "failed non-start proof preserves the actual callback's effect" "original effect"
    (In_channel.with_open_bin marker In_channel.input_all);
  let independent=admitted registry (binding (id "07")) in
  ignore (R.with_launch ~sw (commit independent) (fun _ ~storage:_ -> ()) |> completed))

let test_cancelled_retirement_keeps_permit_retired () = fixture (fun ~env:_ ~sw ~root:_ ~registry ~open_root:_ ->
  let b=binding (id "05") in let original=admitted registry b in let permit=commit original in
  ignore (R.request_cancel original ~confirmed_admission_id:(id "04") |> get);
  let entered,signal=Eio.Promise.create () in let interrupted=ref false in
  Eio.Fiber.first
    (fun () -> try
      ignore (R.For_testing.retire_cancelled_launch ~sw permit ~after_retirement:(fun () ->
        Eio.Promise.resolve signal ();Eio.Fiber.await_cancel ()) |> get);
      fail "paused original retirement returned a proof before opening its storage"
      with Eio.Cancel.Cancelled _ as ex -> interrupted:=true;raise ex)
    (fun () -> Eio.Promise.await entered;
      check bool "original retirement still excludes another original observer without waiting" true
        (R.refresh original=Error R.Busy);
      let independent=admitted registry (binding (id "07")) in
      ignore (R.with_launch ~sw (commit independent) (fun _ ~storage:_ -> ()) |> completed));
  check bool "retirement observer cancellation propagates and releases its lease" true !interrupted;
  let proof=R.retire_cancelled_launch ~sw permit |> get in
  check bool "interrupted storage open can resume only the same retired cancelled source" true
    (R.unlaunched_storage proof |> R.storage_record |> R.cancellation_state=R.Cancellation_requested);
  (match R.with_launch ~sw permit (fun _ ~storage:_ -> fail "retired permit became fresh after interruption") with
   | R.Not_performed R.Launch_cancelled -> ()
   | Not_performed _ | Performed _ -> fail "retired original no longer retains its durable cancellation"))

let test_uncertain_cancel_requires_resync_before_nonstart_proof launch_requested =
  fixture (fun ~env:_ ~sw ~root ~registry ~open_root ->
    let b=binding (id "05") in let original=admitted registry b in
    let permit=if launch_requested then Some (commit original) else None in
    let fault=Recovery_test.parent_sync_dispatch_fault
        ~exception_:(Unix.Unix_error (Unix.EIO,"fsync","cancel parent")) in
    (match Recovery_test.with_replace_dispatch_fault fault (fun () ->
        R.request_cancel original ~confirmed_admission_id:(id "04")) with
     | Error (R.Publication_failed failure) ->
       check bool "uncertain cancellation actually replaced its original claim" true
         (failure.target_effect=Fs_compat.Target_replaced);
       (match failure.primary_failure with
        | Fs_compat.Write_primary_failure failed ->
          check bool "original cancellation parent sync actually failed" true
            (failed.stage=Fs_compat.Sync_parent)
        | Fs_compat.Recovery_primary_failure _ | Fs_compat.Recovery_access_primary_failure _ ->
          fail "cancellation failed before the intended real parent sync");
       check bool "cancellation cleanup also failed to confirm parent durability" true
         (List.exists (function
           | Fs_compat.Write_cleanup_failure failed -> failed.stage=Fs_compat.Cleanup_sync_parent
           | Fs_compat.Recovery_cleanup_failure _ -> false) failure.cleanup_failures)
     | Error error -> fail (R.error_to_string error)
     | Ok _ -> fail "uncertain original cancellation was acknowledged");
    let reopened=open_root () |> get in
    let pending=R.load reopened ~binding:b |> get in
    let claim=claim_path root b in
    let inode=(Unix.lstat claim).st_ino and bytes=In_channel.with_open_bin claim In_channel.input_all in
    let revision=R.revision pending in
    check bool "visible uncertain cancellation retains its exact original coordinates" true
      (R.cancellation_state pending=R.Cancellation_requested && R.binding pending=b
        && R.admission_id pending=id "04" && R.specification pending=spec);
    let retired=ref false and entered_sync=ref false in
    let before_resync_parent ()=
      entered_sync:=true;raise (Unix.Unix_error (Unix.EIO,"fsync","proof parent")) in
    let attempt=match permit with
      | None -> R.For_testing.settle_cancelled_admission ~before_resync_parent ~sw pending
      | Some permit -> R.For_testing.retire_cancelled_launch ~before_resync_parent
          ~after_retirement:(fun () -> retired:=true) ~sw permit in
    (match attempt with
     | Error (R.Authority_unavailable _) -> ()
     | Error error -> fail (R.error_to_string error)
     | Ok _ -> fail "non-start proof trusted cancellation with a failed actual resync");
    check bool "proof attempted the matching claim and actual parent sync" true !entered_sync;
    check bool "failed sync never reached permit retirement" false !retired;
    let unchanged ()=
      let current=R.load reopened ~binding:b |> get in
      check int64 "proof observation never advances the original cancellation revision" revision (R.revision current);
      check int "proof observation never republishes the original claim inode" inode (Unix.lstat claim).st_ino;
      check string "proof observation preserves the exact original claim bytes" bytes
        (In_channel.with_open_bin claim In_channel.input_all) in
    unchanged ();
    let independent=admitted registry (binding (id "07")) in
    ignore (R.with_launch ~sw (commit independent) (fun _ ~storage:_ -> ()) |> completed);
    let proof=match permit with
      | None -> R.settle_cancelled_admission ~sw pending |> get
      | Some permit -> R.retire_cancelled_launch ~sw permit |> get in
    let confirmed=R.unlaunched_storage proof |> R.storage_record in
    check bool "successful proof binds the same original cancellation and known launch" true
      (R.binding confirmed=b && R.admission_id confirmed=id "04" && R.specification confirmed=spec
        && R.revision confirmed=revision && R.cancellation_state confirmed=R.Cancellation_requested
        && R.launch_state confirmed=(match permit with None -> R.Not_requested | Some _ -> R.Requested (id "06")));
    unchanged ();
    (match permit with
     | None -> check bool "settled cancelled admission never issues a new launch permit" true
         (R.commit_launch confirmed ~confirmed_admission_id:(id "04") ~launch_id:(id "08")=Error R.Launch_cancelled)
     | Some permit ->
       (match R.with_launch ~sw permit (fun _ ~storage:_ -> fail "retired original callback was reused") with
        | R.Not_performed R.Launch_cancelled -> ()
        | Not_performed _ | Performed _ -> fail "retired original lost its cancellation authority")))

let test_unlaunched_publication_finishes_entered_metadata normal_teardown =
  fixture (fun ~env:_ ~sw ~root ~registry ~open_root:_ ->
    let b=binding (id "05") in let original=admitted registry b in
    let cancelled=R.request_cancel original ~confirmed_admission_id:(id "04") |> get in
    let proof=R.settle_cancelled_admission ~sw cancelled |> get in
    let entered,signal=Eio.Promise.create () and resume,release=Eio.Promise.create () in
    let teardown,begin_teardown=Eio.Promise.create () and cancellation,notice_cancel=Eio.Promise.create () in
    let drained,finish_scope=Eio.Promise.create () in
    let interrupted=ref None in
    let path=Filename.concat (job_path root b) (R.evidence_leaf (R.Stream_data P.Stdout)) in
    let unblock ()=if Eio.Promise.peek resume=None then Eio.Promise.resolve release () in
    Fun.protect ~finally:unblock (fun () ->
      Eio.Fiber.fork ~sw (fun () ->
        let original_scope_result=match Eio.Switch.run (fun publisher_sw ->
          Eio.Fiber.fork_daemon ~sw:publisher_sw (fun () ->
            let fault=Recovery_test.before_parent_sync_dispatch ~before_sync:(fun () ->
              check bool "actual immutable file exists before its real parent fsync" true (Sys.file_exists path);
              Eio.Promise.resolve signal ();Eio.Promise.await resume) in
            match Recovery_test.with_replace_dispatch_fault fault (fun () ->
                R.publish_unlaunched ~sw:publisher_sw proof ~evidence:(R.Stream_data P.Stdout) ~content:"") with
             | Ok () -> fail "cancelled entered publication returned success"
             | Error error -> fail (R.error_to_string error)
             | exception (Eio.Cancel.Cancelled reason as ex) -> interrupted:=Some reason;raise ex);
          Eio.Fiber.fork_daemon ~sw:publisher_sw (fun () ->
            try Eio.Fiber.await_cancel () with Eio.Cancel.Cancelled reason as ex ->
              Eio.Promise.resolve notice_cancel reason;raise ex);
          Eio.Promise.await teardown;
          if not normal_teardown then Eio.Switch.fail publisher_sw Interrupted) with
          | () -> normal_teardown
          | exception Interrupted -> not normal_teardown in
        Eio.Promise.resolve finish_scope original_scope_result);
      Eio.Promise.await entered;
      let inode=(Unix.lstat path).st_ino in
      Eio.Promise.resolve begin_teardown ();
      let original_reason=Eio.Promise.await cancellation in
      check bool "owner scope cannot release while its actual metadata transaction is entered" true
        (Eio.Promise.peek drained=None);
      check bool "entered publication retains exclusive original authority through settlement" true
        (R.refresh original=Error R.Busy);
      let independent=admitted registry (binding (id "07")) in
      ignore (R.with_launch ~sw (commit independent) (fun _ ~storage:_ -> ()) |> completed);
      unblock ();
      check bool "scope teardown preserves its original completion or failure" true (Eio.Promise.await drained);
      check bool "publisher propagates the original cancellation rather than Fs recovery wrapping" true
        (match !interrupted with Some reason -> reason==original_reason | None -> false);
      check int "entered transaction leaves its original file inode" inode (Unix.lstat path).st_ino;
      check string "entered transaction preserves its actual empty original bytes" ""
        (In_channel.with_open_bin path In_channel.input_all);
      check bool "cancelled metadata never invents a complete terminal receipt" false
        (Sys.file_exists (Filename.concat (job_path root b) (R.evidence_leaf R.Terminal_receipt)));
      R.publish_unlaunched ~sw proof ~evidence:(R.Stream_data P.Stdout) ~content:"" |> get;
      check int "reconciliation retains the exact already published evidence" inode (Unix.lstat path).st_ino))

let test_unlaunched_publication_preserves_actual_fs_failure () =
  fixture (fun ~env:_ ~sw ~root ~registry ~open_root:_ ->
    let b=binding (id "05") in let original=admitted registry b in
    let cancelled=R.request_cancel original ~confirmed_admission_id:(id "04") |> get in
    let proof=R.settle_cancelled_admission ~sw cancelled |> get in
    let fault=Recovery_test.before_parent_sync_dispatch ~before_sync:(fun () ->
      raise (Unix.Unix_error (Unix.EIO,"fsync","unlaunched parent"))) in
    (match Recovery_test.with_replace_dispatch_fault fault (fun () ->
        R.publish_unlaunched ~sw proof ~evidence:(R.Stream_data P.Stdout) ~content:"") with
     | Error (R.Publication_failed failure) ->
       check bool "actual failed parent sync retains the real created-file effect" true
         (failure.target_effect=Fs_compat.Target_created);
       (match failure.primary_failure with
        | Fs_compat.Write_primary_failure failed ->
          check bool "original Fs error remains at the actual parent sync boundary" true
            (failed.stage=Fs_compat.Sync_parent)
        | Fs_compat.Recovery_primary_failure _ | Fs_compat.Recovery_access_primary_failure _ ->
          fail "publication failed outside the actual entered Fs writer")
     | Error error -> fail (R.error_to_string error)
     | Ok () -> fail "actual Fs failure became successful evidence publication");
    let path=Filename.concat (job_path root b) (R.evidence_leaf (R.Stream_data P.Stdout)) in
    check string "failed publication preserves the actual original evidence" ""
      (In_channel.with_open_bin path In_channel.input_all);
    let independent=admitted registry (binding (id "07")) in
    ignore (R.with_launch ~sw (commit independent) (fun _ ~storage:_ -> ()) |> completed))

let test_guarded_launch_pins_cancellation_before_source_adoption () =
  fixture (fun ~env:_ ~sw ~root ~registry ~open_root:_ ->
    let b=binding (id "05") in
    let original=R.with_owner_guard (admitted registry b) in
    let permit=commit original in
    let source=Atomic.make original in
    R.attach_launch_source permit source |> get;
    check bool "attach advances the captured source to the committed launch" true
      (R.launch_state (Atomic.get source)=R.Requested (id "06"));
    let other=Atomic.make original in
    check bool "a second attach is refused" true
      (R.attach_launch_source permit other=Error R.Launch_intent_spent);
    check bool "failed attach does not mutate its source" true (Atomic.get other==original);
    let claim=claim_path root b in
    let launch_bytes=In_channel.with_open_bin claim In_channel.input_all in
    let independent=R.load registry ~binding:b |> get in
    ignore (R.request_cancel independent ~confirmed_admission_id:(id "04") |> get);
    let observed=R.refresh (Atomic.get source) |> get in
    check bool "refresh saw cancellation without adopting the returned record" true
      (R.cancellation_state observed=R.Cancellation_requested
       && R.cancellation_state (Atomic.get source)=R.No_cancellation);
    let saved=claim ^ ".cancelled" in
    Unix.rename claim saved;
    Out_channel.with_open_bin claim (fun channel -> output_string channel launch_bytes);
    Unix.chmod claim 0o400;
    Fun.protect ~finally:(fun () -> Unix.rename saved claim) (fun () ->
      check bool "rollback is rejected by the pinned source" true
        (R.refresh (Atomic.get source)=Error R.Stale_record);
      let entered=ref false in
      (match R.with_launch ~sw permit (fun _ ~storage:_ -> entered:=true) with
       | R.Not_performed R.Stale_record -> ()
       | R.Not_performed error -> fail (R.error_to_string error)
       | R.Performed _ -> fail "rollback entered the original callback");
      check bool "rollback cannot enter the launch callback" false !entered;
      check bool "rollback cannot prove a no-child retirement" true
        (R.retire_cancelled_launch ~sw permit=Error R.Stale_record));
    ignore (R.retire_cancelled_launch ~sw permit |> get);
    let after_retirement=Atomic.make original in
    check bool "a retired permit cannot attach a new source" true
      (R.attach_launch_source permit after_retirement=Error R.Launch_intent_spent);
    check bool "failed retired attach leaves its source unchanged" true
      (Atomic.get after_retirement==original);
    (match R.with_launch ~sw permit (fun _ ~storage:_ -> ()) with
     | R.Not_performed R.Launch_cancelled -> ()
     | R.Not_performed error -> fail (R.error_to_string error)
     | R.Performed _ -> fail "retired cancelled permit re-entered callback"))

let test_guarded_launch_remembers_interrupted_cancel_reply () =
  fixture (fun ~env:_ ~sw ~root ~registry ~open_root:_ ->
    let b=binding (id "05") in
    let original=R.with_owner_guard (admitted registry b) in
    let permit=commit original in
    let source=Atomic.make original in
    R.attach_launch_source permit source |> get;
    let claim=claim_path root b in
    let launch_bytes=In_channel.with_open_bin claim In_channel.input_all in
    (match R.For_testing.request_cancel ~after_publication:(fun () -> raise Interrupted)
        (Atomic.get source) ~confirmed_admission_id:(id "04") with
     | exception Interrupted -> ()
     | Ok _ | Error _ -> fail "cancellation did not reach its lost-reply boundary");
    let saved=claim ^ ".cancelled" in
    Unix.rename claim saved;
    Out_channel.with_open_bin claim (fun channel -> output_string channel launch_bytes);
    Unix.chmod claim 0o400;
    Fun.protect ~finally:(fun () -> Unix.rename saved claim) (fun () ->
      (match R.with_launch ~sw permit (fun _ ~storage:_ -> ()) with
       | R.Not_performed R.Stale_record -> ()
       | R.Not_performed error -> fail (R.error_to_string error)
       | R.Performed _ -> fail "lost cancellation reply allowed rollback launch"));
    ignore (R.retire_cancelled_launch ~sw permit |> get))

let test_guarded_launch_remembers_uncertain_cancel_publication () =
  fixture (fun ~env:_ ~sw ~root ~registry ~open_root:_ ->
    let b=binding (id "05") in
    let original=R.with_owner_guard (admitted registry b) in
    let permit=commit original in
    let source=Atomic.make original in
    R.attach_launch_source permit source |> get;
    let claim=claim_path root b in
    let launch_bytes=In_channel.with_open_bin claim In_channel.input_all in
    let fault=Recovery_test.parent_sync_dispatch_fault
      ~exception_:(Unix.Unix_error (Unix.EIO,"fsync","cancel parent")) in
    (match Recovery_test.with_replace_dispatch_fault fault (fun () ->
        R.request_cancel (Atomic.get source) ~confirmed_admission_id:(id "04")) with
     | Error (R.Publication_failed failure) ->
       check bool "the cancel claim was replaced before durability failed" true
         (failure.target_effect=Fs_compat.Target_replaced)
     | Error error -> fail (R.error_to_string error)
     | Ok _ -> fail "uncertain cancellation was acknowledged");
    let saved=claim ^ ".cancelled" in
    Unix.rename claim saved;
    Out_channel.with_open_bin claim (fun channel -> output_string channel launch_bytes);
    Unix.chmod claim 0o400;
    Fun.protect ~finally:(fun () -> Unix.rename saved claim) (fun () ->
      (match R.with_launch ~sw permit (fun _ ~storage:_ -> ()) with
       | R.Not_performed R.Stale_record -> ()
       | R.Not_performed error -> fail (R.error_to_string error)
       | R.Performed _ -> fail "uncertain replaced cancellation allowed rollback launch");
      check bool "observed replacement cannot be silently republished after rollback" true
        (R.request_cancel (Atomic.get source) ~confirmed_admission_id:(id "04")=Error R.Stale_record));
    let confirmed=R.request_cancel (Atomic.get source) ~confirmed_admission_id:(id "04") |> get in
    check bool "explicit reconciliation confirms the original cancellation" true
      (R.cancellation_state confirmed=R.Cancellation_requested);
    ignore (R.retire_cancelled_launch ~sw permit |> get))

let test_unchanged_cancel_does_not_invent_uncertainty () =
  fixture (fun ~env:_ ~sw ~root:_ ~registry ~open_root:_ ->
    let b=binding (id "05") in
    let original=R.with_owner_guard (admitted registry b) in
    let permit=commit original in
    let source=Atomic.make original in
    R.attach_launch_source permit source |> get;
    let fault=Recovery_test.replace_dispatch_fault ~stage:Recovery_test.Before_publish_replace
      ~exception_:(Unix.Unix_error (Unix.EIO,"rename","cancel claim")) in
    (match Recovery_test.with_replace_dispatch_fault fault (fun () ->
        R.request_cancel (Atomic.get source) ~confirmed_admission_id:(id "04")) with
     | Error (R.Publication_failed failure) ->
       check bool "failed pre-publication leaves the target unchanged" true
         (failure.target_effect=Fs_compat.Target_unchanged)
     | Error error -> fail (R.error_to_string error)
     | Ok _ -> fail "failed cancellation publication was acknowledged");
    let entered=ref 0 in
    ignore (R.with_launch ~sw permit (fun _ ~storage:_ -> incr entered) |> completed);
    check int "unchanged failed cancellation leaves the original launch executable" 1 !entered)

let test_unknown_cancel_effect_holds_original_launch () =
  fixture (fun ~env:_ ~sw ~root:_ ~registry ~open_root:_ ->
    let b=binding (id "05") in
    let original=R.with_owner_guard (admitted registry b) in
    let permit=commit original in
    let source=Atomic.make original in
    R.attach_launch_source permit source |> get;
    let fault=Recovery_test.remove_staging_payload_before_publish () in
    (match Recovery_test.with_replace_dispatch_fault fault (fun () ->
        R.request_cancel (Atomic.get source) ~confirmed_admission_id:(id "04")) with
     | Error (R.Publication_failed failure) ->
       check bool "failed rename reports an unknown target effect" true
         (failure.target_effect=Fs_compat.Target_state_unknown)
     | Error error -> fail (R.error_to_string error)
     | Ok _ -> fail "unknown cancellation publication was acknowledged");
    let entered=ref false in
    check bool "uncertain cancellation is visible to original observation" true
      (R.refresh (Atomic.get source)=Error R.Cancel_reconciliation_required);
    (match R.with_launch ~sw permit (fun _ ~storage:_ -> entered:=true) with
     | R.Not_performed R.Cancel_reconciliation_required -> ()
     | R.Not_performed error -> fail (R.error_to_string error)
     | R.Performed _ -> fail "unknown cancellation effect entered the callback");
    check bool "unknown cancellation never enters the callback" false !entered)

let test_guarded_intent_pins_direct_cancel_observation during_retirement () =
  fixture (fun ~env:_ ~sw ~root ~registry ~open_root:_ ->
    let b=binding (id "05") in
    let original=R.with_owner_guard (admitted registry b) in
    let permit=commit original in
    let source=Atomic.make original in
    R.attach_launch_source permit source |> get;
    let claim=claim_path root b in
    let launch_bytes=In_channel.with_open_bin claim In_channel.input_all in
    let independent=R.load registry ~binding:b |> get in
    ignore (R.request_cancel independent ~confirmed_admission_id:(id "04") |> get);
    if during_retirement then (
      let reached=ref false in
      match R.For_testing.retire_cancelled_launch
          ~before_resync_parent:(fun () -> reached:=true;raise (Unix.Unix_error (Unix.EIO,"fsync","proof parent")))
          ~after_retirement:(fun () -> ()) ~sw permit with
      | Error (R.Authority_unavailable _) when !reached -> ()
      | Ok _ | Error _ -> fail "retirement did not reach the failed resync boundary")
    else (
      match R.with_launch ~sw permit (fun _ ~storage:_ -> ()) with
      | R.Not_performed R.Launch_cancelled -> ()
      | R.Not_performed error -> fail (R.error_to_string error)
      | R.Performed _ -> fail "cancelled original entered callback");
    let saved=claim ^ ".cancelled" in
    Unix.rename claim saved;
    Out_channel.with_open_bin claim (fun channel -> output_string channel launch_bytes);
    Unix.chmod claim 0o400;
    Fun.protect ~finally:(fun () -> Unix.rename saved claim) (fun () ->
      match R.with_launch ~sw permit (fun _ ~storage:_ -> ()) with
      | R.Not_performed R.Stale_record -> ()
      | R.Not_performed error -> fail (R.error_to_string error)
      | R.Performed _ -> fail "previously observed cancellation was lost");
    ignore (R.retire_cancelled_launch ~sw permit |> get))

let ()=run "endpoint job registry" ["original durable admission",[
  test_case "owner guard pins cancellation before source adoption" `Quick
    test_guarded_launch_pins_cancellation_before_source_adoption;
  test_case "owner guard retains an interrupted cancellation reply" `Quick
    test_guarded_launch_remembers_interrupted_cancel_reply;
  test_case "owner guard retains an uncertain replaced cancellation" `Quick
    test_guarded_launch_remembers_uncertain_cancel_publication;
  test_case "unchanged failed cancellation does not invent a hold" `Quick
    test_unchanged_cancel_does_not_invent_uncertainty;
  test_case "unknown cancellation effect holds the original launch" `Quick
    test_unknown_cancel_effect_holds_original_launch;
  test_case "launch observation pins cancellation" `Quick
    (test_guarded_intent_pins_direct_cancel_observation false);
  test_case "failed retirement pins cancellation" `Quick
    (test_guarded_intent_pins_direct_cancel_observation true);
  test_case "original admission is idempotent and survives reopen" `Quick test_original_admission_survives_reopen;
  test_case "base Inspect outer v1 is rejected before original decoding" `Quick
    (test_legacy_claim_version_is_rejected_before_decode "base Inspect with bare binding" `Inspect);
  test_case "f8df Reconcile_admission outer v1 is rejected before original decoding" `Quick
    (test_legacy_claim_version_is_rejected_before_decode "f8df Reconcile_admission with outer v1" `Reconcile_admission);
  test_case "preparing interruptions resume original admission and directory" `Quick test_preparing_boundaries_resume_original;
  test_case "competing directory publication preserves the original admission" `Quick test_competing_directory_publication_preserves_original;
  test_case "launch confirmation is original and its permit is single use" `Quick test_launch_confirmation_and_one_use;
  test_case "lost launch reply and callback exception never replay permission" `Quick test_lost_launch_reply_and_callback_exception;
  test_case "busy startup leaves an independent owner executable" `Quick test_busy_owner_does_not_block_other_owner;
  test_case "missing and corrupt originals never become replacement work" `Quick test_missing_or_corrupt_original_does_not_reconstruct;
  test_case "changed boot or payload configuration never retargets the original" `Quick test_owner_boot_and_execution_identity_cannot_retarget;
  test_case "private authority, symlinks and hardlinks remain explicit refusals" `Quick test_private_authority_and_filesystem_aliases;
  test_case "cancel before launch preserves original and cannot resurrect" `Quick test_cancel_before_launch_preserves_original_and_blocks_admission;
  test_case "cancel wins over an unconsumed launch permit" `Quick test_cancel_wins_over_an_unconsumed_launch_permit;
  test_case "lost cancellation reply is reconciled without republication" `Quick test_lost_cancel_reply_is_reconciled_without_republication;
  test_case "uncertain cancellation needs a successful original claim resync" `Quick test_uncertain_cancel_requires_successful_original_resync;
  test_case "cancel during startup leaves independent jobs progressing" `Quick test_cancel_race_with_active_startup_leaves_other_jobs_progressing;
  test_case "cancel preserves original boot and payload identity authority" `Quick test_cancel_keeps_boot_and_payload_identity_authority;
  test_case "cancel rejects rebound job and known launch coordinates" `Quick test_cancel_rejects_rebound_job_and_known_launch_coordinates;
  test_case "launch storage pins original publication and per-job lifetime" `Quick test_launch_storage_is_original_and_job_owned;
  test_case "storage replacement before effect spends permission without launch" `Quick test_launch_rejects_storage_swap_before_effect;
  test_case "cancelled supervisor scope cannot enter launch" `Quick test_cancelled_job_scope_never_enters_launch;
  test_case "old boot can read original storage without restoring a launch" `Quick test_original_storage_read_survives_boot_without_launch;
  test_case "storage pins its actual registry and rejects a rebound job" `Quick test_open_storage_pins_actual_registry_and_rejects_rebound_job;
  test_case "storage contention preserves progress and known launch authority" `Quick test_storage_contention_and_known_launch_revalidation;
  test_case "original readers overlap while exclusive writers remain nonwaiting" `Quick test_original_readers_overlap_without_admitting_writers;
  test_case "cancelled admission proves no known launch without inventing an exit" `Quick test_cancelled_admission_proves_no_known_launch;
  test_case "only the same unused cancelled permit can be retired" `Quick test_retire_only_unused_cancelled_original_permit;
  test_case "a used permit never becomes non-start after cancellation" `Quick test_used_permit_never_becomes_nonstart_after_cancellation;
  test_case "cancelled retirement keeps its original permit retired" `Quick test_cancelled_retirement_keeps_permit_retired;
  test_case "uncertain cancelled admission requires actual resync before proof" `Quick
    (fun () -> test_uncertain_cancel_requires_resync_before_nonstart_proof false);
  test_case "uncertain cancelled launch requires actual resync before retirement" `Quick
    (fun () -> test_uncertain_cancel_requires_resync_before_nonstart_proof true);
  test_case "normal publisher teardown finishes actual entered metadata" `Quick
    (fun () -> test_unlaunched_publication_finishes_entered_metadata true);
  test_case "cancelled publisher finishes actual entered metadata and preserves its cause" `Quick
    (fun () -> test_unlaunched_publication_finishes_entered_metadata false);
  test_case "unlaunched publication retains actual Fs failure evidence" `Quick
    test_unlaunched_publication_preserves_actual_fs_failure]]
