(** task-366: generate / generate_compact tool_failures parity.

    The Keepers section title ([generate], "tool errors: N") and the compact
    header TOOL-ERR suffix ([generate_compact]) are two renderings of the
    same metric store. Before task-366 they aggregated different metric
    sets, so the compact view could report a larger "tool errors" count
    than the full view on the same store. This regression pins that both
    renderings move together, including for metrics that only the compact
    path used to count (ExecutionReceiptFailures,
    ToolExecuteFailures). *)

let contains text fragment =
  try
    ignore (Str.search_forward (Str.regexp_string fragment) text 0);
    true
  with Not_found -> false
;;

let temp_dir () =
  let path = Filename.temp_file "dashboard-tool-failure-parity-" "" in
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

let bump metric =
  Masc.Otel_metric_store.inc_counter
    metric
    ~labels:[ "keeper", "dashboard-parity-test"; "site", "test" ]
    ()
;;

(* The full view's Keepers title is the only place [generate] surfaces the
   count: "Keepers (tool errors: N)" when the count is non-zero (other
   segments omitted). *)
let extract_full_tool_errors output =
  try
    ignore
      (Str.search_forward
         (Str.regexp "tool errors: \\([0-9]+\\)\\([)\\n]\\)")
         output
         0);
    Some (int_of_string (Str.matched_group 1 output))
  with Not_found -> None
;;

let extract_compact_tool_errors output =
  try
    ignore (Str.search_forward (Str.regexp "TOOL-ERR: \\([0-9]+\\)") output 0);
    Some (int_of_string (Str.matched_group 1 output))
  with Not_found -> None
;;

(* Metrics that only generate_compact used to aggregate (task-478 F2):
   bumping them used to move the compact number while the full view stood
   still. The shared tool_failure_total () now makes both move. *)
let test_full_and_compact_agree_on_late_added_metrics () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let root = temp_dir () in
  let config = Masc.Workspace.default_config root in
  Fun.protect
    ~finally:(fun () -> remove_tree root)
    (fun () ->
      ignore (Masc.Workspace.init config ~agent_name:None);
      bump Keeper_metrics.(to_string ExecutionReceiptFailures);
      bump Keeper_metrics.(to_string ToolExecuteFailures);
      let full = Dashboard.generate config in
      let compact = Dashboard.generate_compact config in
      let full_n = extract_full_tool_errors full in
      let compact_n = extract_compact_tool_errors compact in
      Alcotest.(check bool)
        "full view reports the bumped receipts metric" true
        (full_n <> None);
      Alcotest.(check bool)
        "compact view reports the bumped receipts metric" true
        (compact_n <> None);
      match full_n, compact_n with
      | Some f, Some c ->
          Alcotest.(check int)
            "full and compact tool errors agree" f c
      | _ -> Alcotest.failf "renderings lost the tool errors segment")
;;

let () =
  Alcotest.run
    "dashboard_tool_failure_parity"
    [ ( "parity"
      , [ Alcotest.test_case
            "full and compact agree on late-added metrics"
            `Quick
            test_full_and_compact_agree_on_late_added_metrics
        ] ) ]
;;
