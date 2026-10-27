module Lease = Native_addon_lease
module Socket = Masc.Browser_addon_socket
let ok = function Ok value -> value | Error detail -> Alcotest.fail detail
let lease result = result |> Result.map_error Lease.error_to_string |> ok
let check = Alcotest.check Alcotest.bool
let rec remove path = match (Unix.lstat path).Unix.st_kind with
  | Unix.S_DIR -> Array.iter (fun name -> remove (Filename.concat path name)) (Sys.readdir path);Unix.rmdir path
  | Unix.S_REG|Unix.S_LNK|Unix.S_CHR|Unix.S_BLK|Unix.S_FIFO|Unix.S_SOCK -> Unix.unlink path
let owned_gecko={Masc.Browser_addon_automation.driver="/usr/bin/geckodriver";binary=None;profiles="/fixture/gecko-profiles"}
(* Without a [source], the allocation is an external host worker's: it starts
   no browser and may hold only its socket. *)
let with_claim ?(source=fun _ -> Socket.External_host) ?(models=fun _ -> None)
    ?(context=Fun.id) work =
  let directory=Filename.temp_file "browser-addon-slot-" "" in
  Unix.unlink directory;Unix.mkdir directory 0o700;
  let instance_id=Uuidm.(to_string (v4_gen (Random.State.make_self_init ()) ())) in
  let context=ok (Socket.context ~instance_id ~source:(source directory) ~models:(models directory)) |> context in
  let root=match context with `Assoc fields -> (match List.assoc_opt "directory" fields with
    | Some (`String root) -> root | _ -> Alcotest.fail "missing allocation directory")
    | _ -> Alcotest.fail "invalid allocation intent" in
  check "new allocation is absent" false (Sys.file_exists root);
  Fun.protect ~finally:(fun () ->
    if Sys.file_exists root then remove root;
    remove directory) (fun () ->
    let admission=lease (Lease.prepare ~directories:[directory] ~instance_id ~cleanup_context:(Some context)) in
    work admission directory root)
let released result = check "the allocation is released" true (ok result = Socket.Allocation_released)
let retained result = check "the operator retains the allocation" true (ok result = Socket.Allocation_retained)
let retain_ok = function
  | Ok settlement -> settlement
  | Error (Socket.Retain_refused detail | Socket.Retained_record_unconfirmed detail) -> Alcotest.fail detail
let refused label result = check label true (match result with
  | Error (Socket.Retain_refused _) -> true
  | Ok _ | Error (Socket.Retained_record_unconfirmed _) -> false)
let socket path =
  let descriptor=Unix.socket ~cloexec:true Unix.PF_UNIX Unix.SOCK_STREAM 0 in
  Fun.protect ~finally:(fun () -> Unix.close descriptor) (fun () -> Unix.bind descriptor (Unix.ADDR_UNIX path))
let cleanup_after_reopen () = with_claim (fun admission directory root ->
  let owned=ok (Socket.acquire ~admission ~directory) in
  socket (Socket.socket_path owned);
  check "cannot release a launchable reservation" true (Result.is_error (Socket.cleanup ~admission ~directory));
  lease (Lease.retire admission);
  let recovered=lease (Lease.reopen ~directories:[directory] ~instance_id:(Lease.instance_id admission)) in
  released (Socket.cleanup ~admission:recovered ~directory);
  check "original socket directory removed" false (Sys.file_exists root);
  released (Socket.cleanup ~admission:recovered ~directory);
  Unix.mkdir root 0o700;
  check "released path resurrection is refused" true (Result.is_error (Socket.cleanup ~admission:recovered ~directory));
  check "new directory was preserved" true (Sys.file_exists root))
let interrupted_acquisition () = with_claim (fun admission directory root ->
  Unix.mkdir root 0o700;
  lease (Lease.retire admission);
  released (Socket.cleanup ~admission ~directory);
  check "intent recovers pre-record allocation" false (Sys.file_exists root))
let unknown_resources () = with_claim (fun admission directory root ->
  Unix.mkdir root 0o700;socket (Filename.concat root "s");
  lease (Lease.retire admission);
  check "socket without acquired identity is retained" true (Result.is_error (Socket.cleanup ~admission ~directory));
  check "uncertain socket remains" true (Sys.file_exists (Filename.concat root "s")))
let replaced_directory () = with_claim (fun admission directory root ->
  ignore (ok (Socket.acquire ~admission ~directory));
  let original=Filename.concat directory "original" in
  Unix.rename root original;Unix.mkdir root 0o700;
  lease (Lease.retire admission);
  check "different directory identity is retained" true (Result.is_error (Socket.cleanup ~admission ~directory));
  check "replacement preserved" true (Sys.file_exists root))
let model_configuration_cleanup () =
  let models directory=Some {Masc.Browser_addon_models.store_root=Filename.concat directory "model-results";
    outputs=[{Masc.Lane_addon_types.name="locate";request_schema=Masc.Lane_addon_types.Package_schema_only;schema=`Assoc ["type",`String "string"]}]} in
  with_claim ~models (fun admission directory root ->
    let owned=ok (Socket.acquire ~admission ~directory) in
    check "worker receives the host model configuration flag" true
      (List.mem "--models" (Socket.arguments owned ~max_message_bytes:65536));
    let path=Filename.concat root "models.json" in
    let original=In_channel.with_open_bin path In_channel.input_all in
    let retained=Filename.concat directory "model-result-receipt" in
    Out_channel.with_open_bin retained (fun out -> output_string out "retained independently");
    Out_channel.with_open_bin path (fun out -> output_string out "{}");
    lease (Lease.retire admission);
    check "changed model scope prevents allocation release" true (Result.is_error (Socket.cleanup ~admission ~directory));
    Out_channel.with_open_bin path (fun out -> output_string out original);
    released (Socket.cleanup ~admission ~directory);
    check "model bootstrap is released with original allocation" false (Sys.file_exists root);
    check "separate model receipts survive resource cleanup" true (Sys.file_exists retained))
let owned_backend_cleanup () =
  with_claim ~source:(fun _ -> Socket.Automation owned_gecko)
    (fun admission directory root ->
      ignore (ok (Socket.acquire ~admission ~directory));
      let downloads=Filename.concat root "downloads" in
      Unix.mkdir downloads 0o700;
      Unix.mkdir (Filename.concat downloads "session") 0o700;
      let file=Filename.concat (Filename.concat downloads "session") "partial" in
      Out_channel.with_open_bin file (fun out -> output_string out "preserve");
      lease (Lease.retire admission);
      check "download content is retained" true (Result.is_error (Socket.cleanup ~admission ~directory));
      check "unconfirmed download content remains" true (Sys.file_exists file);
      Unix.unlink file;
      released (Socket.cleanup ~admission ~directory);
      check "a settled worker and empty trees release the allocation" false (Sys.file_exists root))
let interrupted_owned_cleanup () =
  with_claim ~source:(fun _ -> Socket.Automation owned_gecko)
    (fun admission directory root ->
      ignore (ok (Socket.acquire ~admission ~directory));
      (* A known leaf cannot be removed: fail during deletion, then resume
         after some earlier leaves already disappeared. *)
      let obstruction=Filename.concat root "webdriver.log" in
      Unix.mkdir obstruction 0o700;
      lease (Lease.retire admission);
      check "interrupted deletion is reported" true (Result.is_error (Socket.cleanup ~admission ~directory));
      List.iter (fun name -> let path=Filename.concat root name in
        if Sys.file_exists path then Unix.unlink path) ["automation.json"];
      Unix.rmdir obstruction;
      released (Socket.cleanup ~admission ~directory);
      check "cleanup resumes after a partial deletion" false (Sys.file_exists root))
(* An allocation holds the resources of its one source. A file another
   source's browser writes is unknown here, so cleanup keeps the allocation
   until that file is gone. *)
let foreign_source_resources () =
  List.iter (fun (source,foreign) ->
    with_claim ~source:(fun _ -> source) (fun admission directory root ->
      ignore (ok (Socket.acquire ~admission ~directory));
      let path=Filename.concat root foreign in
      Out_channel.with_open_bin path (fun out -> output_string out "preserve");
      lease (Lease.retire admission);
      check "another source's resource retains the allocation" true (Result.is_error (Socket.cleanup ~admission ~directory));
      check "the other source's resource remains" true (Sys.file_exists path);
      Unix.unlink path;
      released (Socket.cleanup ~admission ~directory);
      check "the allocation of its own source's resources is released" false (Sys.file_exists root)))
    [Socket.Automation owned_gecko,"stagehand.json";
     Socket.Ego,"automation.json";
     Socket.External_host,"live-bidi.json"]
let acquisition_state directory =
  match List.filter (fun name -> String.starts_with ~prefix:"browser-" name) (Array.to_list (Sys.readdir directory)) with
  | [name] -> (match Yojson.Safe.from_file (Filename.concat directory name) with
      | `Assoc fields -> (match List.assoc_opt "state" fields with
          | Some (`String state) -> state | _ -> Alcotest.fail "acquisition record has no state")
      | _ -> Alcotest.fail "acquisition record is not an object")
  | names -> Alcotest.failf "expected one acquisition record, found %d" (List.length names)
let operator_retains_unconfirmed_allocation () =
  with_claim ~source:(fun _ -> Socket.Automation owned_gecko)
    (fun admission directory root ->
      ignore (ok (Socket.acquire ~admission ~directory));
      let downloads=Filename.concat root "downloads" in
      Unix.mkdir downloads 0o700;
      let file=Filename.concat downloads "unsettled-download" in
      Out_channel.with_open_bin file (fun out -> output_string out "preserve");
      refused "a launchable reservation cannot be retained" (Socket.retain ~admission ~directory);
      check "a refused retain keeps the acquisition" true (acquisition_state directory = "acquired");
      lease (Lease.retire admission);
      check "unsettled download content retains the allocation" true (Result.is_error (Socket.cleanup ~admission ~directory));
      check "the operator retains the allocation" true (retain_ok (Socket.retain ~admission ~directory) = Socket.Allocation_retained);
      check "the acquisition record names the operator's retention" true (acquisition_state directory = "retained");
      check "retained download content remains" true (Sys.file_exists file);
      (* A later recovery pass reports the retention, never a release. *)
      retained (Socket.cleanup ~admission ~directory);
      check "cleanup leaves a retained allocation in place" true (Sys.file_exists file);
      check "cleanup does not release a retained allocation" true (acquisition_state directory = "retained");
      check "the operator retains the allocation" true (retain_ok (Socket.retain ~admission ~directory) = Socket.Allocation_retained);
      check "a repeated retain changes nothing" true (Sys.file_exists file && acquisition_state directory = "retained"))
let retain_refuses_replaced_directory () =
  with_claim ~source:(fun _ -> Socket.Automation owned_gecko)
    (fun admission directory root ->
      ignore (ok (Socket.acquire ~admission ~directory));
      let original=Filename.concat directory "original" in
      Unix.rename root original;Unix.mkdir root 0o700;
      lease (Lease.retire admission);
      refused "a different directory identity is not retained" (Socket.retain ~admission ~directory);
      check "the refused retain keeps the acquisition" true (acquisition_state directory = "acquired"))
let retain_reports_a_released_allocation () =
  with_claim ~source:(fun _ -> Socket.Automation owned_gecko)
    (fun admission directory _root ->
      ignore (ok (Socket.acquire ~admission ~directory));
      lease (Lease.retire admission);
      released (Socket.cleanup ~admission ~directory);
      check "a released allocation is reported released" true (retain_ok (Socket.retain ~admission ~directory) = Socket.Allocation_released);
      check "a released allocation stays released" true (acquisition_state directory = "released"))
(* The Chrome child claim shares the host-recorded descriptor the Chrome
   controller writes; a different shape would make the claim foreign, and the
   last step below would then fail. *)
let retain_requires_a_settled_child_without_signalling () =
  let stagehand directory = ok (Masc.Browser_addon_stagehand.configuration
    ~browser:{Browser_configuration.chrome="/fixture/chrome";extension="/fixture/extension";profile=None}
    ~launcher:"/fixture/launcher" ~guardian:"/fixture/guardian"
    ~claim_directory:(Filename.concat directory "chrome-slot")) in
  with_claim ~source:(fun directory -> Socket.Stagehand (stagehand directory)) (fun admission directory root ->
    ignore (ok (Socket.acquire ~admission ~directory));
    let c = stagehand directory in
    let profile = match Masc.Browser_addon_stagehand.configuration_to_json c with
      | `Assoc fields -> List.assoc "profile" fields | _ -> Alcotest.fail "expected a Chrome configuration object" in
    Unix.mkdir (Filename.concat directory "chrome-slot") 0o700;
    let child = lease (Lease.prepare ~directories:[Filename.concat directory "chrome-slot"]
      ~instance_id:(Uuidm.(to_string (v4_gen (Random.State.make_self_init ()) ())))
      ~cleanup_context:(Some (`Assoc ["kind",`String "browser_addon_chrome";
        "incarnation",`String (Lease.instance_id admission);"directory",`String root;"profile",profile]))) in
    lease (Lease.retire admission);
    refused "an unsettled Chrome child refuses the retain" (Socket.retain ~admission ~directory);
    check "the refused retain did not retire the child" true (lease (Lease.status child) = Lease.Awaiting_exec);
    check "the refused retain kept the acquisition" true (acquisition_state directory = "acquired");
    lease (Lease.retire child);
    check "the operator retains the allocation" true (retain_ok (Socket.retain ~admission ~directory) = Socket.Allocation_retained))
(* Only a failure before the rename says the record did not change. *)
let retain_reports_where_a_record_write_failed () =
  let failing stage _path _contents = Error {Fs_compat.path="record";stage;
    exception_=Failure "disk full";backtrace=Printexc.get_callstack 0} in
  let attempt save = with_claim ~source:(fun _ -> Socket.Automation owned_gecko)
    (fun admission directory _root ->
      ignore (ok (Socket.acquire ~admission ~directory));
      lease (Lease.retire admission);
      let outcome = Socket.For_testing.retain ~save ~admission ~directory in
      (outcome, acquisition_state directory)) in
  let unconfirmed = function
    | Error (Socket.Retained_record_unconfirmed _) -> true
    | Ok _ | Error (Socket.Retain_refused _) -> false in
  let outcome, _ = attempt (failing Fs_compat.After_rename) in
  check "a write that failed after its rename is unconfirmed, not refused" true (unconfirmed outcome);
  let outcome, _ = attempt (fun _ _ -> raise (Unix.Unix_error (Unix.EIO, "fsync", "record"))) in
  check "a write that raised is unconfirmed, not refused" true (unconfirmed outcome);
  let outcome, state = attempt (failing Fs_compat.Before_rename) in
  refused "a write that failed before its rename is refused" outcome;
  check "the record is unchanged after a write that failed before its rename" true (state = "acquired")
(* A Chrome child claim recorded for another allocation is never read as this
   allocation's settlement. *)
let retain_refuses_a_foreign_child () =
  let stagehand directory = ok (Masc.Browser_addon_stagehand.configuration
    ~browser:{Browser_configuration.chrome="/fixture/chrome";extension="/fixture/extension";profile=None}
    ~launcher:"/fixture/launcher" ~guardian:"/fixture/guardian"
    ~claim_directory:(Filename.concat directory "chrome-slot")) in
  with_claim ~source:(fun directory -> Socket.Stagehand (stagehand directory)) (fun admission directory root ->
    ignore (ok (Socket.acquire ~admission ~directory));
    let c = stagehand directory in
    let profile = match Masc.Browser_addon_stagehand.configuration_to_json c with
      | `Assoc fields -> List.assoc "profile" fields | _ -> Alcotest.fail "expected a Chrome configuration object" in
    let slot = Filename.concat directory "chrome-slot" in
    Unix.mkdir slot 0o700;
    let child = lease (Lease.prepare ~directories:[slot]
      ~instance_id:(Uuidm.(to_string (v4_gen (Random.State.make_self_init ()) ())))
      ~cleanup_context:(Some (`Assoc ["kind",`String "browser_addon_chrome";
        "incarnation",`String "another-allocation";"directory",`String root;"profile",profile]))) in
    lease (Lease.retire child);
    lease (Lease.retire admission);
    refused "a child claim of another allocation refuses the retain" (Socket.retain ~admission ~directory);
    check "the refused retain kept the acquisition" true (acquisition_state directory = "acquired"))
(* A child reservation that was never published is fenced only by the cleanup
   pass. Retain refuses it without fencing; once a cleanup pass settled the
   child, the retain succeeds. *)
let retain_waits_for_an_unpublished_child_to_be_fenced () =
  let stagehand directory = ok (Masc.Browser_addon_stagehand.configuration
    ~browser:{Browser_configuration.chrome="/fixture/chrome";extension="/fixture/extension";profile=None}
    ~launcher:"/fixture/launcher" ~guardian:"/fixture/guardian"
    ~claim_directory:(Filename.concat directory "chrome-slot")) in
  with_claim ~source:(fun directory -> Socket.Stagehand (stagehand directory)) (fun admission directory root ->
    ignore (ok (Socket.acquire ~admission ~directory));
    let c = stagehand directory in
    let profile = match Masc.Browser_addon_stagehand.configuration_to_json c with
      | `Assoc fields -> List.assoc "profile" fields | _ -> Alcotest.fail "expected a Chrome configuration object" in
    let slot = Filename.concat directory "chrome-slot" in
    Unix.mkdir slot 0o700;
    ignore (lease (Lease.prepare ~directories:[slot]
      ~instance_id:(Uuidm.(to_string (v4_gen (Random.State.make_self_init ()) ())))
      ~cleanup_context:(Some (`Assoc ["kind",`String "browser_addon_chrome";
        "incarnation",`String (Lease.instance_id admission);"directory",`String root;"profile",profile]))));
    (* The reservation exists but its intent was never published. *)
    Out_channel.with_open_bin (Filename.concat slot "intent.json") (fun _ -> ());
    lease (Lease.retire admission);
    refused "an unpublished child reservation refuses the retain" (Socket.retain ~admission ~directory);
    check "the refused retain kept the acquisition" true (acquisition_state directory = "acquired");
    ok (Masc.Browser_addon_stagehand.settle c ~incarnation:(Lease.instance_id admission) ~directory:root);
    check "the operator retains the allocation once the child is fenced" true
      (retain_ok (Socket.retain ~admission ~directory) = Socket.Allocation_retained))
(* A reservation keeps its producer's backend payloads. Settlement must not
   require interpreting them after an explicit operator handoff. The owned
   Gecko configuration below has no profiles folder, so only a reader that
   interprets it refuses it. *)
let opaque_backends = function
  | `Assoc fields -> `Assoc (List.map (fun (key,value) -> match key with
      | "source" -> key,`Assoc ["backend",`String "automation";
          "configuration",`Assoc ["driver",`String "/fixture/driver";"binary",`Null]]
      | "models" -> key,`String "operator-owned payload"
      | _ -> key,value) fields)
  | value -> value
let allocation_record admission directory = Filename.concat directory
  ("browser-" ^ Digestif.SHA256.(to_hex (digest_string (Lease.instance_id admission))) ^ ".json")
let produce_allocation admission directory root =
  Unix.mkdir root 0o700;
  let info=Unix.lstat root in
  let value=`Assoc ["state",`String "acquired";"incarnation",`String (Lease.instance_id admission);
    "directory",`String root;"device",`Int info.st_dev;"inode",`Int info.st_ino] in
  ok (Fs_compat.save_file_atomic_strict (allocation_record admission directory) (Yojson.Safe.to_string value))
let opaque_payload_handoff () = with_claim ~context:opaque_backends (fun admission directory root ->
  produce_allocation admission directory root;
  let record=allocation_record admission directory in
  let acquired=In_channel.with_open_bin record In_channel.input_all in
  let sentinel=Filename.concat root "operator-evidence" in
  Out_channel.with_open_bin sentinel (fun out -> output_string out "preserve");
  lease (Lease.retire admission);
  check "unretained resources still need their full backend contract" true
    (Result.is_error (Socket.cleanup ~admission ~directory));
  Alcotest.check Alcotest.string "failed cleanup leaves acquisition unchanged" acquired
    (In_channel.with_open_bin record In_channel.input_all);
  check "official handoff does not interpret automation or model contents" true
    (retain_ok (Socket.retain ~admission ~directory)=Socket.Allocation_retained);
  check "an allocation cannot be projected as an empty reservation" true
    (Result.is_error (Socket.check_retained ~instance_id:(Lease.instance_id admission) ~slot:directory None));
  let marker=In_channel.with_open_bin record In_channel.input_all in
  let moved=Filename.concat directory "operator-allocation" in
  Unix.rename root moved; Unix.symlink moved root;
  let reopened=lease (Lease.reopen ~directories:[directory] ~instance_id:(Lease.instance_id admission)) in
  retained (Socket.cleanup ~admission:reopened ~directory);
  ok (Socket.check_retained ~instance_id:(Lease.instance_id admission) ~slot:directory
    (lease (Lease.cleanup_context reopened)));
  check "repeated handoff does not reopen operator resources" true
    (retain_ok (Socket.retain ~admission:reopened ~directory)=Socket.Allocation_retained);
  Alcotest.check Alcotest.string "operator marker remains byte-identical" marker
    (In_channel.with_open_bin record In_channel.input_all);
  Alcotest.check Alcotest.string "operator evidence survives path replacement" "preserve"
    (In_channel.with_open_bin (Filename.concat moved "operator-evidence") In_channel.input_all))
let retained_record_binding () = with_claim (fun admission directory root ->
  ignore (ok (Socket.acquire ~admission ~directory));
  lease (Lease.retire admission);
  ignore (retain_ok (Socket.retain ~admission ~directory));
  let record=allocation_record admission directory in
  let fields=match Yojson.Safe.from_file record with `Assoc fields -> fields | _ -> Alcotest.fail "record" in
  let altered key value=`Assoc (List.map (fun (name,original) -> name,if name=key then value else original) fields) in
  List.iter (fun value ->
    ok (Fs_compat.save_file_atomic_strict record (Yojson.Safe.to_string value));
    check "unbound or malformed retention is refused" true (Result.is_error (Socket.cleanup ~admission ~directory));
    check "invalid retention preserves the allocation" true (Sys.file_exists root))
    [altered "incarnation" (`String "another-instance");altered "directory" (`String directory);
     altered "state" (`String "unknown");`Assoc (("state",`String "retained")::fields)];
  ok (Fs_compat.save_file_atomic_strict record (Yojson.Safe.to_string (`Assoc fields)));
  let original=Filename.concat directory "original-record" in
  Unix.rename record original; Unix.symlink original record;
  check "a symlink cannot confer retained ownership" true (Result.is_error (Socket.cleanup ~admission ~directory));
  Unix.unlink record;Unix.link original record;
  check "a hardlink cannot confer retained ownership" true (Result.is_error (Socket.cleanup ~admission ~directory)))
let retained_publication_readback () = with_claim ~context:opaque_backends (fun admission directory root ->
  produce_allocation admission directory root;lease (Lease.retire admission);
  let save path contents =
    ok (Fs_compat.save_file_atomic_strict path contents);
    Error {Fs_compat.path;stage=Fs_compat.After_rename;exception_=Failure "fsync failed";
      backtrace=Printexc.get_callstack 0} in
  (match Socket.For_testing.retain ~save ~admission ~directory with
   | Error (Socket.Retained_record_unconfirmed _) -> ()
   | Ok _|Error (Socket.Retain_refused _) -> Alcotest.fail "published handoff must remain unconfirmed");
  let reopened=lease (Lease.reopen ~directories:[directory] ~instance_id:(Lease.instance_id admission)) in
  retained (Socket.cleanup ~admission:reopened ~directory);
  check "published operator allocation survives recovery" true (Sys.file_exists root))
let opaque_release_boundary () = with_claim ~context:opaque_backends (fun admission directory root ->
  lease (Lease.retire admission);
  refused "an unrecorded unknown backend is not reported released" (Socket.retain ~admission ~directory);
  let record=allocation_record admission directory in
  check "a refused unrecorded handoff publishes no marker" false (Sys.file_exists record);
  (* The terminal producer format has no backend payload: release already
     proved that this reservation has no allocation left. *)
  ok (Fs_compat.save_file_atomic_strict record (Yojson.Safe.to_string (`Assoc ["state",`String "released"])));
  released (Socket.cleanup ~admission ~directory);
  ok (Socket.check_retained ~instance_id:(Lease.instance_id admission) ~slot:directory
    (lease (Lease.cleanup_context admission)));
  check "explicit released ownership survives an opaque backend" true
    (retain_ok (Socket.retain ~admission ~directory)=Socket.Allocation_released);
  Unix.mkdir root 0o700;
  check "a released path resurrection is not cleaned" true (Result.is_error (Socket.cleanup ~admission ~directory));
  check "preflight rejects the same resurrection" true
    (Result.is_error (Socket.check_retained ~instance_id:(Lease.instance_id admission) ~slot:directory
      (lease (Lease.cleanup_context admission))));
  refused "handoff cannot bless a released path resurrection" (Socket.retain ~admission ~directory);
  check "the resurrected path survives every refusal" true (Sys.file_exists root))
let () = Alcotest.run "browser addon socket ownership" ["recovery",[
  Alcotest.test_case "original allocation recovery and historical release" `Quick cleanup_after_reopen;
  Alcotest.test_case "crash before acquisition record" `Quick interrupted_acquisition;
  Alcotest.test_case "unconfirmed socket is retained" `Quick unknown_resources;
  Alcotest.test_case "replacement identity is retained" `Quick replaced_directory;
  Alcotest.test_case "model bootstrap cleanup preserves separate receipts" `Quick model_configuration_cleanup;
  Alcotest.test_case "owned backend requires a settled worker and empty resource trees" `Quick owned_backend_cleanup;
  Alcotest.test_case "owned cleanup resumes after interrupted file deletion" `Quick interrupted_owned_cleanup;
  Alcotest.test_case "another source's resources retain the allocation" `Quick foreign_source_resources;
  Alcotest.test_case "the operator retains an unconfirmed allocation in place" `Quick operator_retains_unconfirmed_allocation;
  Alcotest.test_case "retain refuses a replaced allocation directory" `Quick retain_refuses_replaced_directory;
  Alcotest.test_case "retain reports an allocation already released" `Quick retain_reports_a_released_allocation;
  Alcotest.test_case "retain requires a settled Chrome child and signals nothing" `Quick retain_requires_a_settled_child_without_signalling;
  Alcotest.test_case "retain reports where a record write failed" `Quick retain_reports_where_a_record_write_failed;
  Alcotest.test_case "retain refuses a child claim of another allocation" `Quick retain_refuses_a_foreign_child;
  Alcotest.test_case "retain waits until an unpublished child is fenced" `Quick retain_waits_for_an_unpublished_child_to_be_fenced;
  Alcotest.test_case "operator handoff makes backend payloads opaque" `Quick opaque_payload_handoff;
  Alcotest.test_case "retention remains bound to the original host record" `Quick retained_record_binding;
  Alcotest.test_case "published handoff survives an unconfirmed fsync" `Quick retained_publication_readback;
  Alcotest.test_case "released ownership needs an absent original path" `Quick opaque_release_boundary]]
