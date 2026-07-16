module Registry = Keeper_compaction_wake_registry

let keeper value =
  match Keeper_id.Keeper_name.of_string value with
  | Ok keeper -> keeper
  | Error error -> Alcotest.fail error
;;

let alpha = keeper "compaction-alpha"
let beta = keeper "compaction-beta"

let registration = function
  | Ok value -> value
  | Error Registry.Already_registered ->
    Alcotest.fail "unexpected duplicate registration"
;;

let check_equal label expected actual =
  Alcotest.(check bool) label true (expected = actual)
;;

let test_coalesces_and_rearms () =
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun sw ->
  let registry = Registry.create () in
  let actor = registration (Registry.register ~sw registry alpha) in
  (match Registry.register ~sw registry alpha with
   | Error Registry.Already_registered -> ()
   | Ok _ -> Alcotest.fail "duplicate registration accepted");
  check_equal "first hint" Registry.Signaled (Registry.wake registry alpha);
  check_equal "coalesced hint" Registry.Coalesced (Registry.wake registry alpha);
  check_equal "consume hint" Registry.Wake (Registry.await actor);
  check_equal "rearmed hint" Registry.Signaled (Registry.wake registry alpha);
  check_equal "consume rearmed" Registry.Wake (Registry.await actor)
;;

let test_stale_token_cannot_remove_replacement () =
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun sw ->
  let registry = Registry.create () in
  let first = registration (Registry.register ~sw registry alpha) in
  check_equal "first close" Registry.Unregistered (Registry.unregister first);
  let replacement = registration (Registry.register ~sw registry alpha) in
  check_equal
    "stale token"
    Registry.Registration_not_current
    (Registry.unregister first);
  check_equal "replacement signaled" Registry.Signaled
    (Registry.wake registry alpha);
  check_equal "replacement receives hint" Registry.Wake
    (Registry.await replacement)
;;

let test_keeper_lifetimes_are_isolated () =
  Eio_main.run @@ fun _env ->
  let registry = Registry.create () in
  Eio.Switch.run @@ fun beta_sw ->
  let beta_actor = registration (Registry.register ~sw:beta_sw registry beta) in
  Eio.Switch.run (fun alpha_sw ->
    ignore (registration (Registry.register ~sw:alpha_sw registry alpha)));
  check_equal "released keeper absent" Registry.Not_registered
    (Registry.wake registry alpha);
  check_equal "other keeper signaled" Registry.Signaled
    (Registry.wake registry beta);
  check_equal "other keeper receives" Registry.Wake
    (Registry.await beta_actor)
;;

let test_await_propagates_cancellation () =
  let propagated = ref false in
  (try
     Eio_main.run @@ fun _env ->
     Eio.Switch.run @@ fun sw ->
     let registry = Registry.create () in
     let actor = registration (Registry.register ~sw registry alpha) in
     Eio.Cancel.sub (fun context ->
       Eio.Cancel.cancel context Exit;
       ignore (Registry.await actor : Registry.await_result))
   with
   | Eio.Cancel.Cancelled _ -> propagated := true);
  Alcotest.(check bool) "await cancellation propagated" true !propagated
;;

let () =
  Alcotest.run
    "keeper compaction wake registry"
    [ ( "wake hints"
      , [ Alcotest.test_case "coalesces and rearms" `Quick
            test_coalesces_and_rearms
        ; Alcotest.test_case "stale token replacement" `Quick
            test_stale_token_cannot_remove_replacement
        ; Alcotest.test_case "keeper isolation" `Quick
            test_keeper_lifetimes_are_isolated
        ; Alcotest.test_case "cancellation propagation" `Quick
            test_await_propagates_cancellation
        ] )
    ]
