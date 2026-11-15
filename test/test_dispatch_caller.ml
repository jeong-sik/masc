(** Tests for the Keeper binding that dispatch observers read. *)

let eio_test name fn =
  Alcotest.test_case name `Quick (fun () -> Eio_main.run (fun _env -> fn ()))

let keeper = Alcotest.(option string)

let test_no_keeper_outside_a_binding () =
  Alcotest.check keeper "nothing bound" None (Dispatch_caller.current_keeper ())

let test_binding_ends_with_its_scope () =
  let inside = Dispatch_caller.with_keeper "alpha" Dispatch_caller.current_keeper in
  Alcotest.check keeper "the bound Keeper inside" (Some "alpha") inside;
  Alcotest.check keeper "none after the scope" None (Dispatch_caller.current_keeper ())

let test_inner_binding_wins_and_restores () =
  Dispatch_caller.with_keeper "alpha" (fun () ->
    let inner = Dispatch_caller.with_keeper "beta" Dispatch_caller.current_keeper in
    Alcotest.check keeper "the inner Keeper" (Some "beta") inner;
    Alcotest.check keeper
      "the outer Keeper again"
      (Some "alpha")
      (Dispatch_caller.current_keeper ()))

let test_forked_fibers_see_the_binding_they_were_forked_in () =
  let seen = ref [] in
  let record label = seen := (label, Dispatch_caller.current_keeper ()) :: !seen in
  Eio.Fiber.all
    [ (fun () ->
        Dispatch_caller.with_keeper "alpha" (fun () ->
          Eio.Fiber.both
            (fun () -> Eio.Fiber.yield (); record "alpha child")
            (fun () -> record "alpha sibling")))
    ; (fun () ->
        Dispatch_caller.with_keeper "beta" (fun () ->
          Eio.Fiber.yield ();
          record "beta"))
    ; (fun () -> record "unbound")
    ];
  let check label expected =
    Alcotest.check keeper label expected (List.assoc label !seen)
  in
  check "alpha child" (Some "alpha");
  check "alpha sibling" (Some "alpha");
  check "beta" (Some "beta");
  check "unbound" None

let () =
  Alcotest.run
    "Dispatch_caller"
    [ ( "binding"
      , [ eio_test "no Keeper outside a binding" test_no_keeper_outside_a_binding
        ; eio_test "a binding ends with its scope" test_binding_ends_with_its_scope
        ; eio_test "an inner binding wins and the outer one returns" test_inner_binding_wins_and_restores
        ; eio_test
            "forked fibers see the binding they were forked in"
            test_forked_fibers_see_the_binding_they_were_forked_in
        ] )
    ]
