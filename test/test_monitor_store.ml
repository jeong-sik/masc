(* RFC-0379 monitor store: locked-file CRUD, per-keeper cap, owner-checked
   cancel, fire accounting, and expiry sweep against a temp base path. *)

open Alcotest
module D = Monitor_domain
module S = Masc.Keeper_monitor_store

let fresh_base_path =
  let counter = ref 0 in
  fun () ->
    incr counter;
    let dir =
      Filename.concat
        (Filename.get_temp_dir_name ())
        (Printf.sprintf "masc-monitor-store-test-%d-%d" (Unix.getpid ()) !counter)
    in
    Unix.mkdir dir 0o700;
    dir
;;

let record ?(id = "mon-1") ?(keeper = "rondo") ?(max_fires = 1) () : D.t =
  { id
  ; keeper
  ; trigger = D.Port_up { host = "127.0.0.1"; port = 18935 }
  ; payload = `String "verify the reboot"
  ; expires_at = 2_000.0
  ; max_fires
  ; fired_count = 0
  ; created_at = 1_000.0
  ; last_observation = None
  }
;;

let expect_ok label = function
  | Ok value -> value
  | Error message -> fail (Printf.sprintf "%s: %s" label message)
;;

let test_create_load_roundtrip () =
  let base_path = fresh_base_path () in
  check (list string) "empty store loads as no records" []
    (List.map
       (fun (r : D.t) -> r.id)
       (expect_ok "load empty" (S.load ~base_path)));
  expect_ok "create" (S.create ~base_path (record ()));
  (match S.load ~base_path with
   | Ok [ loaded ] ->
     check string "id survives" "mon-1" loaded.D.id;
     check bool "baseline never persists" true (loaded.D.last_observation = None)
   | Ok records -> fail (Printf.sprintf "expected 1 record, got %d" (List.length records))
   | Error message -> fail message);
  (match S.create ~base_path (record ()) with
   | Error _ -> ()
   | Ok () -> fail "duplicate id must be rejected")
;;

let test_per_keeper_cap () =
  let base_path = fresh_base_path () in
  for index = 1 to D.max_active_monitors_per_keeper do
    expect_ok "create under cap"
      (S.create ~base_path (record ~id:(Printf.sprintf "mon-%d" index) ()))
  done;
  (match S.create ~base_path (record ~id:"mon-over" ()) with
   | Error _ -> ()
   | Ok () -> fail "cap must reject the next create");
  expect_ok "another keeper is unaffected"
    (S.create ~base_path (record ~id:"mon-other" ~keeper:"kidsnote" ()))
;;

let test_cancel_ownership () =
  let base_path = fresh_base_path () in
  expect_ok "create" (S.create ~base_path (record ()));
  (match S.cancel ~base_path ~keeper:"kidsnote" ~id:"mon-1" with
   | Error _ -> ()
   | Ok _ -> fail "foreign cancel must be an error, not a removal");
  check bool "own cancel removes" true
    (expect_ok "cancel" (S.cancel ~base_path ~keeper:"rondo" ~id:"mon-1"));
  check bool "missing id reports false" false
    (expect_ok "cancel missing" (S.cancel ~base_path ~keeper:"rondo" ~id:"mon-1"))
;;

let test_fire_accounting () =
  let base_path = fresh_base_path () in
  expect_ok "create one-shot" (S.create ~base_path (record ()));
  (match S.record_fire ~base_path ~id:"mon-1" with
   | Ok S.Fire_recorded_removed -> ()
   | Ok S.Fire_recorded_retained -> fail "one-shot fire must remove the record"
   | Error message -> fail message);
  check (list string) "exhausted record is gone" []
    (List.map (fun (r : D.t) -> r.D.id) (expect_ok "load" (S.load ~base_path)));
  expect_ok "create multi" (S.create ~base_path (record ~id:"mon-3" ~max_fires:2 ()));
  (match S.record_fire ~base_path ~id:"mon-3" with
   | Ok S.Fire_recorded_retained -> ()
   | Ok S.Fire_recorded_removed -> fail "first of two fires must retain"
   | Error message -> fail message);
  (match S.record_fire ~base_path ~id:"mon-3" with
   | Ok S.Fire_recorded_removed -> ()
   | Ok S.Fire_recorded_retained -> fail "second fire must exhaust"
   | Error message -> fail message);
  (match S.record_fire ~base_path ~id:"mon-3" with
   | Error _ -> ()
   | Ok _ -> fail "firing a removed record must be an error")
;;

let test_expiry_sweep () =
  let base_path = fresh_base_path () in
  expect_ok "create" (S.create ~base_path (record ()));
  check (list string) "not yet expired" []
    (expect_ok "sweep early" (S.remove_expired ~base_path ~now:1_500.0));
  check (list string) "expired ids are returned" [ "mon-1" ]
    (expect_ok "sweep late" (S.remove_expired ~base_path ~now:2_000.0));
  check (list string) "store is empty after sweep" []
    (List.map (fun (r : D.t) -> r.D.id) (expect_ok "load" (S.load ~base_path)))
;;

let () =
  run
    "keeper monitor store"
    [ ( "store"
      , [ test_case "create and load roundtrip" `Quick test_create_load_roundtrip
        ; test_case "per-keeper cap" `Quick test_per_keeper_cap
        ; test_case "cancel ownership" `Quick test_cancel_ownership
        ; test_case "fire accounting" `Quick test_fire_accounting
        ; test_case "expiry sweep" `Quick test_expiry_sweep
        ] )
    ]
