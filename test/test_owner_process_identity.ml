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
        Alcotest.check Alcotest.int "the handle names the child" child (Owner_process_identity.pid handle);
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
let rec retrying f =
  match f () with
  | result -> result
  | exception Unix.Unix_error (Unix.EINTR, _, _) -> retrying f
(* A child locks [length] bytes from [byte] and waits to be killed. [lock] is
   the kind of lock it takes, a write lock unless said. *)
let with_child_lock ?(lock = Unix.F_LOCK) fd ~byte ~length f =
  let ready_read, ready_write = Unix.pipe () in
  let child = Unix.fork () in
  if child = 0 then (
    Unix.close ready_read;
    ignore (Unix.lseek fd byte Unix.SEEK_SET);
    Unix.lockf fd lock length;
    ignore (Unix.write_substring ready_write "r" 0 1);
    Unix.close ready_write;
    while true do Unix.pause () done);
  Unix.close ready_write;
  Fun.protect
    ~finally:(fun () ->
      Unix.close ready_read;
      (try Unix.kill child Sys.sigkill with Unix.Unix_error _ -> ());
      ignore (retrying (fun () -> Unix.waitpid [] child)))
    (fun () ->
      let ready = Bytes.create 1 in
      ignore (retrying (fun () -> Unix.read ready_read ready 0 1));
      f child)
let test_held_byte () =
  let path = Filename.temp_file "masc-identity-fixture-" ".byte" in
  let fd = Unix.openfile path [Unix.O_RDWR] 0o600 in
  let byte = 9000 in
  Fun.protect ~finally:(fun () -> Unix.close fd; Sys.remove path) (fun () ->
    (match Owner_process_identity.held_byte fd with
     | Ok None -> () | _ -> Alcotest.fail "a file nobody locked named a holder");
    with_child_lock fd ~byte ~length:1 (fun child ->
      match Owner_process_identity.held_byte fd with
      | Ok (Some { holder; byte = seen }) ->
        Alcotest.check Alcotest.int "the holder is the child" child holder;
        Alcotest.check Alcotest.int "the byte is the one it locked" byte seen
      | _ -> Alcotest.fail "the lock of the child was not read");
    (match Owner_process_identity.held_byte fd with
     | Ok None -> () | _ -> Alcotest.fail "a lock outlived its holder");
    Alcotest.check Alcotest.int "nothing was written to the file" 0 (Unix.fstat fd).Unix.st_size;
    with_child_lock fd ~byte ~length:2 (fun (_ : int) ->
      match Owner_process_identity.held_byte fd with
      | Ok None -> ()
      | _ -> Alcotest.fail "a lock of two bytes was read as a byte lock"))
(* The question about one byte is answered the same whatever other processes
   hold on other bytes, and in whichever order the locks were taken. The
   question about the whole file names one lock and hides the other. *)
let test_byte_holder () =
  let path = Filename.temp_file "masc-identity-fixture-" ".byte" in
  let fd = Unix.openfile path [Unix.O_RDWR] 0o600 in
  let holder_of byte =
    match Owner_process_identity.byte_holder fd ~byte with
    | Ok holder -> holder
    | Error _ -> Alcotest.fail "the kernel could not be asked about the byte" in
  let holder = Alcotest.(option int) in
  let earlier_byte = 9000 and later_byte = 100 in
  Fun.protect ~finally:(fun () -> Unix.close fd; Sys.remove path) (fun () ->
    Alcotest.check holder "a byte nobody locked" None (holder_of earlier_byte);
    with_child_lock fd ~byte:earlier_byte ~length:1 (fun earlier ->
      with_child_lock fd ~byte:later_byte ~length:1 (fun later ->
        Alcotest.check holder "the byte locked first" (Some earlier) (holder_of earlier_byte);
        Alcotest.check holder "the byte locked second" (Some later) (holder_of later_byte);
        Alcotest.check holder "the byte after a locked one" None (holder_of (later_byte + 1));
        Alcotest.check holder "the byte before a locked one" None (holder_of (earlier_byte - 1));
        (match Owner_process_identity.held_byte fd with
         | Ok (Some { holder; byte }) ->
           Alcotest.check Alcotest.bool "the whole file names one of the two" true
             ((holder, byte) = (earlier, earlier_byte) || (holder, byte) = (later, later_byte))
         | _ -> Alcotest.fail "the whole file named neither lock"));
      Alcotest.check holder "the first lock, once the second holder is gone" (Some earlier)
        (holder_of earlier_byte);
      Alcotest.check holder "the byte of a holder that is gone" None (holder_of later_byte));
    with_child_lock ~lock:Unix.F_RLOCK fd ~byte:earlier_byte ~length:1 (fun (_ : int) ->
      Alcotest.check holder "a read lock is no byte lock" None (holder_of earlier_byte));
    with_child_lock fd ~byte:(earlier_byte - 1) ~length:2 (fun (_ : int) ->
      Alcotest.check holder "a lock of two bytes is no byte lock" None (holder_of earlier_byte));
    (match Owner_process_identity.byte_holder fd ~byte:(-1) with
     | Error Unavailable -> ()
     | _ -> Alcotest.fail "the kernel answered about a byte before the file");
    Alcotest.check Alcotest.int "nothing was written to the file" 0 (Unix.fstat fd).Unix.st_size)
let () = Alcotest.run "owner process identity"
  ["lease owner",[Alcotest.test_case "owned child graceful signal" `Quick test_kernel_owner_graceful_signal];
   "held byte",[Alcotest.test_case "the holder and the byte of a lock, while it is held" `Quick test_held_byte;
     Alcotest.test_case "the holder of one byte, beside other locks" `Quick test_byte_holder]]
