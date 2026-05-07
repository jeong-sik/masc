module Dash = Masc_mcp.Dashboard_http_keeper
module P = Masc_mcp.Prometheus
module KT = Masc_mcp.Keeper_types

open Alcotest

let temp_dir () =
  let dir = Filename.temp_file "dashboard_keeper_alerts_drop_" "" in
  Unix.unlink dir;
  Unix.mkdir dir 0o755;
  dir

let cleanup_dir dir =
  let rec rm path =
    if Sys.file_exists path then
      if Sys.is_directory path then (
        Array.iter (fun name -> rm (Filename.concat path name)) (Sys.readdir path);
        Unix.rmdir path)
      else
        Unix.unlink path
  in
  try rm dir with _ -> ()

let write_lines path lines =
  KT.mkdir_p (Filename.dirname path);
  let oc = open_out path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr oc)
    (fun () ->
      List.iter
        (fun line ->
          output_string oc line;
          output_char oc '\n')
        lines)

let persistence_read_drop_total ~surface ~reason =
  P.metric_value_or_zero P.metric_persistence_read_drops
    ~labels:[("surface", surface); ("reason", reason)]
    ()

let check_persistence_read_drop_delta ~surface ~reason ~before ~delta =
  check (float 0.0001)
    (Printf.sprintf "%s/%s persistence read drops" surface reason)
    (before +. float_of_int delta)
    (persistence_read_drop_total ~surface ~reason)

let test_recent_alerts_count_malformed_rows () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir base) (fun () ->
    let config = Masc_mcp.Coord.default_config base in
    let surface = "dashboard_keeper_recent_alerts" in
    let entry_error = Safe_ops.persistence_read_drop_reason_entry_load_error in
    let invalid_payload = Safe_ops.persistence_read_drop_reason_invalid_payload in
    let entry_before = persistence_read_drop_total ~surface ~reason:entry_error in
    let invalid_before = persistence_read_drop_total ~surface ~reason:invalid_payload in
    let alerts_path = KT.keeper_alerts_path config in
    write_lines alerts_path [
      Yojson.Safe.to_string
        (`Assoc
          [ ("keeper", `String "alpha")
          ; ("level", `String "bad")
          ; ("message", `String "alert visible")
          ]);
      "[1]";
      "{not-json";
    ];
    let json = Dash.keepers_dashboard_json ~compact:true config in
    let open Yojson.Safe.Util in
    let alerts = json |> member "recent_alerts" |> to_list in
    check int "valid alert preserved" 1 (List.length alerts);
    check string "alert message" "alert visible"
      (List.hd alerts |> member "message" |> to_string);
    check_persistence_read_drop_delta
      ~surface
      ~reason:entry_error
      ~before:entry_before
      ~delta:1;
    check_persistence_read_drop_delta
      ~surface
      ~reason:invalid_payload
      ~before:invalid_before
      ~delta:1)

let () =
  run "dashboard_keeper_alerts_read_drop" [
    "recent_alerts", [
      test_case "malformed persisted rows count read drops" `Quick
        test_recent_alerts_count_malformed_rows;
    ];
  ]
