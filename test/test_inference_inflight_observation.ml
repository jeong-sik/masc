open Alcotest

module Observation = Masc.Inference_inflight_observation

let test_releases_after_success () =
  Eio_main.run @@ fun _env ->
  Observation.For_testing.reset ();
  let result =
    Observation.with_observation ~keeper_name:"keeper" ~runtime_id:"runtime" (fun () ->
      check int "active inside callback" 1 (Observation.active ());
      42)
  in
  check int "callback result" 42 result;
  check int "active after callback" 0 (Observation.active ())
;;

let test_releases_after_exception () =
  Eio_main.run @@ fun _env ->
  Observation.For_testing.reset ();
  (match
     Observation.with_observation ~keeper_name:"keeper" ~runtime_id:"runtime" (fun () ->
       check int "active inside callback" 1 (Observation.active ());
       failwith "boom")
   with
   | exception Failure message when String.equal message "boom" -> ()
   | exception exn -> failf "unexpected exception: %s" (Printexc.to_string exn)
   | _ -> fail "expected callback exception");
  check int "active after exception" 0 (Observation.active ())
;;

let test_snapshot_has_no_capacity_claim () =
  Eio_main.run @@ fun _env ->
  Observation.For_testing.reset ();
  let json = Observation.snapshot_json () in
  check int "active" 0 Yojson.Safe.Util.(json |> member "active" |> to_int);
  check bool
    "no MASC-owned provider capacity"
    true
    Yojson.Safe.Util.(json |> member "max_concurrent" = `Null)
;;

let () =
  run
    "inference_inflight_observation"
    [ ( "observation"
      , [ test_case "release after success" `Quick test_releases_after_success
        ; test_case "release after exception" `Quick test_releases_after_exception
        ; test_case "no capacity claim" `Quick test_snapshot_has_no_capacity_claim
        ] )
    ]
;;
