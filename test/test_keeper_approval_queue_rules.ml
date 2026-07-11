open Alcotest

module AQ = Masc.Keeper_approval_queue

let temp_dir () =
  let dir = Filename.temp_file "test_keeper_approval_queue_rules_" "" in
  Unix.unlink dir;
  Unix.mkdir dir 0o755;
  dir
;;

let cleanup_dir dir =
  let rec rm_rf path =
    if Sys.is_directory path
    then (
      Array.iter (fun name -> rm_rf (Filename.concat path name)) (Sys.readdir path);
      Unix.rmdir path)
    else Sys.remove path
  in
  try rm_rf dir with
  | _ -> ()
;;

let rules_path ~base_path =
  Filename.concat
    (Common.masc_dir_from_base_path ~base_path)
    "approval-rules.json"
;;

let write_rules ~base_path json =
  let masc_dir = Common.masc_dir_from_base_path ~base_path in
  if not (Sys.file_exists masc_dir) then Unix.mkdir masc_dir 0o755;
  Out_channel.with_open_text (rules_path ~base_path) (fun oc ->
    output_string oc (Yojson.Safe.pretty_to_string json))
;;

let write_rules_raw ~base_path content =
  let masc_dir = Common.masc_dir_from_base_path ~base_path in
  if not (Sys.file_exists masc_dir) then Unix.mkdir masc_dir 0o755;
  Out_channel.with_open_text (rules_path ~base_path) (fun oc -> output_string oc content)
;;

let read_drop_count reason =
  Masc.Otel_metric_store.metric_value_or_zero
    Masc.Otel_metric_store.metric_persistence_read_drops
    ~labels:[ "surface", "keeper_approval_rules"; "reason", reason ]
    ()
;;

let stored_rule_json ~base_path =
  match AQ.list_rules_dashboard_json ~base_path () with
  | `List [ (`Assoc _ as rule_json) ] -> rule_json
  | json ->
    fail
      ("expected exactly one stored approval rule, got: " ^ Yojson.Safe.to_string json)
;;

let with_max_risk value = function
  | `Assoc fields -> `Assoc (("max_risk", value) :: List.remove_assoc "max_risk" fields)
  | json -> json
;;

let matching_lookup ~base_path ~input () =
  AQ.find_matching_rule
    ~base_path
    ~keeper_name:"keeper"
    ~tool_name:"tool_execute"
    ~input
    ~risk_level:AQ.Low
    ()
;;

let test_malformed_persisted_rule_cannot_match () =
  let base_path = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_path)
    (fun () ->
       let input = `Assoc [ "command", `String "deploy"; "args", `List [] ] in
       let _, created =
         AQ.upsert_rule
           ~base_path
           ~keeper_name:"keeper"
           ~tool_name:"tool_execute"
           ~input
           ~risk_level:AQ.High
           ()
       in
       check bool "fixture rule created" true created;
       let valid_rule_json = stored_rule_json ~base_path in
       let before_invalid_payload =
         read_drop_count Safe_ops.persistence_read_drop_reason_invalid_payload
       in
       write_rules
         ~base_path
         (`List [ with_max_risk (`String "god-mode") valid_rule_json ]);
       check int "malformed rule skipped during load" 0 (List.length (AQ.list_rules ~base_path ()));
       let after_invalid_payload =
         read_drop_count Safe_ops.persistence_read_drop_reason_invalid_payload
       in
       check
         bool
         "malformed rule reported"
         true
         (after_invalid_payload -. before_invalid_payload >= 1.0);
       check
         bool
         "malformed rule does not auto-approve matching low-risk request"
         true
         (Option.is_none (matching_lookup ~base_path ~input ()));
       write_rules ~base_path (`List [ valid_rule_json ]);
       check int "valid rule loads" 1 (List.length (AQ.list_rules ~base_path ()));
       check
         bool
         "same persisted shape matches once valid"
         true
         (Option.is_some (matching_lookup ~base_path ~input ())))
;;

let test_corrupt_rules_file_reports_read_drop () =
  let base_path = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_path)
    (fun () ->
       let before_entry_load =
         read_drop_count Safe_ops.persistence_read_drop_reason_entry_load_error
       in
       write_rules_raw ~base_path "{not-json";
       check int "corrupt file loads no rules" 0 (List.length (AQ.list_rules ~base_path ()));
       let after_entry_load =
         read_drop_count Safe_ops.persistence_read_drop_reason_entry_load_error
       in
       check
         bool
         "corrupt file reported"
         true
         (after_entry_load -. before_entry_load >= 1.0))
;;

let () =
  Eio_main.run @@ fun _env ->
  run
    "Keeper_approval_queue_rules"
    [ ( "persisted rules"
      , [ test_case
            "malformed persisted rule cannot match"
            `Quick
            test_malformed_persisted_rule_cannot_match
        ; test_case
            "corrupt rules file reports read drop"
            `Quick
            test_corrupt_rules_file_reports_read_drop
        ] )
    ]
;;
