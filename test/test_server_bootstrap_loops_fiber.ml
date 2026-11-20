(* Server_bootstrap_loops_fiber.run_steps: a step that raises is that step's
   failure. The steps after it still run and the pass returns, so the loop
   that called it reaches its next pass. *)

let run steps =
  let ran = ref [] in
  let failed = ref [] in
  let named (name, step) =
    ( name
    , fun () ->
        ran := name :: !ran;
        step () )
  in
  let outcome =
    match
      Server_bootstrap_loops_fiber.run_steps
        ~on_error:(fun name exn -> failed := (name, Printexc.to_string exn) :: !failed)
        (List.map named steps)
    with
    | () -> Ok ()
    | exception exn -> Error exn
  in
  outcome, List.rev !ran, List.rev !failed
;;

let returned = Alcotest.testable (fun ppf () -> Format.pp_print_string ppf "returned") ( = )
let raised = Alcotest.testable (fun ppf exn -> Format.pp_print_string ppf (Printexc.to_string exn)) ( = )
let outcome = Alcotest.result returned raised
let failures = Alcotest.(list (pair string string))

let test_steps_after_a_raise_still_run () =
  let result, ran, failed =
    run [ "first", Fun.id; "second", (fun () -> failwith "boom"); "third", Fun.id ]
  in
  Alcotest.check outcome "the pass returns" (Ok ()) result;
  Alcotest.(check (list string)) "every step ran" [ "first"; "second"; "third" ] ran;
  Alcotest.check
    failures
    "the raise is the second step's failure"
    [ "second", Printexc.to_string (Failure "boom") ]
    failed
;;

(* A cancellation or an exhausted heap is not the step's failure: the pass
   stops there and the exception goes on up. *)
let test_reserved_exception_goes_up reserved () =
  let result, ran, failed =
    run [ "first", Fun.id; "second", (fun () -> raise reserved); "third", Fun.id ]
  in
  Alcotest.check outcome "the exception leaves the pass" (Error reserved) result;
  Alcotest.(check (list string)) "the step after it did not run" [ "first"; "second" ] ran;
  Alcotest.check failures "it is not reported as a step failure" [] failed
;;

let () =
  Alcotest.run
    "server_bootstrap_loops_fiber"
    [ ( "run_steps"
      , [ Alcotest.test_case "Steps after a raise still run" `Quick test_steps_after_a_raise_still_run
        ; Alcotest.test_case
            "A cancellation goes up"
            `Quick
            (test_reserved_exception_goes_up (Eio.Cancel.Cancelled Exit))
        ; Alcotest.test_case
            "Out of memory goes up"
            `Quick
            (test_reserved_exception_goes_up Out_of_memory)
        ] )
    ]
;;
