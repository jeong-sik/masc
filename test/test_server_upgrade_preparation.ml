let test_admin_workspace_and_incarnation () =
  Eio_main.run (fun _ -> Eio.Switch.run (fun sw ->
    let base = Unix.realpath (Filename.get_temp_dir_name ()) in
    let version = ref "0.35.2" and admin = ref true and signals = ref 0 and closes = ref 0 in
    let health () = Ok (Yojson.Safe.to_string (`Assoc ["version",`String !version;
      "paths",`Assoc ["effective_base_path",`String base]])) in
    let prepare () = Server_upgrade_preparation.For_testing.prepare ~sw ~base_path:base
      ~observe:health ~authorize:(fun () -> !admin)
      ~capture:(fun () -> Ok ((fun () -> incr signals; Ok ()),(fun () -> incr closes))) in
    let owner = match prepare () with Ok owner -> owner | Error _ -> Alcotest.fail "valid owner preparation" in
    Alcotest.check Alcotest.int "preparation never stops server" 0 !signals;
    admin := false;
    (match Server_upgrade_preparation.request_termination owner with
     | Error Admin_required -> () | _ -> Alcotest.fail "lost admin permission ignored");
    admin := true; version := "0.35.5";
    (match Server_upgrade_preparation.request_termination owner with
     | Error Incumbent_changed -> () | _ -> Alcotest.fail "replaced incumbent accepted");
    Alcotest.check Alcotest.int "revalidation failures never signal" 0 !signals;
    version := "0.35.2";
    ignore (Server_upgrade_preparation.request_termination owner |> Result.get_ok);
    (match Server_upgrade_preparation.request_termination owner with
     | Error Already_requested -> () | _ -> Alcotest.fail "duplicate request accepted");
    Alcotest.check Alcotest.int "explicit request exactly once" 1 !signals;
    Server_upgrade_preparation.close owner; Server_upgrade_preparation.close owner;
    Alcotest.check Alcotest.int "identity released once" 1 !closes))
let test_other_workspace_never_receives_credentials () =
  Eio_main.run (fun _ -> Eio.Switch.run (fun sw ->
    let authorizations = ref 0 in
    let result = Server_upgrade_preparation.For_testing.prepare ~sw
      ~base_path:(Filename.get_temp_dir_name ())
      ~observe:(fun () -> Ok {|{"version":"0.35.2","paths":{"effective_base_path":"/"}}|})
      ~authorize:(fun () -> incr authorizations; true)
      ~capture:(fun () -> Alcotest.fail "unrelated workspace captured") in
    (match result with Error Different_workspace -> () | _ -> Alcotest.fail "workspace conflict ignored");
    Alcotest.check Alcotest.int "no credential transmission across workspace conflict" 0 !authorizations))
let () = Alcotest.run "upgrade preparation"
  ["owner checks",[Alcotest.test_case "admin and exact incumbent" `Quick test_admin_workspace_and_incarnation;
    Alcotest.test_case "workspace conflict" `Quick test_other_workspace_never_receives_credentials]]
