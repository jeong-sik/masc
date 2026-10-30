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

let test_validation_before_and_after_install () =
  let calls = ref 0 in
  Keeper_turn_dispatch_authority.run (fun token ->
    check
      "uninitialized authority refuses validation"
      (Result.is_error (Keeper_turn_dispatch_authority.validate token));
    check
      "validator installs"
      (Result.is_ok (Keeper_turn_dispatch_authority.install token (fun () ->
         incr calls;
         Error "input changed")));
    check
      "a replacement is refused"
      (Result.is_error (Keeper_turn_dispatch_authority.install token (fun () -> Ok ())));
    check
      "the original rejection is preserved"
      (Keeper_turn_dispatch_authority.validate token = Error "input changed");
    check "only the original validator ran" (!calls = 1))
;;

let test_exception_closes_authority () =
  let captured = ref None in
  let raised =
    try
      Keeper_turn_dispatch_authority.run (fun token ->
        captured := Some token;
        match Keeper_turn_dispatch_authority.install token (fun () -> Ok ()) with
        | Ok () -> failwith "turn failed"
        | Error _ -> ());
      false
    with Failure detail -> String.equal detail "turn failed"
  in
  check "turn exception is propagated" raised;
  match !captured with
  | None -> check "authority was captured" false
  | Some token ->
    check "exception closes validation"
      (Result.is_error (Keeper_turn_dispatch_authority.validate token));
    check "exception closes installation"
      (Result.is_error (Keeper_turn_dispatch_authority.install token (fun () -> Ok ())))
;;

let test_closed_token_releases_validator_capture () =
  let capture () =
    let payload = Bytes.of_string (Sys.opaque_identity "selected source") in
    let weak = Weak.create 1 in
    Weak.set weak 0 (Some payload);
    let token = Keeper_turn_dispatch_authority.run (fun token ->
      (match Keeper_turn_dispatch_authority.install token (fun () ->
         if Bytes.get payload 0 = 's' then Ok () else Error "changed") with
       | Ok () -> ()
       | Error _ -> check "capture validator installs" false);
      token)
    in
    weak, token
  in
  let weak, token = capture () in
  Gc.full_major ();
  Gc.full_major ();
  check "closed token releases validator capture" (not (Weak.check weak 0));
  check "closed token remains invalid" (Result.is_error (Keeper_turn_dispatch_authority.validate token))
;;

let test_parallel_install_is_single_assignment () =
  let token = Keeper_turn_dispatch_authority.run (fun token ->
    let start = Atomic.make false in
    let install reason =
      Domain.spawn (fun () ->
        while not (Atomic.get start) do Domain.cpu_relax () done;
        Keeper_turn_dispatch_authority.install token (fun () -> Error reason))
    in
    let first = install "first" and second = install "second" in
    Atomic.set start true;
    let first, second = Domain.join first, Domain.join second in
    let accepted = match first, second with
      | Ok (), Error _ -> Some "first"
      | Error _, Ok () -> Some "second"
      | Ok (), Ok () | Error _, Error _ -> None in
    check "only one parallel validator installs" (Option.is_some accepted);
    check "validation uses the installed validator"
      (match accepted with
       | Some reason -> Keeper_turn_dispatch_authority.validate token = Error reason
       | None -> false);
    token)
  in
  check "completed installation is invalid after scope returns"
    (Result.is_error (Keeper_turn_dispatch_authority.validate token))
;;

let test_late_install_cannot_revive_token () =
  let token, installer, start = Keeper_turn_dispatch_authority.run (fun token ->
    let start = Atomic.make false in
    let installer = Domain.spawn (fun () ->
      while not (Atomic.get start) do Domain.cpu_relax () done;
      Keeper_turn_dispatch_authority.install token (fun () -> Ok ())) in
    token, installer, start)
  in
  Atomic.set start true;
  check "installation after closure is rejected" (Result.is_error (Domain.join installer));
  check "late installation leaves token closed"
    (Result.is_error (Keeper_turn_dispatch_authority.validate token))
;;

let () =
  test_selected_authority_rejection_has_zero_provider_dispatch ();
  test_install_is_single_assignment ();
  test_validation_before_and_after_install ();
  test_exception_closes_authority ();
  test_closed_token_releases_validator_capture ();
  test_parallel_install_is_single_assignment ();
  test_late_install_cannot_revive_token ();
  if !failures > 0
  then (
    Printf.printf "FAILED: %d check(s)\n%!" !failures;
    exit 1)
  else Printf.printf "All keeper_turn_dispatch_authority checks passed\n%!"
;;
