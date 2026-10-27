open Alcotest
module P = Endpoint_job_protocol
module R = Endpoint_job_registry
let require = function Ok value -> value | Error e -> fail e
let get = function Ok value -> value | Error e -> fail (R.error_to_string e)
let id suffix = P.Id.of_string ("019a0000-0000-7000-8000-0000000000" ^ suffix) |> require
let digest value = P.Sha256.of_string Digestif.SHA256.(digest_string value |> to_hex) |> require
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

let test_original_admission_survives_reopen () = fixture (fun ~env:_ ~sw:_ ~root:_ ~registry ~open_root ->
  let b=binding (id "05") in let first=admitted registry b in
  check int64 "admission is durably ready before return" 1L (R.revision first);
  check bool "complete binary launch data is retained" true (R.specification first=spec);
  check bool "admission itself grants no launch" true (R.launch_state first=R.Not_requested);
  let repeated=R.admit registry ~new_admission_id:(id "99") ~binding:b ~spec |> get in
  check bool "duplicate caller does not replace the original admission identity" true (R.admission_id first=R.admission_id repeated);
  let reopened=open_root () |> get in let recovered=R.load reopened ~binding:b |> get in
  check bool "restart read preserves original owner, invocation and launch bytes" true
    (R.binding recovered=b && R.specification recovered=spec && R.admission_id recovered=id "04");
  check int "payload identity remains original" (chosen_payload_uid ()) (R.payload_uid recovered))

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

let test_launch_confirmation_and_one_use () = fixture (fun ~env:_ ~sw:_ ~root:_ ~registry ~open_root ->
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
  let value=R.with_launch permit (fun target -> incr count;
    check bool "callback receives exact original endpoint admission" true
      (target.R.binding=b && target.spec=spec && target.admission_id=id "04" && target.launch_id=id "06");
    check int "the stored execution identity reaches the supervisor boundary" (chosen_payload_uid ()) target.payload_uid;
    "original launch result") |> completed in
  check string "callback result remains authoritative" "original launch result" value;
  (match R.with_launch permit (fun _ -> incr count) with
   | R.Not_performed R.Launch_intent_spent -> ()
   | R.Not_performed _ | R.Performed _ -> fail "spent permit executed again");
  check int "exactly one actual callback entry" 1 !count)

let test_lost_launch_reply_and_callback_exception () =
  fixture (fun ~env:_ ~sw:_ ~root:_ ~registry ~open_root ->
    let b=binding (id "05") in let record=admitted registry b in
    (match R.For_testing.commit_launch ~after_publication:(fun () -> raise Interrupted)
        record ~confirmed_admission_id:(id "04") ~launch_id:(id "06") with
     | exception Interrupted -> ()
     | Ok _ | Error _ -> fail "lost-reply boundary was not reached");
    let recovered=R.load (open_root () |> get) ~binding:b |> get in
    check bool "lost reply retains original durable launch intent" true (R.launch_state recovered=R.Requested (id "06"));
    check bool "lost reply is reconciliation, never a new launch permit" true
      (R.commit_launch recovered ~confirmed_admission_id:(id "04") ~launch_id:(id "07")=Error R.Launch_already_requested));
  fixture (fun ~env:_ ~sw:_ ~root:_ ~registry ~open_root:_ ->
    let permit=admitted registry (binding (id "05")) |> commit in let count=ref 0 in
    (match R.with_launch permit (fun _ -> incr count;raise Interrupted) with
     | exception Interrupted -> ()
     | R.Not_performed _ | R.Performed _ -> fail "launch exception did not propagate");
    (match R.with_launch permit (fun _ -> incr count) with
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
        (R.with_launch permit (fun _ -> Eio.Promise.resolve signal ();Eio.Promise.await release_startup;"first")));
      Eio.Promise.await entered;
      check bool "same operation is observed busy without waiting" true (R.load registry ~binding:b=Error R.Busy);
      let other=admitted registry (binding (id "07")) |> commit in
      check string "an independent operation progresses before the first startup releases" "independent"
        (R.with_launch other (fun _ -> "independent") |> completed);
      check bool "first callback is genuinely still active" true (Eio.Promise.peek finished=None);
      release ();
      check string "original callback settles after its own release" "first" (Eio.Promise.await finished |> completed))))

let test_missing_or_corrupt_original_does_not_reconstruct () =
  List.iter (fun fault -> fixture (fun ~env:_ ~sw:_ ~root ~registry ~open_root:_ ->
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
      (R.with_launch healthy (fun _ -> "healthy") |> completed)))
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

let ()=run "endpoint job registry" ["original durable admission",[
  test_case "original admission is idempotent and survives reopen" `Quick test_original_admission_survives_reopen;
  test_case "preparing interruptions resume original admission and directory" `Quick test_preparing_boundaries_resume_original;
  test_case "competing directory publication preserves the original admission" `Quick test_competing_directory_publication_preserves_original;
  test_case "launch confirmation is original and its permit is single use" `Quick test_launch_confirmation_and_one_use;
  test_case "lost launch reply and callback exception never replay permission" `Quick test_lost_launch_reply_and_callback_exception;
  test_case "busy startup leaves an independent owner executable" `Quick test_busy_owner_does_not_block_other_owner;
  test_case "missing and corrupt originals never become replacement work" `Quick test_missing_or_corrupt_original_does_not_reconstruct;
  test_case "changed boot or payload configuration never retargets the original" `Quick test_owner_boot_and_execution_identity_cannot_retarget;
  test_case "private authority, symlinks and hardlinks remain explicit refusals" `Quick test_private_authority_and_filesystem_aliases]]
