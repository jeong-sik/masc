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

let write_rules ~base_path json =
  let masc_dir = Filename.concat base_path ".masc" in
  if not (Sys.file_exists masc_dir) then Unix.mkdir masc_dir 0o755;
  Out_channel.with_open_text
    (Filename.concat masc_dir "approval-rules.json")
    (fun oc -> output_string oc (Yojson.Safe.pretty_to_string json))
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
       write_rules
         ~base_path
         (`List [ with_max_risk (`String "god-mode") valid_rule_json ]);
       check int "malformed rule skipped during load" 0 (List.length (AQ.list_rules ~base_path ()));
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

let () =
  run
    "Keeper_approval_queue_rules"
    [ ( "persisted rules"
      , [ test_case
            "malformed persisted rule cannot match"
            `Quick
            test_malformed_persisted_rule_cannot_match
        ] )
    ]
;;
