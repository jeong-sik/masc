(** Concurrency tests for {!Context} under Eio fibers.

    Verifies that the default Eio-backed context survives parallel access from
    multiple fibers without deadlock or crash. *)

open Agent_sdk

let test_concurrent_context_access () =
  Eio_main.run
  @@ fun _env ->
  Eio.Switch.run
  @@ fun sw ->
  let ctx = Context.create () in
  let f n =
    Eio.Fiber.fork ~sw (fun () ->
      for i = 1 to 100 do
        Context.set ctx ("key" ^ string_of_int n) (`Int i)
      done)
  in
  List.iter f [ 1; 2; 3 ];
  (* If we get here without deadlock or exception, the test passes. *)
  ()
;;

let () =
  Alcotest.run
    "Context_concurrency"
    [ ( "fiber safety"
      , [ Alcotest.test_case
            "concurrent set under Eio"
            `Quick
            test_concurrent_context_access
        ] )
    ]
;;
