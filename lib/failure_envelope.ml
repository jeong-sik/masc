type severity =
  | Warn
  | Bad
  | Critical

type recoverability =
  | Operator_action_required
  | Fatal

type tool_host_cause =
  | Tool_host_timeout
  | Tool_host_transport_unavailable

type t = {
  surface : string;
  entity_kind : string;
  entity_id : string option;
  cause_code : string;
  severity : severity;
  summary : string;
  recoverability : recoverability;
  operator_action : string option;
  evidence_ref : Yojson.Safe.t;
}

let tool_host_log_module_name = "ToolHost"

let severity_to_string = function
  | Warn -> "warn"
  | Bad -> "bad"
  | Critical -> "critical"

let severity_of_string = function
  | "warn" -> Ok Warn
  | "bad" -> Ok Bad
  | "critical" -> Ok Critical
  | other -> Error ("unknown failure severity: " ^ other)

let recoverability_to_string = function
  | Operator_action_required -> "operator_action_required"
  | Fatal -> "fatal"

let recoverability_of_string = function
  | "operator_action_required" -> Ok Operator_action_required
  | "fatal" -> Ok Fatal
  | other -> Error ("unknown failure recoverability: " ^ other)

let tool_host_cause_code = function
  | Tool_host_timeout -> "tool_host_timeout"
  | Tool_host_transport_unavailable -> "tool_host_transport_unavailable"

let tool_host_cause_of_code = function
  | "tool_host_timeout" -> Ok Tool_host_timeout
  | "tool_host_transport_unavailable" -> Ok Tool_host_transport_unavailable
  | other -> Error (Printf.sprintf "unknown tool host cause_code: %S" other)

let first_non_empty values =
  List.find_map (fun value -> Option.bind value String_util.trim_nonempty) values

let operator_action_for_tool_host_cause = function
  | Tool_host_timeout | Tool_host_transport_unavailable ->
    Some "masc_operator_digest"

let summary_for_tool_host ~client_name ~tool_name ~transport = function
  | Some phase when String.trim phase <> "" ->
      Printf.sprintf "%s %s failed during %s on %s" client_name tool_name phase
        transport
  | _ -> Printf.sprintf "%s %s failed on %s" client_name tool_name transport

let tool_host_failure ~agent_name ~client_name ~tool_name ~transport ?phase
    ?request_id ?session_id ?trace_id ?timeout_ms ~cause ~message () =
  {
    surface = "tool_host";
    entity_kind = "tool_call";
    entity_id = first_non_empty [ request_id; session_id; trace_id ];
    cause_code = tool_host_cause_code cause;
    severity = Bad;
    summary = summary_for_tool_host ~client_name ~tool_name ~transport phase;
    recoverability =
      (match cause with
       | Tool_host_timeout | Tool_host_transport_unavailable ->
           Operator_action_required);
    operator_action = operator_action_for_tool_host_cause cause;
    evidence_ref =
      `Assoc
        (List.filter_map
           Fun.id
           [
             Some ("agent_name", `String agent_name);
             Some ("client_name", `String client_name);
             Some ("tool_name", `String tool_name);
             Some ("transport", `String transport);
             Some ("message", `String message);
             Option.map (fun value -> ("phase", `String value)) (Option.bind phase String_util.trim_nonempty);
             Option.map (fun value -> ("request_id", `String value)) (Option.bind request_id String_util.trim_nonempty);
             Option.map (fun value -> ("session_id", `String value)) (Option.bind session_id String_util.trim_nonempty);
             Option.map (fun value -> ("trace_id", `String value)) (Option.bind trace_id String_util.trim_nonempty);
             Option.map (fun value -> ("timeout_ms", `Int value)) timeout_ms;
           ]);
  }

let to_yojson (envelope : t) =
  `Assoc
    [
      ("surface", `String envelope.surface);
      ("entity_kind", `String envelope.entity_kind);
      ("entity_id", Json_util.option_to_yojson (fun value -> `String value) envelope.entity_id);
      ("cause_code", `String envelope.cause_code);
      ("severity", `String (severity_to_string envelope.severity));
      ("summary", `String envelope.summary);
      ("recoverability", `String (recoverability_to_string envelope.recoverability));
      ("operator_action", Json_util.option_to_yojson (fun value -> `String value) envelope.operator_action);
      ("evidence_ref", envelope.evidence_ref);
    ]

let required_string json key =
  match Json_util.assoc_member_opt key json with
  | None | Some `Null -> Error (Printf.sprintf "missing required failure field: %s" key)
  | Some (`String value) -> Ok value
  | Some other ->
      Error
        (Printf.sprintf
           "failure field %s must be a string (received %s)" key
           (Json_util.kind_name other))

let optional_string json key =
  match Json_util.assoc_member_opt key json with
  | Some (`String value) -> String_util.trim_nonempty value
  | _ -> None

let of_yojson json =
  match json with
  | `Assoc _ -> (
      match required_string json "surface" with
      | Error _ as err -> err
      | Ok surface -> (
          match required_string json "entity_kind" with
          | Error _ as err -> err
          | Ok entity_kind -> (
              match required_string json "cause_code" with
              | Error _ as err -> err
              | Ok cause_code -> (
                  match required_string json "severity" with
                  | Error _ as err -> err
                  | Ok severity_raw -> (
                      match severity_of_string severity_raw with
                      | Error _ as err -> err
                      | Ok severity -> (
                          match required_string json "summary" with
                          | Error _ as err -> err
                          | Ok summary -> (
                              match required_string json "recoverability" with
                              | Error _ as err -> err
                              | Ok recoverability_raw -> (
                                  match
                                    recoverability_of_string recoverability_raw
                                  with
                                  | Error _ as err -> err
                                  | Ok recoverability ->
                                      Ok
                                        {
                                          surface;
                                          entity_kind;
                                          entity_id =
                                            optional_string json "entity_id";
                                          cause_code;
                                          severity;
                                          summary;
                                          recoverability;
                                          operator_action =
                                            optional_string json
                                              "operator_action";
                                          evidence_ref =
                                            Option.value ~default:`Null
                                              (Json_util.assoc_member_opt
                                                 "evidence_ref" json);
                                        }))))))))
  | other ->
      Error
        (Printf.sprintf "failure envelope must be a JSON object (received %s)"
           (Json_util.kind_name other))

let attach_to_details details envelope =
  match details with
  | `Assoc fields -> `Assoc (("failure_envelope", to_yojson envelope) :: fields)
  | _ -> `Assoc [ ("failure_envelope", to_yojson envelope) ]

let find_in_json json =
  match json with
  | `Assoc _ -> (
      match of_yojson (Option.value ~default:`Null (Json_util.assoc_member_opt "failure_envelope" json)) with
      | Ok envelope -> Some envelope
      | Error _ -> None)
  | _ -> None
