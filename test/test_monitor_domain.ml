(* RFC-0379 monitor domain: transition matrix, lifecycle predicates,
   creation validation, and closed codecs. *)

open Alcotest
module M = Monitor_domain

let port_up = M.Port_up { host = "127.0.0.1"; port = 8935 }
let port_down = M.Port_down { host = "127.0.0.1"; port = 8935 }
let file_changed = M.File_changed { path = "/tmp/watched" }
let snapshot_a = M.File_snapshot { mtime = 100.0; inode = 7 }
let snapshot_b = M.File_snapshot { mtime = 200.0; inode = 7 }
let snapshot_c = M.File_snapshot { mtime = 100.0; inode = 9 }

let fired = function
  | M.Fire _ -> true
  | M.Hold -> false
;;

let check_fire name expected trigger ~prev ~current =
  check bool name expected (fired (M.decide trigger ~prev ~current))
;;

let test_baseline_never_fires () =
  check_fire "port_up baseline" false port_up ~prev:None ~current:M.Reachable;
  check_fire "port_down baseline" false port_down ~prev:None ~current:M.Unreachable;
  check_fire "file baseline" false file_changed ~prev:None ~current:snapshot_a
;;

let test_reachability_edges () =
  check_fire "port_up fires on down->up" true port_up
    ~prev:(Some M.Unreachable) ~current:M.Reachable;
  check_fire "port_up holds on up->up" false port_up
    ~prev:(Some M.Reachable) ~current:M.Reachable;
  check_fire "port_up holds on up->down" false port_up
    ~prev:(Some M.Reachable) ~current:M.Unreachable;
  check_fire "port_down fires on up->down" true port_down
    ~prev:(Some M.Reachable) ~current:M.Unreachable;
  check_fire "port_down holds on down->up" false port_down
    ~prev:(Some M.Unreachable) ~current:M.Reachable;
  check_fire "port_down holds on steady down" false port_down
    ~prev:(Some M.Unreachable) ~current:M.Unreachable
;;

let test_file_edges () =
  check_fire "same snapshot holds" false file_changed
    ~prev:(Some snapshot_a) ~current:snapshot_a;
  check_fire "mtime change fires" true file_changed
    ~prev:(Some snapshot_a) ~current:snapshot_b;
  check_fire "inode change fires" true file_changed
    ~prev:(Some snapshot_a) ~current:snapshot_c;
  check_fire "absent->present fires" true file_changed
    ~prev:(Some M.File_absent) ~current:snapshot_a;
  check_fire "present->absent fires" true file_changed
    ~prev:(Some snapshot_a) ~current:M.File_absent;
  check_fire "absent->absent holds" false file_changed
    ~prev:(Some M.File_absent) ~current:M.File_absent
;;

let test_incoherent_pairs_hold () =
  check_fire "port trigger with file prev holds" false port_up
    ~prev:(Some snapshot_a) ~current:M.Reachable;
  check_fire "port trigger with file current holds" false port_up
    ~prev:(Some M.Unreachable) ~current:snapshot_a;
  check_fire "file trigger with reachability holds" false file_changed
    ~prev:(Some M.Reachable) ~current:M.Unreachable
;;

let record ?(max_fires = 1) ?(fired_count = 0) () : M.t =
  { id = "mon-test"
  ; keeper = "rondo"
  ; trigger = port_up
  ; payload = `Assoc [ "note", `String "verify boot" ]
  ; expires_at = 1_000.0
  ; max_fires
  ; fired_count
  ; created_at = 500.0
  ; last_observation = None
  }
;;

let test_lifecycle_predicates () =
  check bool "not expired before expires_at" false
    (M.expired (record ()) ~now:999.9);
  check bool "expired at expires_at" true (M.expired (record ()) ~now:1_000.0);
  check bool "fresh record is not exhausted" false (M.exhausted (record ()));
  check bool "fired one-shot is exhausted" true
    (M.exhausted (record ~fired_count:1 ()));
  check bool "multi-fire below cap is not exhausted" false
    (M.exhausted (record ~max_fires:3 ~fired_count:2 ()))
;;

let expect_error name = function
  | Error _ -> ()
  | Ok () -> fail (name ^ ": expected a validation error")
;;

let test_validate_create () =
  (match
     M.validate_create ~keeper:"rondo" ~trigger:port_up ~expires_at:200.0
       ~max_fires:1 ~now:100.0
   with
   | Ok () -> ()
   | Error e -> fail ("valid create rejected: " ^ e));
  expect_error "blank keeper"
    (M.validate_create ~keeper:" " ~trigger:port_up ~expires_at:200.0 ~max_fires:1
       ~now:100.0);
  expect_error "port zero"
    (M.validate_create ~keeper:"rondo"
       ~trigger:(M.Port_up { host = "127.0.0.1"; port = 0 })
       ~expires_at:200.0 ~max_fires:1 ~now:100.0);
  expect_error "port over 65535"
    (M.validate_create ~keeper:"rondo"
       ~trigger:(M.Port_up { host = "127.0.0.1"; port = 70_000 })
       ~expires_at:200.0 ~max_fires:1 ~now:100.0);
  expect_error "blank path"
    (M.validate_create ~keeper:"rondo"
       ~trigger:(M.File_changed { path = "" })
       ~expires_at:200.0 ~max_fires:1 ~now:100.0);
  expect_error "past expires_at"
    (M.validate_create ~keeper:"rondo" ~trigger:port_up ~expires_at:99.0
       ~max_fires:1 ~now:100.0);
  expect_error "zero max_fires"
    (M.validate_create ~keeper:"rondo" ~trigger:port_up ~expires_at:200.0
       ~max_fires:0 ~now:100.0)
;;

let expect_ok = function
  | Ok value -> value
  | Error e -> fail ("unexpected decode error: " ^ e)
;;

let test_trigger_codec_roundtrip () =
  List.iter
    (fun trigger ->
       let decoded = M.trigger_to_yojson trigger |> M.trigger_of_yojson |> expect_ok in
       check bool "trigger roundtrips" true (decoded = trigger))
    [ port_up; port_down; file_changed ];
  (match M.trigger_of_yojson (`Assoc [ "kind", `String "log_pattern" ]) with
   | Error _ -> ()
   | Ok _ -> fail "unknown trigger kind must be rejected")
;;

let test_observation_codec_roundtrip () =
  List.iter
    (fun observation ->
       let decoded =
         M.observation_to_yojson observation |> M.observation_of_yojson |> expect_ok
       in
       check bool "observation roundtrips" true (decoded = observation))
    [ M.Reachable; M.Unreachable; snapshot_a; M.File_absent ]
;;

let test_record_codec () =
  let source = { (record ()) with last_observation = Some M.Reachable } in
  let decoded = M.to_yojson source |> M.of_yojson |> expect_ok in
  check bool "identity fields roundtrip" true
    (String.equal decoded.M.id source.M.id
     && String.equal decoded.M.keeper source.M.keeper
     && decoded.M.trigger = source.M.trigger
     && decoded.M.payload = source.M.payload
     && Float.equal decoded.M.expires_at source.M.expires_at);
  check bool "baseline is dropped by persistence" true
    (decoded.M.last_observation = None);
  (match
     M.of_yojson
       (`Assoc [ "id", `String "mon-x"; "unknown_field", `String "boom" ])
   with
   | Error _ -> ()
   | Ok _ -> fail "unknown record field must be rejected")
;;

let () =
  run
    "monitor domain"
    [ ( "decide"
      , [ test_case "baseline never fires" `Quick test_baseline_never_fires
        ; test_case "reachability edges" `Quick test_reachability_edges
        ; test_case "file edges" `Quick test_file_edges
        ; test_case "incoherent pairs hold" `Quick test_incoherent_pairs_hold
        ] )
    ; ( "lifecycle"
      , [ test_case "expiry and exhaustion" `Quick test_lifecycle_predicates
        ; test_case "creation validation" `Quick test_validate_create
        ] )
    ; ( "codec"
      , [ test_case "trigger roundtrip" `Quick test_trigger_codec_roundtrip
        ; test_case "observation roundtrip" `Quick test_observation_codec_roundtrip
        ; test_case "record closed decode" `Quick test_record_codec
        ] )
    ]
