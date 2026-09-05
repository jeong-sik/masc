open Alcotest

let fixed_clock = fun () -> 0.0

let with_clean_registry f =
  Heap_roots.For_testing.clear ();
  Fun.protect ~finally:Heap_roots.For_testing.clear f
;;

let register_or_fail ~name root =
  match Heap_roots.register ~name root with
  | Ok () -> ()
  | Error `Duplicate -> fail ("fresh name refused: " ^ name)
;;

let test_measures_a_registered_value () =
  with_clean_registry @@ fun () ->
  let held = Array.make 4096 "x" in
  register_or_fail ~name:"array" (fun walk -> walk (Some (Obj.repr held)));
  match Heap_roots.measure ~now:fixed_clock () with
  | [ { Heap_roots.name = "array"; measurement = Words words; _ } ] ->
    (* 4096 slots plus the header, at least; the shared "x" counts once. *)
    check bool "walk sees the array" true (words > 4096)
  | _ -> fail "one measured reading expected"
;;

let test_a_root_may_walk_under_its_own_lock () =
  with_clean_registry @@ fun () ->
  let table = Hashtbl.create 8 in
  Hashtbl.replace table "k" (String.make 1000 'v');
  let mutex = Stdlib.Mutex.create () in
  register_or_fail ~name:"locked" (fun walk ->
    Stdlib.Mutex.protect mutex (fun () -> walk (Some (Obj.repr table))));
  (match Heap_roots.measure ~now:fixed_clock () with
   | [ { Heap_roots.measurement = Words words; _ } ] ->
     check bool "walk ran inside the lock" true (words > 100)
   | _ -> fail "one measured reading expected");
  (* The lock was released by the walk: taking it again does not block. *)
  check bool "lock released" true (Stdlib.Mutex.try_lock mutex);
  Stdlib.Mutex.unlock mutex
;;

let test_absent_and_failed_roots_are_named () =
  with_clean_registry @@ fun () ->
  register_or_fail ~name:"absent" (fun walk -> walk None);
  register_or_fail ~name:"raises" (fun _walk -> failwith "boom");
  match Heap_roots.measure ~now:fixed_clock () with
  | [ { Heap_roots.name = "absent"; measurement = Absent; _ }
    ; { Heap_roots.name = "raises"; measurement = Failed message; _ } ] ->
    check bool "error text kept" true (String.length message > 0)
  | _ -> fail "readings in registration order with absent then failed"
;;

let test_duplicate_names_are_refused () =
  with_clean_registry @@ fun () ->
  let first = Heap_roots.register ~name:"same" (fun walk -> walk None) in
  let second = Heap_roots.register ~name:"same" (fun walk -> walk None) in
  check bool "first accepted" true (Result.is_ok first);
  (match second with
   | Error `Duplicate -> ()
   | Ok () -> fail "second registration under the same name was accepted");
  check (list string) "one root" [ "same" ] (Heap_roots.registered ())
;;

let test_wire_shape_and_total () =
  let reading = { Heap_roots.name = "r"; measurement = Words 10; walk_ms = 1.5 } in
  (match Heap_roots.reading_to_yojson reading with
   | `Assoc fields ->
     check bool "measured" true (List.mem ("status", `String "measured") fields);
     check bool "bytes are words times the word size" true
       (List.mem ("bytes", `Int (Heap_roots.words_to_bytes 10)) fields);
     check bool "walk_ms" true (List.mem ("walk_ms", `Float 1.5) fields)
   | _ -> fail "object");
  check (float 1e-9) "total walk" 3.0
    (Heap_roots.total_walk_ms [ reading; { reading with walk_ms = 1.5 } ])
;;

let () =
  run
    "heap_roots"
    [ ( "readings"
      , [ test_case "measures a registered value" `Quick test_measures_a_registered_value
        ; test_case "walks under the root's lock" `Quick test_a_root_may_walk_under_its_own_lock
        ; test_case "absent and failed are named" `Quick test_absent_and_failed_roots_are_named
        ; test_case "duplicates refused" `Quick test_duplicate_names_are_refused
        ; test_case "wire shape and total" `Quick test_wire_shape_and_total
        ] )
    ]
;;
