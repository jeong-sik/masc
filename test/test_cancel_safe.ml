(** Tests for [Cancel_safe.protect]/[observe] — the RFC-0106 SSOT that
    re-raises [Eio.Cancel.Cancelled] (so cooperative cancellation propagates)
    while routing any other exception to [on_exn]. The keeper turn/create hot
    paths delegate to this combinator; its correctness is what makes those
    catch-alls cancel-safe. *)

open Alcotest

let test_reraises_cancelled () =
  let on_exn_called = ref false in
  let reraised = ref false in
  (try
     ignore
       (Cancel_safe.protect
          ~on_exn:(fun _ ->
            on_exn_called := true;
            0)
          (fun () -> raise (Eio.Cancel.Cancelled (Failure "boom"))))
   with
   | Eio.Cancel.Cancelled _ -> reraised := true);
  check bool "Cancelled propagated to caller" true !reraised;
  check bool "on_exn NOT invoked for Cancelled" false !on_exn_called

let test_routes_other_exn () =
  let r =
    Cancel_safe.protect ~on_exn:(fun _ -> 42) (fun () -> raise (Failure "x"))
  in
  check int "on_exn result becomes the value" 42 r

let test_passes_through_success () =
  let r = Cancel_safe.protect ~on_exn:(fun _ -> 0) (fun () -> 7) in
  check int "success value returned unchanged" 7 r

let test_observe_routes_then_reraises () =
  let logged = ref false in
  Cancel_safe.observe
    ~on_exn:(fun _ -> logged := true)
    (fun () -> raise (Failure "y"));
  check bool "observe routes other exn to on_exn" true !logged;
  let reraised = ref false in
  (try
     Cancel_safe.observe
       ~on_exn:(fun _ -> ())
       (fun () -> raise (Eio.Cancel.Cancelled (Failure "z")))
   with
   | Eio.Cancel.Cancelled _ -> reraised := true);
  check bool "observe re-raises Cancelled" true !reraised

let () =
  run "cancel_safe"
    [ ( "protect"
      , [ test_case "re-raises Cancelled" `Quick test_reraises_cancelled
        ; test_case "routes other exn to on_exn" `Quick test_routes_other_exn
        ; test_case "passes through success" `Quick test_passes_through_success
        ; test_case "observe routes then re-raises Cancelled" `Quick
            test_observe_routes_then_reraises
        ] )
    ]
