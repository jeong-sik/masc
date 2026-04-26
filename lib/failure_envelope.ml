type severity =
  | Warn
  | Bad
  | Critical

type recoverability =
  | Retryable
  | Operator_action_required
  | Fatal

type t =
  { surface : string
  ; entity_kind : string
  ; entity_id : string option
  ; cause_code : string
  ; severity : severity
  ; summary : string
  ; recoverability : recoverability
  ; operator_action : string option
  ; evidence_ref : Yojson.Safe.t
  }

let tool_host_log_module_name = "ToolHost"

let severity_to_string = function
  | Warn -> "warn"
  | Bad -> "bad"
  | Critical -> "critical"
;;

let severity_of_string = function
  | "warn" -> Ok Warn
  | "bad" -> Ok Bad
  | "critical" -> Ok Critical
  | other -> Error ("unknown failure severity: " ^ other)
;;

let recoverability_to_string = function
  | Retryable -> "retryable"
  | Operator_action_required -> "operator_action_required"
  | Fatal -> "fatal"
;;

let recoverability_of_string = function
  | "retryable" -> Ok Retryable
  | "operator_action_required" -> Ok Operator_action_required
  | "fatal" -> Ok Fatal
  | other -> Error ("unknown failure recoverability: " ^ other)
;;

(** Coerce to canonical [Severity.t] for cross-module communication. *)
let to_severity : severity -> Severity.t = function
  | Warn -> Warning
  | Bad -> Error
  | Critical -> Critical
;;

let option_to_json f = function
  | Some value -> f value
  | None -> `Null
;;

let trim_to_option value =
  let trimmed = String.trim value in
  if trimmed = "" then None else Some trimmed
;;

let first_non_empty values =
  List.find_map (fun value -> Option.bind value trim_to_option) values
;;

let tool_host_cause_code ?timeout_ms message =
  let lower = String.lowercase_ascii message in
  if
    Option.is_some timeout_ms
    || String_util.contains_substring lower "timed out"
    || String_util.contains_substring lower "timeout"
  then "tool_host_timeout"
  else if
    String_util.contains_substring lower "port already in use"
    || String_util.contains_substring lower "connection refused"
    || String_util.contains_substring lower "transport unavailable"
  then "tool_host_transport_unavailable"
  else "tool_host_failure"
;;

let operator_action_for_cause_code = function
  | "tool_host_timeout" -> Some "masc_operator_digest"
  | "tool_host_transport_unavailable" -> Some "masc_operator_digest"
  | _ -> None
;;

let summary_for_tool_host ~client_name ~tool_name ~transport = function
  | Some phase when String.trim phase <> "" ->
    Printf.sprintf "%s %s failed during %s on %s" client_name tool_name phase transport
  | _ -> Printf.sprintf "%s %s failed on %s" client_name tool_name transport
;;

let tool_host_failure
      ~agent_name
      ~client_name
      ~tool_name
      ~transport
      ?phase
      ?request_id
      ?session_id
      ?trace_id
      ?timeout_ms
      ~message
      ()
  =
  let cause_code = tool_host_cause_code ?timeout_ms message in
  { surface = "tool_host"
  ; entity_kind = "tool_call"
  ; entity_id = first_non_empty [ request_id; session_id; trace_id ]
  ; cause_code
  ; severity = Bad
  ; summary = summary_for_tool_host ~client_name ~tool_name ~transport phase
  ; recoverability =
      (match cause_code with
       | "tool_host_timeout" | "tool_host_transport_unavailable" ->
         Operator_action_required
       | _ -> Retryable)
  ; operator_action = operator_action_for_cause_code cause_code
  ; evidence_ref =
      `Assoc
        (List.filter_map
           Fun.id
           [ Some ("agent_name", `String agent_name)
           ; Some ("client_name", `String client_name)
           ; Some ("tool_name", `String tool_name)
           ; Some ("transport", `String transport)
           ; Some ("message", `String message)
           ; Option.map
               (fun value -> "phase", `String value)
               (Option.bind phase trim_to_option)
           ; Option.map
               (fun value -> "request_id", `String value)
               (Option.bind request_id trim_to_option)
           ; Option.map
               (fun value -> "session_id", `String value)
               (Option.bind session_id trim_to_option)
           ; Option.map
               (fun value -> "trace_id", `String value)
               (Option.bind trace_id trim_to_option)
           ; Option.map (fun value -> "timeout_ms", `Int value) timeout_ms
           ])
  }
;;

let to_yojson (envelope : t) =
  `Assoc
    [ "surface", `String envelope.surface
    ; "entity_kind", `String envelope.entity_kind
    ; "entity_id", option_to_json (fun value -> `String value) envelope.entity_id
    ; "cause_code", `String envelope.cause_code
    ; "severity", `String (severity_to_string envelope.severity)
    ; "summary", `String envelope.summary
    ; "recoverability", `String (recoverability_to_string envelope.recoverability)
    ; ( "operator_action"
      , option_to_json (fun value -> `String value) envelope.operator_action )
    ; "evidence_ref", envelope.evidence_ref
    ]
;;

let required_string json key =
  let open Yojson.Safe.Util in
  match json |> member key with
  | `String value -> Ok value
  | _ -> Error ("missing required failure field: " ^ key)
;;

let optional_string json key =
  let open Yojson.Safe.Util in
  match json |> member key with
  | `String value -> trim_to_option value
  | _ -> None
;;

let of_yojson json =
  match json with
  | `Assoc _ ->
    (match required_string json "surface" with
     | Error _ as err -> err
     | Ok surface ->
       (match required_string json "entity_kind" with
        | Error _ as err -> err
        | Ok entity_kind ->
          (match required_string json "cause_code" with
           | Error _ as err -> err
           | Ok cause_code ->
             (match required_string json "severity" with
              | Error _ as err -> err
              | Ok severity_raw ->
                (match severity_of_string severity_raw with
                 | Error _ as err -> err
                 | Ok severity ->
                   (match required_string json "summary" with
                    | Error _ as err -> err
                    | Ok summary ->
                      (match required_string json "recoverability" with
                       | Error _ as err -> err
                       | Ok recoverability_raw ->
                         (match recoverability_of_string recoverability_raw with
                          | Error _ as err -> err
                          | Ok recoverability ->
                            Ok
                              { surface
                              ; entity_kind
                              ; entity_id = optional_string json "entity_id"
                              ; cause_code
                              ; severity
                              ; summary
                              ; recoverability
                              ; operator_action = optional_string json "operator_action"
                              ; evidence_ref = Yojson.Safe.Util.member "evidence_ref" json
                              }))))))))
  | _ -> Error "failure envelope must be a JSON object"
;;

let attach_to_details details envelope =
  match details with
  | `Assoc fields -> `Assoc (("failure_envelope", to_yojson envelope) :: fields)
  | _ -> `Assoc [ "failure_envelope", to_yojson envelope ]
;;

let find_in_json json =
  match json with
  | `Assoc _ ->
    (match of_yojson (Yojson.Safe.Util.member "failure_envelope" json) with
     | Ok envelope -> Some envelope
     | Error _ -> None)
  | _ -> None
;;
