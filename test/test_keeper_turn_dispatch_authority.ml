open Masc

let failures = ref 0

let check name condition =
  if condition
  then Printf.printf "  ✓ %s\n%!" name
  else (
    incr failures;
    Printf.printf "  ✗ %s\n%!" name)
;;

let test_selected_authority_rejection_has_zero_provider_dispatch () =
  let dispatch_count = ref 0 in
  let captured_token = ref None in
  let result =
    Keeper_turn_dispatch_authority.run (fun token ->
      captured_token := Some token;
      (match
         Keeper_turn_dispatch_authority.install
           token
           (fun () -> Error "selected pending source changed")
       with
       | Ok () -> ()
       | Error _ -> check "dispatch authority installs once" false);
      Keeper_unified_turn_execution.run_provider_dispatch_if_authorized
        ~before_dispatch_authority:
          (fun () -> Keeper_turn_dispatch_authority.validate token)
        (fun () ->
           incr dispatch_count;
           Ok ()))
  in
  check "authority failure is typed" (Result.is_error result);
  check "provider dispatch closure was not called" (!dispatch_count = 0);
  match !captured_token with
  | None -> check "released token was captured" false
  | Some token ->
    check
      "released token cannot dispatch"
      (Result.is_error (Keeper_turn_dispatch_authority.validate token))
;;

let test_install_is_single_assignment () =
  Keeper_turn_dispatch_authority.run (fun token ->
    check
      "first validator installs"
      (Result.is_ok (Keeper_turn_dispatch_authority.install token (fun () -> Ok ())));
    check
      "second validator is rejected"
      (Result.is_error
         (Keeper_turn_dispatch_authority.install token (fun () -> Ok ()))))
;;

let () =
  test_selected_authority_rejection_has_zero_provider_dispatch ();
  test_install_is_single_assignment ();
  if !failures > 0
  then (
    Printf.printf "FAILED: %d check(s)\n%!" !failures;
    exit 1)
  else Printf.printf "All keeper_turn_dispatch_authority checks passed\n%!"
;;
