(** Otel_runtime_observables — computed-sample source regression tests.

    The source must always yield the console-sink and transition-audit
    samples (present from process start: no absence-vs-zero ambiguity),
    omit bus/pool families when those subsystems are not running (unit
    test process), and report watched-store sizes from a real directory
    walk with the 60s cache honored. *)

open Alcotest
module Obs = Masc.Otel_runtime_observables

let sample_names samples = List.map (fun (s : Otel_metrics.sample) -> s.name) samples

let find name samples =
  List.find_opt (fun (s : Otel_metrics.sample) -> String.equal s.name name) samples

let with_temp_masc_root f =
  let root =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "otel-obs-test-%d" (Unix.getpid ()))
  in
  let store = Filename.concat root "tool_calls" in
  Unix.mkdir root 0o755;
  Unix.mkdir store 0o755;
  let oc = open_out (Filename.concat store "2026-06-10.jsonl") in
  output_string oc "{\"a\":1}\n{\"b\":2}\n";
  close_out oc;
  Fun.protect
    ~finally:(fun () ->
      Sys.remove (Filename.concat store "2026-06-10.jsonl");
      Unix.rmdir store;
      Unix.rmdir root)
    (fun () -> f root)

let test_core_samples_always_present () =
  with_temp_masc_root (fun root ->
    Obs.For_testing.reset_store_cache ();
    let samples = Obs.For_testing.samples ~masc_root:root () in
    List.iter
      (fun name ->
        check bool (Printf.sprintf "sample %s present" name) true
          (Option.is_some (find name samples)))
      [ "masc_console_sink_dropped_total"
      ; "masc_console_sink_queue_depth"
      ; "masc_keeper_transition_audit_queue_depth"
      ];
    match find "masc_console_sink_dropped_total" samples with
    | None -> fail "unreachable"
    | Some s -> check bool "dropped is a counter" true (s.kind = Otel_metrics.Counter))

let test_bus_and_pool_absent_without_subsystems () =
  with_temp_masc_root (fun root ->
    Obs.For_testing.reset_store_cache ();
    let names = sample_names (Obs.For_testing.samples ~masc_root:root ()) in
    List.iter
      (fun prefix ->
        check bool
          (Printf.sprintf "no %s* without the subsystem" prefix)
          false
          (List.exists (fun n -> String.starts_with ~prefix n) names))
      [ "masc_event_bus_"; "masc_pool_" ])

let test_store_bytes_from_walk () =
  with_temp_masc_root (fun root ->
    Obs.For_testing.reset_store_cache ();
    let samples = Obs.For_testing.samples ~masc_root:root () in
    let bytes =
      List.find_opt
        (fun (s : Otel_metrics.sample) ->
          String.equal s.name "masc_store_bytes"
          && s.labels = [ "store", "tool_calls" ])
        samples
    in
    match bytes with
    | None -> fail "masc_store_bytes{store=tool_calls} missing"
    | Some s ->
      check bool "bytes counted" true (s.value > 0.0);
      (* second call inside the 60s window serves the cache *)
      let again = Obs.For_testing.samples ~masc_root:root () in
      (match
         List.find_opt
           (fun (x : Otel_metrics.sample) ->
             String.equal x.name "masc_store_bytes"
             && x.labels = [ "store", "tool_calls" ])
           again
       with
       | None -> fail "cached store sample missing"
       | Some s2 -> check (float 0.0) "cached value identical" s.value s2.value))

(* The walk runs on the domain pool when one is installed. Inline (no
   pool, no Eio) and pooled (one-domain pool inside Eio) must report the
   same store sizes. *)
let store_sizes samples =
  List.filter_map
    (fun (s : Otel_metrics.sample) ->
      if String.equal s.name "masc_store_bytes" || String.equal s.name "masc_store_files"
      then Some (s.name, s.labels, s.value)
      else None)
    samples
;;

let test_store_walk_matches_on_the_pool () =
  with_temp_masc_root (fun root ->
    Obs.For_testing.reset_store_cache ();
    let inline = store_sizes (Obs.For_testing.samples ~masc_root:root ()) in
    check bool "inline walk reports the store" true (inline <> []);
    let pooled =
      Eio_main.run (fun env ->
        Eio.Switch.run (fun sw ->
          let pool =
            Domain_pool.create ~sw ~domain_count:1 (Eio.Stdenv.domain_mgr env)
          in
          Domain_pool_ref.set pool;
          Fun.protect
            ~finally:Domain_pool_ref.clear_for_tests
            (fun () ->
              Obs.For_testing.reset_store_cache ();
              store_sizes (Obs.For_testing.samples ~masc_root:root ()))))
    in
    check
      (list (triple string (list (pair string string)) (float 0.0)))
      "pooled walk reports the same sizes"
      inline
      pooled)
;;

let test_fd_samples_present () =
  with_temp_masc_root (fun root ->
    Obs.For_testing.reset_store_cache ();
    let samples = Obs.For_testing.samples ~masc_root:root () in
    check bool "active-operation gauge present" true
      (Option.is_some (find "masc_fd_active_operations" samples));
    check bool "typed resource-error counter present" true
      (Option.is_some (find "masc_fd_resource_errors_total" samples));
    check bool "legacy pressure gauge absent" true
      (Option.is_none (find "masc_fd_pressure_active" samples)))

(* masc#29023: the store writer lands every computed sample in an
   Otel_metric_store cell, so fleet HTTP and the dashboard read them
   with no collector installed. *)
let test_store_writer_lands_samples_in_cells () =
  with_temp_masc_root (fun root ->
    Obs.For_testing.reset_store_cache ();
    let written = Obs.For_testing.write_samples_to_store ~masc_root:root () in
    check bool "writer reports the sample count" true (written > 0);
    let samples = Obs.For_testing.samples ~masc_root:root () in
    let queue =
      List.find
        (fun (s : Otel_metrics.sample) ->
          String.equal s.name "masc_console_sink_queue_depth")
        samples
    in
    check (float 0.0)
      "console queue depth readable from the store with no collector"
      queue.value
      (Masc.Otel_metric_store.metric_value_or_zero
         "masc_console_sink_queue_depth"
         ());
    match
      List.find_opt
        (fun (s : Otel_metrics.sample) ->
          String.equal s.name "masc_store_bytes"
          && s.labels = [ "store", "tool_calls" ])
        samples
    with
    | None -> fail "masc_store_bytes sample missing"
    | Some bytes ->
      check (float 0.0)
        "store bytes readable from the labeled cell"
        bytes.value
        (Masc.Otel_metric_store.metric_value_or_zero
           "masc_store_bytes"
           ~labels:[ "store", "tool_calls" ]
           ()))

let () =
  run "otel_runtime_observables"
    [ ( "samples"
      , [ test_case "core samples always present" `Quick test_core_samples_always_present
        ; test_case "bus/pool absent without subsystems" `Quick
            test_bus_and_pool_absent_without_subsystems
        ; test_case "store bytes from walk + cache" `Quick test_store_bytes_from_walk
        ; test_case "fd samples present" `Quick test_fd_samples_present
        ; test_case "store walk matches on the pool" `Quick test_store_walk_matches_on_the_pool
        ; test_case "store writer lands samples in cells (masc#29023)" `Quick
            test_store_writer_lands_samples_in_cells
        ] )
    ]
