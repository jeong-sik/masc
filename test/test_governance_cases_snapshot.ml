open Alcotest
module G = Masc_mcp.Governance_cases_snapshot
module P = Masc_mcp.Prometheus

let persistence_surface = "governance_cases_snapshot"

let counter_value reason =
  P.metric_value_or_zero
    P.metric_persistence_read_drops
    ~labels:[ "surface", persistence_surface; "reason", reason ]
    ()
;;

let with_temp_dir f =
  let dir = Filename.temp_dir "masc_governance_cases" "" in
  let rec cleanup path =
    if Sys.file_exists path
    then
      if Sys.is_directory path
      then (
        Sys.readdir path |> Array.iter (fun name -> cleanup (Filename.concat path name));
        Unix.rmdir path)
      else Unix.unlink path
  in
  Fun.protect
    ~finally:(fun () ->
      try cleanup dir with
      | _ -> ())
    (fun () -> f dir)
;;

let write_file path body =
  let oc = open_out path in
  Fun.protect ~finally:(fun () -> close_out_noerr oc) (fun () -> output_string oc body)
;;

let test_missing_dir_stays_quiet () =
  with_temp_dir
  @@ fun base_path ->
  let before_list_dir =
    counter_value Safe_ops.persistence_read_drop_reason_list_dir_error
  in
  let before_entry =
    counter_value Safe_ops.persistence_read_drop_reason_entry_load_error
  in
  let before_invalid =
    counter_value Safe_ops.persistence_read_drop_reason_invalid_payload
  in
  let cases = G.load_all ~base_path in
  check int "no cases" 0 (List.length cases);
  check
    (float 0.1)
    "missing dir does not increment list_dir_error"
    before_list_dir
    (counter_value Safe_ops.persistence_read_drop_reason_list_dir_error);
  check
    (float 0.1)
    "missing dir does not increment entry_load_error"
    before_entry
    (counter_value Safe_ops.persistence_read_drop_reason_entry_load_error);
  check
    (float 0.1)
    "missing dir does not increment invalid_payload"
    before_invalid
    (counter_value Safe_ops.persistence_read_drop_reason_invalid_payload)
;;

let test_load_all_skips_bad_entries_with_metric () =
  with_temp_dir
  @@ fun base_path ->
  let dir = G.cases_dir ~base_path in
  Fs_compat.mkdir_p dir;
  Fs_compat.save_file
    (Filename.concat dir "good.json")
    (Yojson.Safe.to_string
       (`Assoc
           [ "id", `String "case-1"
           ; "title", `String "case title"
           ; "status", `String "pending_ruling"
           ; "risk_class", `String "high"
           ; "created_at", `Float 1000.0
           ]));
  write_file (Filename.concat dir "broken.json") "{not-json";
  Fs_compat.save_file
    (Filename.concat dir "missing-id.json")
    (Yojson.Safe.to_string
       (`Assoc
           [ "title", `String "missing id"
           ; "status", `String "pending_ruling"
           ; "risk_class", `String "low"
           ]));
  let before_entry =
    counter_value Safe_ops.persistence_read_drop_reason_entry_load_error
  in
  let before_invalid =
    counter_value Safe_ops.persistence_read_drop_reason_invalid_payload
  in
  let cases = G.load_all ~base_path in
  check int "only valid case loaded" 1 (List.length cases);
  let case = List.hd cases in
  check string "case id" "case-1" case.id;
  check string "case status" "pending_ruling" case.status;
  check
    (float 0.1)
    "broken file increments entry_load_error"
    1.0
    (counter_value Safe_ops.persistence_read_drop_reason_entry_load_error -. before_entry);
  check
    (float 0.1)
    "missing id increments invalid_payload"
    1.0
    (counter_value Safe_ops.persistence_read_drop_reason_invalid_payload -. before_invalid)
;;

let () =
  run
    "Governance_cases_snapshot"
    [ ( "load_all"
      , [ test_case "missing dir stays quiet" `Quick test_missing_dir_stays_quiet
        ; test_case
            "skips bad entries with metric"
            `Quick
            test_load_all_skips_bad_entries_with_metric
        ] )
    ]
;;
