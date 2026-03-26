open Alcotest

module R = Masc_mcp.Keeper_registry
module Keeper_types = Masc_mcp.Keeper_types

let bp = "/tmp/test"

let make_meta name =
  let json = `Assoc [
    ("name", `String name);
    ("agent_name", `String ("agent-" ^ name));
    ("trace_id", `String ("trace-test-" ^ name));
    ("goal", `String "test goal");
  ] in
  match Keeper_types.meta_of_json json with
  | Ok meta -> meta
  | Error err -> Alcotest.fail ("make_meta failed: " ^ err)

(** Wrap each test body in Eio_main.run for Eio.Mutex support. *)
let eio_test name fn =
  test_case name `Quick (fun () -> Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env); fn ())

(* ── Basic registry operations ─────────────────────────── *)

let test_register_and_get () =
  R.clear ();
  let meta = make_meta "k1" in
  let entry = R.register ~base_path:bp "k1" meta in
  check string "name" "k1" entry.name;
  check string "state" "running" (R.state_to_string entry.state);
  match R.get ~base_path:bp "k1" with
  | None -> fail "expected entry for k1"
  | Some e -> check string "get name" "k1" e.name

let test_unregister () =
  R.clear ();
  let _entry = R.register ~base_path:bp "k2" (make_meta "k2") in
  check bool "exists before" true (Option.is_some (R.get ~base_path:bp "k2"));
  R.unregister ~base_path:bp "k2";
  check bool "gone after" true (Option.is_none (R.get ~base_path:bp "k2"))

let test_all () =
  R.clear ();
  let _e1 = R.register ~base_path:bp "a" (make_meta "a") in
  let _e2 = R.register ~base_path:bp "b" (make_meta "b") in
  let _e3 = R.register ~base_path:bp "c" (make_meta "c") in
  let all = R.all () in
  check int "count" 3 (List.length all)

let test_update_meta () =
  R.clear ();
  let _entry = R.register ~base_path:bp "k3" (make_meta "k3") in
  let updated_meta = { (make_meta "k3") with goal = "updated goal" } in
  R.update_meta ~base_path:bp "k3" updated_meta;
  match R.get ~base_path:bp "k3" with
  | None -> fail "expected k3"
  | Some e -> check string "goal updated" "updated goal" e.meta.goal

let test_set_state () =
  R.clear ();
  let _entry = R.register ~base_path:bp "k4" (make_meta "k4") in
  check bool "running" true (R.is_running ~base_path:bp "k4");
  R.set_state ~base_path:bp "k4" R.Paused;
  check bool "not running after pause" false (R.is_running ~base_path:bp "k4");
  match R.get ~base_path:bp "k4" with
  | None -> fail "expected k4"
  | Some e -> check string "state" "paused" (R.state_to_string e.state)

let test_count_running () =
  R.clear ();
  let _e1 = R.register ~base_path:bp "r1" (make_meta "r1") in
  let _e2 = R.register ~base_path:bp "r2" (make_meta "r2") in
  let _e3 = R.register ~base_path:bp "r3" (make_meta "r3") in
  check int "3 running" 3 (R.count_running ());
  R.set_state ~base_path:bp "r2" R.Paused;
  check int "2 running" 2 (R.count_running ());
  R.unregister ~base_path:bp "r1";
  check int "1 running" 1 (R.count_running ())

let test_count_running_atomic_transitions () =
  let bp2 = "/tmp/test-2" in
  R.clear ();
  ignore (R.register ~base_path:bp "fast1" (make_meta "fast1"));
  ignore (R.register ~base_path:bp2 "fast2" (make_meta "fast2"));
  check int "global fast-path count" 2 (R.count_running ());
  check int "scoped count stays exact" 1 (R.count_running ~base_path:bp ());
  R.set_state ~base_path:bp2 "fast2" R.Paused;
  check int "pause decrements global fast-path" 1 (R.count_running ());
  ignore (R.register ~base_path:bp "fast1" (make_meta "fast1"));
  check int "replacing running entry keeps count stable" 1 (R.count_running ());
  R.unregister ~base_path:bp "fast1";
  check int "unregister decrements global fast-path" 0 (R.count_running ());
  R.clear ();
  check int "clear resets global fast-path" 0 (R.count_running ())

let test_record_restart () =
  R.clear ();
  let _entry = R.register ~base_path:bp "k5" (make_meta "k5") in
  R.record_restart ~base_path:bp "k5";
  R.record_restart ~base_path:bp "k5";
  match R.get ~base_path:bp "k5" with
  | None -> fail "expected k5"
  | Some e ->
      check int "restart count" 2 e.restart_count;
      check bool "last_restart_ts set" true (e.last_restart_ts > 0.0)

let test_record_error () =
  R.clear ();
  let _entry = R.register ~base_path:bp "k6" (make_meta "k6") in
  check bool "no error initially" true
    (Option.is_none (Option.bind (R.get ~base_path:bp "k6") (fun e -> e.last_error)));
  R.record_error ~base_path:bp "k6" "something broke";
  match R.get ~base_path:bp "k6" with
  | None -> fail "expected k6"
  | Some e ->
    check (option string) "error recorded" (Some "something broke") e.last_error

let test_get_exn_not_found () =
  R.clear ();
  match R.get_exn ~base_path:bp "nonexistent" with
  | _ -> fail "expected Not_found"
  | exception Not_found -> ()

let test_noop_on_missing () =
  R.clear ();
  R.update_meta ~base_path:bp "ghost" (make_meta "ghost");
  R.set_state ~base_path:bp "ghost" R.Paused;
  R.record_restart ~base_path:bp "ghost";
  R.record_error ~base_path:bp "ghost" "err";
  R.record_crash ~base_path:bp "ghost" 0.0 "crash";
  R.set_grpc_close ~base_path:bp "ghost" None;
  R.wakeup ~base_path:bp "ghost";
  R.unregister ~base_path:bp "ghost";
  check bool "no crash on missing" true true

let test_register_replaces () =
  R.clear ();
  let _e1 = R.register ~base_path:bp "dup" (make_meta "dup") in
  R.record_restart ~base_path:bp "dup";
  let _e2 = R.register ~base_path:bp "dup" (make_meta "dup") in
  match R.get ~base_path:bp "dup" with
  | None -> fail "expected dup"
  | Some e ->
    check int "restart count reset" 0 e.restart_count

(* ── New fields: grpc_close, crash_log, wakeup, fiber_health ── *)

let test_grpc_close () =
  R.clear ();
  let _entry = R.register ~base_path:bp "g1" (make_meta "g1") in
  let called = ref false in
  R.set_grpc_close ~base_path:bp "g1" (Some (fun () -> called := true));
  (match R.get ~base_path:bp "g1" with
   | Some e ->
       (match !(e.grpc_close) with
        | Some f -> f (); check bool "grpc_close called" true !called
        | None -> fail "expected grpc_close")
   | None -> fail "expected g1");
  R.set_grpc_close ~base_path:bp "g1" None;
  match R.get ~base_path:bp "g1" with
  | Some e -> check bool "grpc_close cleared" true (Option.is_none !(e.grpc_close))
  | None -> fail "expected g1"

let test_crash_log () =
  R.clear ();
  let _entry = R.register ~base_path:bp "c1" (make_meta "c1") in
  R.record_crash ~base_path:bp "c1" 1.0 "crash-1";
  R.record_crash ~base_path:bp "c1" 2.0 "crash-2";
  R.record_crash ~base_path:bp "c1" 3.0 "crash-3";
  let log = R.crash_log_of ~base_path:bp "c1" in
  check int "3 entries" 3 (List.length log);
  check string "latest first" "crash-3" (snd (List.hd log));
  R.record_crash ~base_path:bp "c1" 4.0 "crash-4";
  R.record_crash ~base_path:bp "c1" 5.0 "crash-5";
  R.record_crash ~base_path:bp "c1" 6.0 "crash-6";
  let log2 = R.crash_log_of ~base_path:bp "c1" in
  check int "capped at 5" 5 (List.length log2)

let test_started_at () =
  R.clear ();
  check bool "none for missing" true (Option.is_none (R.started_at ~base_path:bp "nope"));
  let _entry = R.register ~base_path:bp "s1" (make_meta "s1") in
  check bool "some for existing" true (Option.is_some (R.started_at ~base_path:bp "s1"))

let test_wakeup () =
  R.clear ();
  let entry = R.register ~base_path:bp "w1" (make_meta "w1") in
  check bool "wakeup initially false" false !(entry.fiber_wakeup);
  R.wakeup ~base_path:bp "w1";
  check bool "wakeup set" true !(entry.fiber_wakeup)

let test_wakeup_all () =
  R.clear ();
  let e1 = R.register ~base_path:bp "wa1" (make_meta "wa1") in
  let e2 = R.register ~base_path:bp "wa2" (make_meta "wa2") in
  let e3 = R.register ~base_path:bp "wa3" (make_meta "wa3") in
  let e4 = R.register ~base_path:bp "wa4" (make_meta "wa4") in
  R.set_state ~base_path:bp "wa3" R.Stopped;
  R.set_state ~base_path:bp "wa4" R.Paused;
  R.wakeup_all ();
  check bool "wa1 woken" true !(e1.fiber_wakeup);
  check bool "wa2 woken" true !(e2.fiber_wakeup);
  check bool "wa3 not woken (stopped)" false !(e3.fiber_wakeup);
  check bool "wa4 not woken (paused)" false !(e4.fiber_wakeup)

let test_fiber_health_alive () =
  R.clear ();
  let _entry = R.register ~base_path:bp "fh1" (make_meta "fh1") in
  match R.fiber_health_of ~base_path:bp "fh1" with
  | Keeper_types.Fiber_alive -> ()
  | _ -> fail "expected Fiber_alive"

let test_fiber_health_unknown () =
  R.clear ();
  match R.fiber_health_of ~base_path:bp "nonexistent" with
  | Keeper_types.Fiber_unknown -> ()
  | _ -> fail "expected Fiber_unknown"

let test_fiber_health_stopped () =
  R.clear ();
  let entry = R.register ~base_path:bp "fh2" (make_meta "fh2") in
  Eio.Promise.resolve entry.done_r `Stopped;
  match R.fiber_health_of ~base_path:bp "fh2" with
  | Keeper_types.Fiber_unknown -> ()
  | _ -> fail "expected Fiber_unknown for stopped"

let test_fiber_health_crashed () =
  R.clear ();
  let entry = R.register ~base_path:bp "fh3" (make_meta "fh3") in
  Eio.Promise.resolve entry.done_r (`Crashed "test crash");
  match R.fiber_health_of ~base_path:bp "fh3" with
  | Keeper_types.Fiber_zombie -> ()
  | _ -> fail "expected Fiber_zombie for crashed"

let test_shared_refs () =
  R.clear ();
  let entry = R.register ~base_path:bp "ref1" (make_meta "ref1") in
  let entry_via_get = R.get_exn ~base_path:bp "ref1" in
  entry.fiber_wakeup := true;
  check bool "shared wakeup ref" true !(entry_via_get.fiber_wakeup);
  entry_via_get.fiber_stop := true;
  check bool "shared stop ref" true !(entry.fiber_stop)

let test_spawn_slots () =
  R.clear ();
  check bool "slots available" true (R.spawn_slots_available ())

(* ── Board tracking tests ─────────────────────────────── *)

let test_last_agent_count_default () =
  R.clear ();
  check int "0 for unknown" 0 (R.get_last_agent_count ~base_path:bp "none")

let test_last_agent_count_set_get () =
  R.clear ();
  ignore (R.register ~base_path:bp "ac1" (make_meta "ac1"));
  R.set_last_agent_count ~base_path:bp "ac1" 42;
  check int "set then get" 42 (R.get_last_agent_count ~base_path:bp "ac1")

let test_board_wakeup_debounce () =
  R.clear ();
  ignore (R.register ~base_path:bp "bw1" (make_meta "bw1"));
  let first = R.board_wakeup_allowed ~base_path:bp "bw1" ~post_id:"p1" ~debounce_sec:60.0 in
  let second = R.board_wakeup_allowed ~base_path:bp "bw1" ~post_id:"p1" ~debounce_sec:60.0 in
  check bool "first allowed" true first;
  check bool "second blocked" false second

let test_board_wakeup_different_post () =
  R.clear ();
  ignore (R.register ~base_path:bp "bw2" (make_meta "bw2"));
  let first = R.board_wakeup_allowed ~base_path:bp "bw2" ~post_id:"p1" ~debounce_sec:60.0 in
  let second = R.board_wakeup_allowed ~base_path:bp "bw2" ~post_id:"p2" ~debounce_sec:60.0 in
  check bool "p1 allowed" true first;
  check bool "p2 allowed" true second

let test_cleanup_tracking () =
  R.clear ();
  ignore (R.register ~base_path:bp "ct1" (make_meta "ct1"));
  R.set_last_agent_count ~base_path:bp "ct1" 10;
  ignore (R.board_wakeup_allowed ~base_path:bp "ct1" ~post_id:"x" ~debounce_sec:60.0);
  R.cleanup_tracking ~base_path:bp "ct1";
  check int "agent count reset" 0 (R.get_last_agent_count ~base_path:bp "ct1");
  let allowed = R.board_wakeup_allowed ~base_path:bp "ct1" ~post_id:"x" ~debounce_sec:60.0 in
  check bool "wakeup allowed after cleanup" true allowed

let () =
  run "Keeper_registry"
    [
      ( "basic",
        [
          eio_test "register and get" test_register_and_get;
          eio_test "unregister" test_unregister;
          eio_test "all" test_all;
          eio_test "update meta" test_update_meta;
          eio_test "set state" test_set_state;
          eio_test "count running" test_count_running;
          eio_test "count running atomic transitions" test_count_running_atomic_transitions;
          eio_test "record restart" test_record_restart;
          eio_test "record error" test_record_error;
          eio_test "get_exn not found" test_get_exn_not_found;
          eio_test "noop on missing keys" test_noop_on_missing;
          eio_test "register replaces existing" test_register_replaces;
        ] );
      ( "extended",
        [
          eio_test "grpc_close" test_grpc_close;
          eio_test "crash log" test_crash_log;
          eio_test "started_at" test_started_at;
          eio_test "wakeup" test_wakeup;
          eio_test "wakeup_all" test_wakeup_all;
          eio_test "fiber_health alive" test_fiber_health_alive;
          eio_test "fiber_health unknown" test_fiber_health_unknown;
          eio_test "fiber_health stopped" test_fiber_health_stopped;
          eio_test "fiber_health crashed" test_fiber_health_crashed;
          eio_test "shared refs" test_shared_refs;
          eio_test "spawn slots" test_spawn_slots;
        ] );
      ( "board_tracking",
        [
          eio_test "last_agent_count default 0" test_last_agent_count_default;
          eio_test "last_agent_count set/get" test_last_agent_count_set_get;
          eio_test "board wakeup debounce" test_board_wakeup_debounce;
          eio_test "board wakeup different post" test_board_wakeup_different_post;
          eio_test "cleanup_tracking resets" test_cleanup_tracking;
        ] );
    ]
