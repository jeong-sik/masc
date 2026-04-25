module Stress = Masc_mcp.Agent_stress

let assoc_field name = function
  | `Assoc fields -> List.assoc_opt name fields
  | _ -> None

let nested_assoc_field outer inner json =
  match assoc_field outer json with
  | Some (`Assoc fields) -> List.assoc_opt inner fields
  | _ -> None

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
          error_kind = Some "api";
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
        ] );
    ]
