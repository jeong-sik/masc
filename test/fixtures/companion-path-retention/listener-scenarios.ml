let with_fixture run =
 let directory=Filename.temp_dir "broker-retention-owned-" "" in
 let socket_path=Filename.concat directory "s" in
 let moved=Filename.concat directory "old" in
 Fun.protect ~finally:(fun () ->
  hooks:=[];fail_close:=false;
  (try Real_unix.unlink socket_path with _ -> ());
  (try Real_unix.unlink moved with _ -> ());
  Real_unix.rmdir directory)
 (fun () -> run directory socket_path moved)
let () =
 with_fixture (fun _ socket_path moved ->
  let shutdown=ref (Ok ()) in
  let fd=private_listener ~sw:() ~socket_path ~shutdown in
  assert (!shutdown=Error Listener_close_unconfirmed);
  Real_unix.rename socket_path moved;
  let successor=Real_unix.socket Real_unix.PF_UNIX Real_unix.SOCK_STREAM 0 in
  Fun.protect ~finally:(fun () -> Real_unix.close successor) (fun () ->
   Real_unix.bind successor (Real_unix.ADDR_UNIX socket_path);
   let identity=Real_unix.lstat socket_path in
   List.iter (fun f -> f ()) !hooks;
   assert (!shutdown=Ok ());
   let current=Real_unix.lstat socket_path in
   assert (identity.st_ino=current.st_ino && identity.st_dev=current.st_dev);
   assert (Sys.file_exists moved);
   assert (try ignore (Real_unix.getsockname fd);false with Real_unix.Unix_error (Real_unix.EBADF,_,_) -> true)));
 print_endline "actual private_listener: close confirmed and successor socket retained PASS";
 with_fixture (fun _ socket_path _ ->
  let shutdown=ref (Ok ()) in
  let fd=private_listener ~sw:() ~socket_path ~shutdown in
  Fun.protect ~finally:(fun () -> fail_close:=false;Real_unix.close fd) (fun () ->
   fail_close:=true;
   List.iter (fun f -> f ()) !hooks;
   assert (!shutdown=Error Listener_close_unconfirmed);
   assert (Sys.file_exists socket_path);
   ignore (Real_unix.getsockname fd)));
 print_endline "actual private_listener: close failure retained as typed error PASS"
