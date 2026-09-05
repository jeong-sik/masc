open Alcotest

let fixed_clock = fun () -> 0.0

let with_clean_registry f =
  Heap_roots.clear_for_tests ();
  Fun.protect ~finally:Heap_roots.clear_for_tests f
;;

let test_measures_a_registered_value () =
  with_clean_registry @@ fun () ->
  let held = Array.make 4096 "x" in
  (match Heap_roots.register ~name:"array" (fun () -> Some (Obj.repr held)) with
   | Ok () -> ()
   | Error `Duplicate -> fail "fresh name refused");
  match Heap_roots.measure ~now:fixed_clock () with
  | [ { Heap_roots.name = "array"; measurement = Words words; _ } ] ->
    (* 4096 slots plus the header, at least; the shared "x" counts once. *)
    check bool "walk sees the array" true (words > 4096)
  | _ -> fail "one measured reading expected"
;;

let test_absent_and_failed_roots_are_named () =
  with_clean_registry @@ fun () ->
  let ok = Heap_roots.register ~name:"absent" (fun () -> None) in
  let ok2 = Heap_roots.register ~name:"raises" (fun () -> failwith "boom") in
  check bool "both registered" true (Result.is_ok ok && Result.is_ok ok2);
  match Heap_roots.measure ~now:fixed_clock () with
  | [ { Heap_roots.name = "absent"; measurement = Absent; _ }
    ; { Heap_roots.name = "raises"; measurement = Failed message; _ } ] ->
    check bool "error text kept" true (String.length message > 0)
  | _ -> fail "readings in registration order with absent then failed"
;;

let test_duplicate_names_are_refused () =
  with_clean_registry @@ fun () ->
  let first = Heap_roots.register ~name:"same" (fun () -> None) in
  let second = Heap_roots.register ~name:"same" (fun () -> None) in
  check bool "first accepted" true (Result.is_ok first);
  (match second with
   | Error `Duplicate -> ()
   | Ok () -> fail "second registration under the same name was accepted");
  check (list string) "one root" [ "same" ] (Heap_roots.registered ())
;;

let test_wire_shape () =
  let json =
    Heap_roots.reading_to_yojson
      { Heap_roots.name = "r"; measurement = Words 10; walk_ms = 1.5 }
  in
  match json with
  | `Assoc fields ->
    check bool "measured" true (List.mem ("status", `String "measured") fields);
    check bool "bytes are words times the word size" true
      (List.mem ("bytes", `Int (Heap_roots.words_to_bytes 10)) fields);
    check bool "walk_ms" true (List.mem ("walk_ms", `Float 1.5) fields)
  | _ -> fail "object"
;;

let () =
  run
    "heap_roots"
    [ ( "readings"
      , [ test_case "measures a registered value" `Quick test_measures_a_registered_value
        ; test_case "absent and failed are named" `Quick test_absent_and_failed_roots_are_named
        ; test_case "duplicates refused" `Quick test_duplicate_names_are_refused
        ; test_case "wire shape" `Quick test_wire_shape
        ] )
    ]
;;
