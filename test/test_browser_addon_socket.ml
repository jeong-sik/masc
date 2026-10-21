module Lease = Native_addon_lease
module Socket = Masc.Browser_addon_socket
let ok = function Ok value -> value | Error detail -> Alcotest.fail detail
let lease result = result |> Result.map_error Lease.error_to_string |> ok
let check = Alcotest.check Alcotest.bool
let rec remove path = match (Unix.lstat path).Unix.st_kind with
  | Unix.S_DIR -> Array.iter (fun name -> remove (Filename.concat path name)) (Sys.readdir path);Unix.rmdir path
  | Unix.S_REG|Unix.S_LNK|Unix.S_CHR|Unix.S_BLK|Unix.S_FIFO|Unix.S_SOCK -> Unix.unlink path
let with_claim work =
  let directory=Filename.temp_file "browser-addon-slot-" "" in
  Unix.unlink directory;Unix.mkdir directory 0o700;
  let instance_id=Uuidm.(to_string (v4_gen (Random.State.make_self_init ()) ())) in
  let context=ok (Socket.context ~instance_id) in
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
let () = Alcotest.run "browser addon socket ownership" ["recovery",[
  Alcotest.test_case "original allocation recovery and historical release" `Quick cleanup_after_reopen;
  Alcotest.test_case "crash before acquisition record" `Quick interrupted_acquisition;
  Alcotest.test_case "unconfirmed socket is retained" `Quick unknown_resources;
  Alcotest.test_case "replacement identity is retained" `Quick replaced_directory]]
