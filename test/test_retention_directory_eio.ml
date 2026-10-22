module Directory = Fs_compat.Retention_directory

let test_cancel_closes_owned_scope () =
  Eio_main.run @@ fun _env ->
  let path = Filename.temp_file "masc-retention-cancel-" "" in
  Sys.remove path;
  Unix.mkdir path 0o700;
  let path = Unix.realpath path in
  let ready, signal_ready = Eio.Promise.create () in
  let never, _signal_never = Eio.Promise.create () in
  let escaped = ref None in
  Eio.Fiber.first
    (fun () ->
       ignore (Directory.with_root path (fun directory ->
         escaped := Some directory;
         Eio.Promise.resolve signal_ready ();
         Eio.Promise.await never)))
    (fun () -> Eio.Promise.await ready);
  let directory = Option.get !escaped in
  let other = Unix.openfile path [Unix.O_RDONLY] 0 in
  Fun.protect ~finally:(fun () -> Unix.close other) (fun () ->
    Alcotest.check_raises "cancelled scope cannot access a later descriptor"
      (Invalid_argument "expired retention directory")
      (fun () -> ignore (Directory.names directory : string list));
    List.iter (fun operation ->
      Alcotest.check_raises "cancelled scope cannot perform checked removals"
        (Invalid_argument "expired retention directory")
        (fun () -> ignore (operation directory "absent" : bool)))
      [Directory.unlink_entry; Directory.remove_empty_child_checked])

let () = Alcotest.run "retention cancellation"
  ["owned scope", [Alcotest.test_case "cancellation expires bound handle" `Quick test_cancel_closes_owned_scope]]
