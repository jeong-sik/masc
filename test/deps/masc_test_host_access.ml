(* Every test executable that links [masc_test_deps] is a host tool on a base
   path never set up for accounts. It publishes that access once, when it
   starts and before its first case, the way a host tool publishes it
   ({!Runtime_account_access.publish_host_tool}): the single user of a fresh
   base path. A case that asks for the access then finds the host of a single
   user.

   A process publishes its access once. A test that publishes another access
   itself, a multi-account zone or the publication under test, lists its
   libraries without [masc_test_deps]. *)
let () =
  let root = Filename.temp_dir "masc-test-account-access-" "" in
  let published =
    Eio_main.run (fun _env ->
      Runtime_account_access.publish_host_tool
        ~base_path:root ~config_dir:(Some (Filename.concat root "config")))
  in
  Unix.rmdir root;
  match published with
  | Ok () -> ()
  | Error (first, _) -> failwith first
;;
