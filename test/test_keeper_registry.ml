open Alcotest

module R = Masc_mcp.Keeper_registry
module Keeper_types = Masc_mcp.Keeper_types

let make_meta name =
  let json = `Assoc [
    ("name", `String name);
    ("agent_name", `String ("agent-" ^ name));
    ("trace_id", `String ("trace-test-" ^ name));
    ("goal", `String "test goal");
    ("models", `List [ `String "custom:test" ]);
  ] in
  match Keeper_types.meta_of_json json with
  | Ok meta -> meta
  | Error err -> Alcotest.fail ("make_meta failed: " ^ err)

let test_register_and_get () =
  R.clear ();
  let meta = make_meta "k1" in
  let entry = R.register "k1" meta in
  check string "name" "k1" entry.name;
  check string "state" "running" (R.state_to_string entry.state);
  match R.get "k1" with
  | None -> fail "expected entry for k1"
  | Some e -> check string "get name" "k1" e.name

let test_unregister () =
  R.clear ();
  let _entry = R.register "k2" (make_meta "k2") in
  check bool "exists before" true (Option.is_some (R.get "k2"));
  R.unregister "k2";
  check bool "gone after" true (Option.is_none (R.get "k2"))

let test_all () =
  R.clear ();
  let _e1 = R.register "a" (make_meta "a") in
  let _e2 = R.register "b" (make_meta "b") in
  let _e3 = R.register "c" (make_meta "c") in
  let all = R.all () in
  check int "count" 3 (List.length all)

let test_update_meta () =
  R.clear ();
  let _entry = R.register "k3" (make_meta "k3") in
  let updated_meta = { (make_meta "k3") with goal = "updated goal" } in
  R.update_meta "k3" updated_meta;
  match R.get "k3" with
  | None -> fail "expected k3"
  | Some e -> check string "goal updated" "updated goal" e.meta.goal

let test_set_state () =
  R.clear ();
  let _entry = R.register "k4" (make_meta "k4") in
  check bool "running" true (R.is_running "k4");
  R.set_state "k4" R.Paused;
  check bool "not running after pause" false (R.is_running "k4");
  match R.get "k4" with
  | None -> fail "expected k4"
  | Some e -> check string "state" "paused" (R.state_to_string e.state)

let test_count_running () =
  R.clear ();
  let _e1 = R.register "r1" (make_meta "r1") in
  let _e2 = R.register "r2" (make_meta "r2") in
  let _e3 = R.register "r3" (make_meta "r3") in
  check int "3 running" 3 (R.count_running ());
  R.set_state "r2" R.Paused;
  check int "2 running" 2 (R.count_running ());
  R.unregister "r1";
  check int "1 running" 1 (R.count_running ())

let test_record_restart () =
  R.clear ();
  let _entry = R.register "k5" (make_meta "k5") in
  R.record_restart "k5";
  R.record_restart "k5";
  match R.get "k5" with
  | None -> fail "expected k5"
  | Some e -> check int "restart count" 2 e.restart_count

let test_record_error () =
  R.clear ();
  let _entry = R.register "k6" (make_meta "k6") in
  check bool "no error initially" true
    (Option.is_none (Option.bind (R.get "k6") (fun e -> e.last_error)));
  R.record_error "k6" "something broke";
  match R.get "k6" with
  | None -> fail "expected k6"
  | Some e ->
    check (option string) "error recorded" (Some "something broke") e.last_error

let test_get_exn_not_found () =
  R.clear ();
  match R.get_exn "nonexistent" with
  | _ -> fail "expected Not_found"
  | exception Not_found -> ()

let test_noop_on_missing () =
  R.clear ();
  R.update_meta "ghost" (make_meta "ghost");
  R.set_state "ghost" R.Paused;
  R.record_restart "ghost";
  R.record_error "ghost" "err";
  R.unregister "ghost";
  check bool "no crash on missing" true true

let test_register_replaces () =
  R.clear ();
  let _e1 = R.register "dup" (make_meta "dup") in
  R.record_restart "dup";
  let _e2 = R.register "dup" (make_meta "dup") in
  match R.get "dup" with
  | None -> fail "expected dup"
  | Some e ->
    check int "restart count reset" 0 e.restart_count

let () =
  run "Keeper_registry"
    [
      ( "basic",
        [
          test_case "register and get" `Quick test_register_and_get;
          test_case "unregister" `Quick test_unregister;
          test_case "all" `Quick test_all;
          test_case "update meta" `Quick test_update_meta;
          test_case "set state" `Quick test_set_state;
          test_case "count running" `Quick test_count_running;
          test_case "record restart" `Quick test_record_restart;
          test_case "record error" `Quick test_record_error;
          test_case "get_exn not found" `Quick test_get_exn_not_found;
          test_case "noop on missing keys" `Quick test_noop_on_missing;
          test_case "register replaces existing" `Quick test_register_replaces;
        ] );
    ]
