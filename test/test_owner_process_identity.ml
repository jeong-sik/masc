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
let test_self_capture_preserves_lease () =
  let root = Filename.temp_dir "masc-self-lease-" "" |> Unix.realpath in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree root) (fun () ->
    let workspace = Filename.concat root "workspace" in
    let run_dir = Filename.concat root "run" in
    Unix.mkdir workspace 0o700;
    Unix.mkdir run_dir 0o700;
    let open Server_startup_takeover in
    match acquire_base_path_lock ~run_dir workspace with
    | Base_path_already_owned _ | Base_path_rejected _ -> Alcotest.fail "fixture lease unavailable"
    | Base_path_acquired lease ->
      Fun.protect ~finally:(fun () -> release_base_path_lease lease) (fun () ->
        (match capture_existing_owner ~run_dir ~base_path:workspace with
         | Error Current_process_owner -> ()
         | _ -> Alcotest.fail "current process must not capture its own lease");
        (* Closing another descriptor for the same inode would release the
           parent's POSIX lock. A fresh child must still be unable to acquire it. *)
        let child = Unix.fork () in
        if child = 0 then (
          let path = base_path_lock_path ~run_dir ~canonical_base_path:workspace in
          let fd = Unix.openfile path [Unix.O_RDWR] 0 in
          let code = try Unix.lockf fd Unix.F_TLOCK 0; 1 with
            | Unix.Unix_error ((Unix.EACCES | Unix.EAGAIN), _, _) -> 0
            | Unix.Unix_error _ -> 2 in
          Unix.close fd;
          Unix._exit code);
        let _, status = Unix.waitpid [] child in
        Alcotest.check Alcotest.bool "capture refusal preserved kernel lease" true
          (status = Unix.WEXITED 0)))
let () = Alcotest.run "owner process identity"
  ["lease owner",[Alcotest.test_case "owned child graceful signal" `Quick test_kernel_owner_graceful_signal;
    Alcotest.test_case "self capture preserves kernel lock" `Quick test_self_capture_preserves_lease]]
