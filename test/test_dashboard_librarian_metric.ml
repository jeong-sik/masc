(** Dedicated-process regression for the compact Librarian failure counter.

    This executable owns its metric store lifetime, so it can exercise a
    non-zero process-global counter without contaminating another test. *)

let contains text fragment =
  try
    ignore (Str.search_forward (Str.regexp_string fragment) text 0);
    true
  with Not_found -> false
;;

let temp_dir () =
  let path = Filename.temp_file "dashboard-librarian-metric-" "" in
  Sys.remove path;
  Unix.mkdir path 0o755;
  path
;;

let rec remove_tree path =
  if Sys.file_exists path
  then if Sys.is_directory path
    then (
      Sys.readdir path
      |> Array.iter (fun name -> remove_tree (Filename.concat path name));
      Unix.rmdir path)
    else Sys.remove path
;;

let test_nonzero_failure_total_is_rendered_exactly () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let root = temp_dir () in
  let config = Masc.Workspace.default_config root in
  Fun.protect
    ~finally:(fun () -> remove_tree root)
    (fun () ->
      ignore (Masc.Workspace.init config ~agent_name:None);
      let metric =
        Keeper_metrics.(to_string MemoryOsLibrarianFailures)
      in
      let before = Masc.Otel_metric_store.metric_total metric |> int_of_float in
      Masc.Otel_metric_store.inc_counter
        metric
        ~labels:[ "keeper", "dedicated-dashboard-test"; "site", "test" ]
        ();
      let expected = before + 1 in
      let output = Dashboard.generate_compact config in
      Alcotest.(check bool)
        "non-zero counter has an exact numeric boundary"
        true
        (contains
           output
           (Printf.sprintf
              "LIBRARIAN-FAILURES-SINCE-START: %d | GUARD:"
              expected)))
;;

let () =
  Alcotest.run
    "dashboard_librarian_metric"
    [ ( "compact"
      , [ Alcotest.test_case
            "non-zero failure total is exact"
            `Quick
            test_nonzero_failure_total_is_rendered_exactly
        ] )
    ]
;;
