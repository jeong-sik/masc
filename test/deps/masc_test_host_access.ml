(* Every test executable that links [masc_test_deps] is a host tool on a base
   path never set up for accounts. It publishes that access once, when it
   starts and before its first case, the way a host tool publishes it
   ({!Runtime_account_access.publish_host_tool}): the single user of a fresh
   base path. A case that asks for the access then finds the host of a single
   user.

   A process publishes its access once. A test that publishes another access
   itself, a multi-account zone or the publication under test, lists its
   libraries without [masc_test_deps].

   The Eio posix backend sets a SIGCHLD handler when a run starts and leaves it
   set when the run returns. With that handler left behind, a case that never
   runs an Eio loop and waits for a child with a blocking [Unix.waitpid] or
   [Unix.read] gets EINTR when the child exits (#51254: 15 of the 29
   [test_repo_git] cases on macOS). So this run puts back the SIGCHLD
   behavior it found. A case that runs an Eio loop of its own gets the
   handler again from that run. *)
let () =
  let root = Filename.temp_dir "masc-test-account-access-" "" in
  let sigchld_before = Sys.signal Sys.sigchld Sys.Signal_default in
  let published =
    Fun.protect
      ~finally:(fun () -> Sys.set_signal Sys.sigchld sigchld_before)
      (fun () ->
         Eio_main.run (fun _env ->
           Runtime_account_access.publish_host_tool
             ~base_path:root ~config_dir:(Some (Filename.concat root "config"))))
  in
  Unix.rmdir root;
  match published with
  | Ok () -> ()
  | Error (first, _) -> failwith first
;;
