(** Characterisation of the unfiltered keeper-metric fan-in.

    With no [keeper_name] and no correlation filter, [read_unified] routes
    [Keeper_metric] through an internal fast path that probes every keeper
    directory for its newest timestamp, sorts the directories by it, and then
    reads entries only while a directory can still beat the running cutoff.

    That path has no test. These pin what it returns — newest-first, across
    keeper directories, honouring the limit — so the probe stage can be changed
    without guessing at its contract. The probe currently retains every
    directory's probe rows, which is a cost proportional to keeper count and
    the axis RFC-0372 §5 makes the Phase 2 gate; nothing below depends on that
    retention. *)

open Alcotest

let counter = ref 0

let temp_root () =
  incr counter;
  let dir =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "telemetry_fan_in_%d_%d" !counter (Unix.getpid ()))
  in
  Fs_compat.mkdir_p dir;
  dir

let cleanup_dir dir =
  let rec rm path =
    if Sys.file_exists path then
      if Sys.is_directory path then (
        Array.iter (fun name -> rm (Filename.concat path name)) (Sys.readdir path);
        Unix.rmdir path)
      else Unix.unlink path
  in
  try rm dir with _ -> ()

(* One keeper's metrics store, seeded with the given timestamps in the order
   given. The reader treats a day-file as append-ordered. *)
let seed_keeper masc_root ~name ~timestamps =
  let metrics_dir =
    Filename.concat
      (Filename.concat (Filename.concat masc_root Common.keepers_runtime_dirname) name)
      "metrics"
  in
  let month_dir = Filename.concat metrics_dir "2026-01" in
  Fs_compat.mkdir_p month_dir;
  let buf = Buffer.create 512 in
  List.iter
    (fun ts ->
      Buffer.add_string buf
        (Printf.sprintf {|{"timestamp":%.1f,"keeper":"%s","kind":"metric"}|} ts name);
      Buffer.add_char buf '\n')
    timestamps;
  Fs_compat.append_file (Filename.concat month_dir "01.jsonl") (Buffer.contents buf)

let timestamps_of entries =
  List.map
    (fun json -> Yojson.Safe.Util.(json |> member "timestamp" |> to_float))
    entries

let read_top root ~n =
  Telemetry_unified.read_unified ~base_path:root ~masc_root:root
    ~sources:[ Telemetry_unified.Keeper_metric ]
    ~limit:(Telemetry_unified.read_limit_of_int n)
    ()

let with_root f =
  let root = temp_root () in
  Fun.protect ~finally:(fun () -> cleanup_dir root) (fun () -> f root)

let test_returns_newest_first_across_keepers () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  with_root (fun root ->
    seed_keeper root ~name:"alpha" ~timestamps:[ 100.0; 400.0 ];
    seed_keeper root ~name:"bravo" ~timestamps:[ 200.0; 500.0 ];
    seed_keeper root ~name:"charlie" ~timestamps:[ 300.0 ];
    check (list (float 0.001)) "newest first across all keeper stores"
      [ 500.0; 400.0; 300.0; 200.0; 100.0 ]
      (timestamps_of (read_top root ~n:10)))

let test_limit_takes_the_newest_slice () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  with_root (fun root ->
    seed_keeper root ~name:"alpha" ~timestamps:[ 100.0; 400.0 ];
    seed_keeper root ~name:"bravo" ~timestamps:[ 200.0; 500.0 ];
    seed_keeper root ~name:"charlie" ~timestamps:[ 300.0 ];
    check (list (float 0.001)) "limit keeps the newest two"
      [ 500.0; 400.0 ]
      (timestamps_of (read_top root ~n:2)))

(* A keeper whose newest entry is older than the running cutoff must not
   contribute, but must also not truncate the result: the early exit is an
   optimisation, not a filter. *)
let test_a_stale_keeper_does_not_shorten_the_result () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  with_root (fun root ->
    seed_keeper root ~name:"fresh" ~timestamps:[ 900.0; 950.0; 990.0 ];
    seed_keeper root ~name:"stale" ~timestamps:[ 1.0; 2.0 ];
    check (list (float 0.001)) "cutoff skips the stale store only"
      [ 990.0; 950.0; 900.0 ]
      (timestamps_of (read_top root ~n:3)))

let test_a_keeper_without_metrics_is_skipped () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  with_root (fun root ->
    seed_keeper root ~name:"alpha" ~timestamps:[ 100.0 ];
    (* A keeper directory with no metrics subdirectory at all. *)
    Fs_compat.mkdir_p
      (Filename.concat
         (Filename.concat root Common.keepers_runtime_dirname)
         "no-metrics");
    check (list (float 0.001)) "directory without a metrics store is ignored"
      [ 100.0 ]
      (timestamps_of (read_top root ~n:10)))

let test_empty_root_reads_nothing () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  with_root (fun root ->
    check (list (float 0.001)) "no keepers, no entries" []
      (timestamps_of (read_top root ~n:10)))

let () =
  run "telemetry_unified_keeper_fan_in"
    [ ( "unfiltered_fast_path",
        [ test_case "newest first across keepers" `Quick
            test_returns_newest_first_across_keepers;
          test_case "limit takes the newest slice" `Quick
            test_limit_takes_the_newest_slice;
          test_case "a stale keeper does not shorten the result" `Quick
            test_a_stale_keeper_does_not_shorten_the_result;
          test_case "a keeper without metrics is skipped" `Quick
            test_a_keeper_without_metrics_is_skipped;
          test_case "empty root reads nothing" `Quick test_empty_root_reads_nothing
        ] )
    ]
