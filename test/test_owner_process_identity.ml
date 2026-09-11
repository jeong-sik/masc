let test_kernel_owner_graceful_signal () =
  let path = Filename.temp_file "masc-identity-fixture-" ".lock" in
  let fd = Unix.openfile path [Unix.O_RDWR] 0o600 in
  Fun.protect ~finally:(fun () -> Unix.close fd; Sys.remove path) (fun () ->
    (match Owner_process_identity.capture ~lease_fd:fd with
     | Error No_owner -> () | _ -> Alcotest.fail "unheld lease authorized signaling");
    let ready_read, ready_write = Unix.pipe () in
    let child = Unix.fork () in
    if child = 0 then (
      Unix.close ready_read;
      Sys.set_signal Sys.sigterm Sys.Signal_default;
      Unix.lockf fd Unix.F_LOCK 0;
      ignore (Unix.write_substring ready_write "r" 0 1);
      Unix.close ready_write;
      while true do Unix.pause () done);
    Unix.close ready_write;
    Fun.protect ~finally:(fun () -> Unix.close ready_read) (fun () ->
      let ready = Bytes.create 1 in
      ignore (Unix.read ready_read ready 0 1);
      let handle = match Owner_process_identity.capture ~lease_fd:fd with
        | Ok handle -> handle
        | Error _ -> Unix.kill child Sys.sigterm; ignore (Unix.waitpid [] child);
          Alcotest.fail "kernel-held child lease could not be captured" in
      Fun.protect ~finally:(fun () -> Owner_process_identity.close handle) (fun () ->
        (match Owner_process_identity.request_termination handle with
         | Ok () -> ()
         | Error _ -> Unix.kill child Sys.sigterm; ignore (Unix.waitpid [] child);
           Alcotest.fail "captured child did not accept graceful termination");
        let _, status = Unix.waitpid [] child in
        Alcotest.check Alcotest.bool "SIGTERM, no escalation" true (status = Unix.WSIGNALED Sys.sigterm);
        (match Owner_process_identity.request_termination handle with
         | Error Owner_changed -> () | _ -> Alcotest.fail "exited owner retained signal authority");
        Owner_process_identity.close handle;
        (match Owner_process_identity.request_termination handle with
         | Error Closed -> () | _ -> Alcotest.fail "closed handle retained authority"))))
let () = Alcotest.run "owner process identity"
  ["lease owner",[Alcotest.test_case "owned child graceful signal" `Quick test_kernel_owner_graceful_signal]]
