module Stress = Masc_mcp.Agent_stress
module Prometheus = Masc_mcp.Prometheus
module Safe_ops = Safe_ops

let assoc_field name = function
  | `Assoc fields -> List.assoc_opt name fields
  | _ -> None

let nested_assoc_field outer inner json =
  match assoc_field outer json with
  | Some (`Assoc fields) -> List.assoc_opt inner fields
  | _ -> None

let temp_dir () =
  let dir =
    Filename.concat (Filename.get_temp_dir_name ())
      (Printf.sprintf "agent-stress-test-%d-%d"
         (Unix.getpid ()) (Random.int 1_000_000))
  in
  Unix.mkdir dir 0o755;
  dir

let rec rm_rf path =
  if Sys.file_exists path then
    if Sys.is_directory path then (
      Array.iter (fun name -> rm_rf (Filename.concat path name)) (Sys.readdir path);
      Unix.rmdir path)
    else Sys.remove path

let with_temp_base f =
  let dir = temp_dir () in
  Fun.protect ~finally:(fun () -> rm_rf dir) (fun () -> f dir)

let write_lines path lines =
  let oc = open_out path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr oc)
    (fun () ->
      output_string oc (String.concat "\n" lines);
      output_char oc '\n')

let persistence_drop_value reason =
  Prometheus.metric_value_or_zero Prometheus.metric_persistence_read_drops
    ~labels:[("surface", "agent_stress"); ("reason", reason)]
    ()

let test_turn_failure_json_contract () =
  let event : Stress.event =
    {
      agent_name = "sangsu";
      room_id = "default";
      kind =
        Stress.Turn_failure {
          consecutive = 2;
          threshold = 3;
          counted_toward_crash = true;
          recoverable = false;
          error_kind = Some (Stress.error_kind_of_string "api");
        };
      timestamp = 1_777_120_045.0;
    }
  in
  let json = Stress.event_to_json event in
  Alcotest.(check (option string))
    "agent"
    (Some "sangsu")
    (match assoc_field "agent_name" json with
     | Some (`String s) -> Some s
     | _ -> None);
  Alcotest.(check (option string))
    "kind type"
    (Some "turn_failure")
    (match nested_assoc_field "kind" "type" json with
     | Some (`String s) -> Some s
     | _ -> None);
  Alcotest.(check (option int))
    "consecutive"
    (Some 2)
    (match nested_assoc_field "kind" "consecutive" json with
     | Some (`Int n) -> Some n
     | _ -> None);
  Alcotest.(check (option int))
    "threshold"
    (Some 3)
    (match nested_assoc_field "kind" "threshold" json with
     | Some (`Int n) -> Some n
     | _ -> None);
  Alcotest.(check (option bool))
    "counted toward crash"
    (Some true)
    (match nested_assoc_field "kind" "counted_toward_crash" json with
     | Some (`Bool b) -> Some b
     | _ -> None);
  Alcotest.(check (option bool))
    "recoverable"
    (Some false)
    (match nested_assoc_field "kind" "recoverable" json with
     | Some (`Bool b) -> Some b
     | _ -> None);
  Alcotest.(check (option string))
    "error kind"
    (Some "api")
    (match nested_assoc_field "kind" "error_kind" json with
     | Some (`String s) -> Some s
     | _ -> None)

let test_turn_failure_omits_absent_error_kind () =
  let event : Stress.event =
    {
      agent_name = "janitor";
      room_id = "";
      kind =
        Stress.Turn_failure {
          consecutive = 0;
          threshold = 3;
          counted_toward_crash = false;
          recoverable = true;
          error_kind = None;
        };
      timestamp = 1.0;
    }
  in
  let json = Stress.event_to_json event in
  Alcotest.(check (option string))
    "kind type"
    (Some "turn_failure")
    (match nested_assoc_field "kind" "type" json with
     | Some (`String s) -> Some s
     | _ -> None);
  Alcotest.(check bool)
    "no raw/absent error field"
    true
    (Option.is_none (nested_assoc_field "kind" "error_kind" json))

let test_recent_records_jsonl_drop_metric () =
  with_temp_base @@ fun base_path ->
  let masc_dir = Filename.concat base_path ".masc" in
  Unix.mkdir masc_dir 0o755;
  Stress.init ~base_path;
  let valid : Stress.event =
    {
      agent_name = "sangsu";
      room_id = "default";
      kind = Stress.Timeout;
      timestamp = 2.0;
    }
  in
  let reason = Safe_ops.persistence_read_drop_reason_entry_load_error in
  let before = persistence_drop_value reason in
  write_lines
    (Filename.concat masc_dir "agent_stress.jsonl")
    [ Yojson.Safe.to_string (Stress.event_to_json valid); "{not-json" ];
  let recent = Stress.recent 10 in
  Alcotest.(check int) "valid event survives" 1 (List.length recent);
  Alcotest.(check (float 0.001)) "malformed row increments drop counter" 1.0
    (persistence_drop_value reason -. before)

let () =
  Alcotest.run
    "Agent_stress"
    [
      ( "turn failure"
      , [
          Alcotest.test_case
            "serializes typed turn failure stress" `Quick
            test_turn_failure_json_contract;
          Alcotest.test_case
            "omits absent error kind" `Quick
            test_turn_failure_omits_absent_error_kind;
          Alcotest.test_case
            "recent counts malformed jsonl drops" `Quick
            test_recent_records_jsonl_drop_metric;
        ] );
    ]
