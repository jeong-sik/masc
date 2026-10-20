module Lease = Native_addon_lease
module Socket = Masc.Browser_addon_socket
let ok = function Ok value -> value | Error detail -> Alcotest.fail detail
let lease result = result |> Result.map_error Lease.error_to_string |> ok
let check = Alcotest.check Alcotest.bool
let rec remove path = match (Unix.lstat path).Unix.st_kind with
  | Unix.S_DIR -> Array.iter (fun name -> remove (Filename.concat path name)) (Sys.readdir path);Unix.rmdir path
  | Unix.S_REG|Unix.S_LNK|Unix.S_CHR|Unix.S_BLK|Unix.S_FIFO|Unix.S_SOCK -> Unix.unlink path
let with_claim ?(automation=None) ?(models=fun _ -> None) work =
  let directory=Filename.temp_file "browser-addon-slot-" "" in
  Unix.unlink directory;Unix.mkdir directory 0o700;
  let instance_id=Uuidm.(to_string (v4_gen (Random.State.make_self_init ()) ())) in
  let context=ok (Socket.context ~instance_id ~automation ~models:(models directory)) in
  let root=match context with `Assoc fields -> (match List.assoc_opt "directory" fields with
    | Some (`String root) -> root | _ -> Alcotest.fail "missing allocation directory")
    | _ -> Alcotest.fail "invalid allocation intent" in
  check "new allocation is absent" false (Sys.file_exists root);
  Fun.protect ~finally:(fun () ->
    if Sys.file_exists root then remove root;
    remove directory) (fun () ->
    let admission=lease (Lease.prepare ~directories:[directory] ~instance_id ~cleanup_context:(Some context)) in
    work admission directory root)
let socket path =
  let descriptor=Unix.socket ~cloexec:true Unix.PF_UNIX Unix.SOCK_STREAM 0 in
  Fun.protect ~finally:(fun () -> Unix.close descriptor) (fun () -> Unix.bind descriptor (Unix.ADDR_UNIX path))
let cleanup_after_reopen () = with_claim (fun admission directory root ->
  let owned=ok (Socket.acquire ~admission ~directory) in
  socket (Socket.socket_path owned);
  check "cannot release a launchable reservation" true (Result.is_error (Socket.cleanup ~admission ~directory));
  lease (Lease.retire admission);
  let recovered=lease (Lease.reopen ~directories:[directory] ~instance_id:(Lease.instance_id admission)) in
  ok (Socket.cleanup ~admission:recovered ~directory);
  check "original socket directory removed" false (Sys.file_exists root);
  ok (Socket.cleanup ~admission:recovered ~directory);
  Unix.mkdir root 0o700;
  check "released path resurrection is refused" true (Result.is_error (Socket.cleanup ~admission:recovered ~directory));
  check "new directory was preserved" true (Sys.file_exists root))
let interrupted_acquisition () = with_claim (fun admission directory root ->
  Unix.mkdir root 0o700;
  lease (Lease.retire admission);
  ok (Socket.cleanup ~admission ~directory);
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
    ok (Socket.cleanup ~admission ~directory);
    check "model bootstrap is released with original allocation" false (Sys.file_exists root);
    check "separate model receipts survive resource cleanup" true (Sys.file_exists retained))
let owned_backend_cleanup () =
  with_claim ~automation:(Some {Browser_configuration.driver="/usr/bin/geckodriver";binary=None})
    (fun admission directory root ->
      ignore (ok (Socket.acquire ~admission ~directory));
      let profiles=Filename.concat root "profiles" and downloads=Filename.concat root "downloads" in
      Unix.mkdir profiles 0o700;Unix.mkdir downloads 0o700;
      Unix.mkdir (Filename.concat downloads "session") 0o700;
      let file=Filename.concat profiles "still-in-use" in
      Out_channel.with_open_bin file (fun out -> output_string out "preserve");
      lease (Lease.retire admission);
      check "missing worker receipt retains allocation" true (Result.is_error (Socket.cleanup ~admission ~directory));
      let receipt=Filename.concat root "automation-closed.json" in
      let write id=Out_channel.with_open_bin receipt (fun out ->
        output_string out (Yojson.Safe.to_string (`Assoc ["incarnation",`String id]))) in
      write "another-worker";
      check "other worker receipt is refused" true (Result.is_error (Socket.cleanup ~admission ~directory));
      write (Lease.instance_id admission);
      check "receipt alone cannot discard profile contents" true (Result.is_error (Socket.cleanup ~admission ~directory));
      check "unconfirmed profile content remains" true (Sys.file_exists file);
      Unix.unlink file;
      ok (Socket.cleanup ~admission ~directory);
      check "receipt and empty trees release allocation" false (Sys.file_exists root))
let interrupted_owned_cleanup () =
  with_claim ~automation:(Some {Browser_configuration.driver="/usr/bin/geckodriver";binary=None})
    (fun admission directory root ->
      ignore (ok (Socket.acquire ~admission ~directory));
      let receipt=Filename.concat root "automation-closed.json" in
      Out_channel.with_open_bin receipt (fun out -> output_string out
        (Yojson.Safe.to_string (`Assoc ["incarnation",`String (Lease.instance_id admission)])));
      (* A known leaf cannot be removed: commit cleanup evidence, then fail
         during deletion. Resume after some earlier leaves already disappeared. *)
      let obstruction=Filename.concat root "webdriver.log" in
      Unix.mkdir obstruction 0o700;
      lease (Lease.retire admission);
      check "interrupted deletion is reported" true (Result.is_error (Socket.cleanup ~admission ~directory));
      List.iter (fun name -> let path=Filename.concat root name in
        if Sys.file_exists path then Unix.unlink path) ["automation.json";"automation-closed.json"];
      Unix.rmdir obstruction;
      ok (Socket.cleanup ~admission ~directory);
      check "durable cleanup evidence resumes after receipt deletion" false (Sys.file_exists root))
let () = Alcotest.run "browser addon socket ownership" ["recovery",[
  Alcotest.test_case "original allocation recovery and historical release" `Quick cleanup_after_reopen;
  Alcotest.test_case "crash before acquisition record" `Quick interrupted_acquisition;
  Alcotest.test_case "unconfirmed socket is retained" `Quick unknown_resources;
  Alcotest.test_case "replacement identity is retained" `Quick replaced_directory;
  Alcotest.test_case "model bootstrap cleanup preserves separate receipts" `Quick model_configuration_cleanup;
  Alcotest.test_case "owned backend requires receipt and empty resource trees" `Quick owned_backend_cleanup;
  Alcotest.test_case "owned cleanup resumes after interrupted file deletion" `Quick interrupted_owned_cleanup]]
