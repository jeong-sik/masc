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

let with_temp_masc_root ?(suffix = "default") ?(contents = "{\"a\":1}\n{\"b\":2}\n") f =
  let root =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "otel-obs-test-%s-%d" suffix (Unix.getpid ()))
  in
  let store = Filename.concat root "tool_calls" in
  let store_file = Filename.concat store "2026-06-10.jsonl" in
  Unix.mkdir root 0o755;
  Unix.mkdir store 0o755;
  let oc = open_out store_file in
  output_string oc contents;
  close_out oc;
  Fun.protect
    ~finally:(fun () ->
      Sys.remove store_file;
      Unix.rmdir store;
      Unix.rmdir root)
    (fun () -> f root)

let write_file path contents =
  let oc = open_out_bin path in
  Fun.protect
    ~finally:(fun () -> close_out oc)
    (fun () -> output_string oc contents)

let with_temp_trajectory_stores f =
  let root =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "otel-obs-trajectory-test-%d" (Unix.getpid ()))
  in
  let keepers_root = Filename.concat root Common.keepers_runtime_dirname in
  let trajectory_label =
    Common.keeper_runtime_store_dirname Common.Keeper_trajectories
  in
  let retired_root = Filename.concat root trajectory_label in
  let keeper_dirs keeper_name =
    let keeper_root = Filename.concat keepers_root keeper_name in
    let canonical = Trajectory.trajectories_dir root keeper_name in
    keeper_root, Filename.dirname canonical, canonical
  in
  let alice_root, alice_store, alice_v1 = keeper_dirs "alice" in
  let bob_root, bob_store, bob_v1 = keeper_dirs "bob" in
  let directories =
    [ root
    ; keepers_root
    ; alice_root
    ; alice_store
    ; alice_v1
    ; bob_root
    ; bob_store
    ; bob_v1
    ; retired_root
    ]
  in
  List.iter (fun path -> Unix.mkdir path 0o755) directories;
  let alice_contents = "canonical-alice\n" in
  let bob_contents = "canonical-bob\n" in
  let alice_file = Trajectory.trajectory_path root "alice" "trace-a" in
  let bob_file = Trajectory.trajectory_path root "bob" "trace-b" in
  let retired_file = Filename.concat retired_root "retired.jsonl" in
  let unrelated_keeper_sidecar = Filename.concat keepers_root "alice.memory.jsonl" in
  write_file alice_file alice_contents;
  write_file bob_file bob_contents;
  write_file retired_file (String.make 1_024 'x');
  write_file unrelated_keeper_sidecar "not-a-keeper-directory\n";
  Fun.protect
    ~finally:(fun () ->
      List.iter Sys.remove
        [ alice_file; bob_file; retired_file; unrelated_keeper_sidecar ];
      List.iter Unix.rmdir (List.rev directories))
    (fun () ->
      f root (String.length alice_contents + String.length bob_contents))

let with_temp_partial_trajectory_stores f =
  let root =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "otel-obs-partial-trajectory-test-%d" (Unix.getpid ()))
  in
  let keepers_root = Filename.concat root Common.keepers_runtime_dirname in
  let keeper_dirs keeper_name =
    let keeper_root = Filename.concat keepers_root keeper_name in
    let canonical = Trajectory.trajectories_dir root keeper_name in
    keeper_root, Filename.dirname canonical, canonical
  in
  let alice_root, alice_store, alice_v1 = keeper_dirs "alice" in
  let bob_root, bob_store, bob_v1 = keeper_dirs "bob" in
  let directories =
    [ root
    ; keepers_root
    ; alice_root
    ; alice_store
    ; alice_v1
    ; bob_root
    ; bob_store
    ]
  in
  List.iter (fun path -> Unix.mkdir path 0o755) directories;
  let alice_contents = "canonical-alice\n" in
  let alice_file = Trajectory.trajectory_path root "alice" "trace-a" in
  write_file alice_file alice_contents;
  write_file bob_v1 "not-a-directory\n";
  Fun.protect
    ~finally:(fun () ->
      List.iter Sys.remove [ alice_file; bob_v1 ];
      List.iter Unix.rmdir (List.rev directories))
    (fun () -> f root (String.length alice_contents))

let find_store_sample name store samples =
  List.find_opt
    (fun (sample : Otel_metrics.sample) ->
      String.equal sample.name name
      && sample.labels = [ "store", store ])
    samples

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

let test_trajectory_store_uses_only_canonical_keeper_paths () =
  with_temp_trajectory_stores (fun root expected_bytes ->
    Obs.For_testing.reset_store_cache ();
    let samples = Obs.For_testing.samples ~masc_root:root () in
    let trajectory_label =
      Common.keeper_runtime_store_dirname Common.Keeper_trajectories
    in
    let trajectory_samples name =
      List.filter
        (fun (sample : Otel_metrics.sample) ->
          String.equal sample.name name
          && sample.labels = [ "store", trajectory_label ])
        samples
    in
    (match trajectory_samples "masc_store_bytes" with
     | [ sample ] ->
       check
         (float 0.0)
         "canonical keeper trajectory bytes aggregated; retired root ignored"
         (Float.of_int expected_bytes)
         sample.value
     | _ -> fail "expected exactly one canonical trajectory byte sample");
    match trajectory_samples "masc_store_files" with
    | [ sample ] -> check (float 0.0) "two canonical files" 2.0 sample.value
    | _ -> fail "expected exactly one canonical trajectory file sample")

let test_trajectory_store_preserves_healthy_keeper_on_partial_scan () =
  with_temp_partial_trajectory_stores (fun root expected_bytes ->
    Obs.For_testing.reset_store_cache ();
    let samples = Obs.For_testing.samples ~masc_root:root () in
    let store = Common.keeper_runtime_store_dirname Common.Keeper_trajectories in
    (match find_store_sample "masc_store_bytes" store samples with
     | Some sample ->
       check (float 0.0) "healthy keeper bytes survive sibling path error"
         (Float.of_int expected_bytes) sample.value
     | None -> fail "partial scan discarded healthy keeper byte sample");
    (match find_store_sample "masc_store_files" store samples with
     | Some sample ->
       check (float 0.0) "healthy keeper file survives sibling path error" 1.0
         sample.value
     | None -> fail "partial scan discarded healthy keeper file sample");
    (match find_store_sample "masc_store_scan_errors" store samples with
     | Some sample -> check (float 0.0) "scan error is explicit" 1.0 sample.value
     | None -> fail "partial scan error observation missing");
    match find_store_sample "masc_store_scan_partial" store samples with
    | Some sample -> check (float 0.0) "partial state is explicit" 1.0 sample.value
    | None -> fail "partial scan state observation missing")

let store_bytes_exn ~store samples =
  match find_store_sample "masc_store_bytes" store samples with
  | Some sample -> sample.value
  | None -> failf "masc_store_bytes{store=%s} missing" store

let domain_samples root =
  Domain.spawn (fun () ->
    try Ok (Obs.For_testing.samples ~masc_root:root ()) with
    | exn -> Error exn)

let joined_samples = function
  | Ok samples -> samples
  | Error exn -> raise exn

let test_store_cache_is_root_scoped_and_domain_safe () =
  with_temp_masc_root ~suffix:"root-a" ~contents:"a\n" (fun root_a ->
    with_temp_masc_root ~suffix:"root-b" ~contents:(String.make 97 'b')
      (fun root_b ->
        Obs.For_testing.reset_store_cache ();
        let a_domain = domain_samples root_a in
        let b_domain = domain_samples root_b in
        let a_result = Domain.join a_domain in
        let b_result = Domain.join b_domain in
        let a_samples = joined_samples a_result in
        let b_samples = joined_samples b_result in
        check (float 0.0) "root A keeps its own cache entry" 2.0
          (store_bytes_exn ~store:"tool_calls" a_samples);
        check (float 0.0) "root B keeps its own cache entry" 97.0
          (store_bytes_exn ~store:"tool_calls" b_samples);
        let a_cached = Obs.For_testing.samples ~masc_root:root_a () in
        let b_cached = Obs.For_testing.samples ~masc_root:root_b () in
        check (float 0.0) "root A cached value remains isolated" 2.0
          (store_bytes_exn ~store:"tool_calls" a_cached);
        check (float 0.0) "root B cached value remains isolated" 97.0
          (store_bytes_exn ~store:"tool_calls" b_cached)))

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

let () =
  run "otel_runtime_observables"
    [ ( "samples"
      , [ test_case "core samples always present" `Quick test_core_samples_always_present
        ; test_case "bus/pool absent without subsystems" `Quick
            test_bus_and_pool_absent_without_subsystems
        ; test_case "store bytes from walk + cache" `Quick test_store_bytes_from_walk
        ; test_case "trajectory store uses canonical keeper paths only" `Quick
            test_trajectory_store_uses_only_canonical_keeper_paths
        ; test_case "partial trajectory scan preserves healthy keeper" `Quick
            test_trajectory_store_preserves_healthy_keeper_on_partial_scan
        ; test_case "store cache is root-scoped and domain-safe" `Quick
            test_store_cache_is_root_scoped_and_domain_safe
        ; test_case "fd samples present" `Quick test_fd_samples_present
        ] )
    ]
