(** Cooperative-scheduling regression test for [Keeper_telemetry_consumer].

    The drain fiber forked by [spawn_subscriber] consumes a non-blocking
    primitive ([Agent_sdk_metrics_bridge.drain]). Without an explicit
    yield it pins its Eio domain at ~100% CPU and starves every
    co-located fiber on the same domain — including timer fibers, so a
    [Eio.Time.sleep] in a sibling fiber never fires.

    This test runs [spawn_subscriber] under a switch and then asks the
    main fiber to perform a short sleep loop. If the drain fiber yields
    (the contract from RFC-0063 §6, encoded by PR #14499 as
    [Eio.Time.sleep clock drain_interval_s]), the main fiber's sleeps
    fire and the counter reaches its target. If a future change drops
    the yield, the main fiber's first sleep never wakes up and the test
    hangs — the CI wall-clock cutoff catches it.

    Regression context: PR #14491 introduced [spawn_subscriber] without
    a yield; PR #14499 restored cooperative behaviour; RFC-0063 §7-D
    classifies this style of harness as "partial coverage, low cost". *)

module KTC = Masc.Keeper_telemetry_consumer

let target_iters = 5
let inter_sleep_s = 0.02
let total_expected_wall_clock_s = float_of_int target_iters *. inter_sleep_s
let temp_counter = ref 0

let temp_base_path prefix =
  incr temp_counter;
  let dir =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "%s_%d_%d_%.0f" prefix !temp_counter (Unix.getpid ())
         (Unix.gettimeofday ()))
  in
  Fs_compat.mkdir_p dir;
  dir

(* Marker used to break out of [Switch.run] once the assertion data is
   collected. Using [Switch.fail] would propagate as the switch's
   failure exception; raising [Exit] is the simpler shape because
   [Switch.run] re-raises and the outer [try] cleans up. *)
exception Test_done

let test_drain_loop_yields_to_co_located_fiber () =
  let counter = ref 0 in
  Eio_main.run @@ fun env ->
    let clock = Eio.Stdenv.clock env in
    let bus = Agent_sdk.Event_bus.create () in
    let base_path = temp_base_path "keeper_telemetry_consumer" in
    (try
      Eio.Switch.run (fun sw ->
        KTC.spawn_subscriber ~sw ~clock ~base_path ~bus;
        for _ = 1 to target_iters do
          Eio.Time.sleep clock inter_sleep_s;
          incr counter
        done;
        raise Test_done)
    with Test_done -> ());
  Alcotest.(check int)
    (Printf.sprintf
       "co-located fiber completed %d sleeps (~%.2fs wall-clock); \
        drain fiber must have yielded"
       target_iters total_expected_wall_clock_s)
    target_iters !counter

(* Walk [dir] recursively and return every regular file ending in
   ".jsonl". Stdlib-only so the test does not need a [dated_jsonl] dune
   dependency just to read the store back. *)
let rec find_jsonl dir =
  if not (Sys.file_exists dir) then []
  else if Sys.is_directory dir then
    Sys.readdir dir |> Array.to_list
    |> List.concat_map (fun name -> find_jsonl (Filename.concat dir name))
  else if Filename.check_suffix dir ".jsonl" then [ dir ]
  else []

let contains_substring haystack needle =
  let hl = String.length haystack and nl = String.length needle in
  let rec loop i =
    if i + nl > hl then false
    else if String.sub haystack i nl = needle then true
    else loop (i + 1)
  in
  nl = 0 || loop 0

(* Regression for the silent telemetry drop: the consumer must persist
   each [Custom ("telemetry_event", json)] payload to
   [{base_path}/data/harness-telemetry/YYYY-MM/DD.jsonl], not merely
   increment a counter. A counter-only consumer (the state #20853 fixed
   and 6f5bfdeb2 reverted) drops the payload — this test fails on it. *)
let test_persists_telemetry_event_to_jsonl () =
  let base_path = temp_base_path "keeper_telemetry_persist" in
  let marker = "persist_probe_3f9c1" in
  let payload =
    `Assoc [ ("kind", `String "turn_observation"); ("marker", `String marker) ]
  in
  Eio_main.run @@ fun env ->
    let clock = Eio.Stdenv.clock env in
    let bus = Agent_sdk.Event_bus.create () in
    (try
      Eio.Switch.run (fun sw ->
        KTC.spawn_subscriber ~sw ~clock ~base_path ~bus;
        Agent_sdk.Event_bus.publish bus
          (Agent_sdk.Event_bus.mk_event
             (Agent_sdk.Event_bus.Custom ("telemetry_event", payload)));
        (* Let several drain intervals (0.1s each) flush to disk. *)
        Eio.Time.sleep clock 0.35;
        raise Test_done)
    with Test_done -> ());
  let store_dir = Filename.concat base_path "data/harness-telemetry" in
  let files = find_jsonl store_dir in
  let persisted =
    List.exists
      (fun path -> contains_substring (Fs_compat.load_file path) marker)
      files
  in
  Alcotest.(check bool)
    "telemetry_event payload persisted to harness-telemetry JSONL"
    true persisted

let () =
  Alcotest.run "keeper_telemetry_consumer"
    [
      ( "cooperative_scheduling",
        [
          Alcotest.test_case
            "drain loop yields to co-located fiber"
            `Quick
            test_drain_loop_yields_to_co_located_fiber;
        ] );
      ( "persistence",
        [
          Alcotest.test_case
            "telemetry_event persisted to dated JSONL"
            `Quick
            test_persists_telemetry_event_to_jsonl;
        ] );
    ]
