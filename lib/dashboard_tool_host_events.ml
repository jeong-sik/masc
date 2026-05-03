module Format = Stdlib.Format
module Map = Stdlib.Map
module Set = Stdlib.Set
module Queue = Stdlib.Queue
module Hashtbl = Stdlib.Hashtbl
module Mutex = Stdlib.Mutex
module Option = Stdlib.Option
module Result = Stdlib.Result
module Sys = Stdlib.Sys
module Filename = Stdlib.Filename
module List = Stdlib.List
module Array = Stdlib.Array
module String = Stdlib.String
module Char = Stdlib.Char
module Int = Stdlib.Int
module Float = Stdlib.Float

type report = {
  agent_name : string;
  client_name : string;
  tool_name : string;
  transport : string;
  phase : string option;
  message : string;
  request_id : string option;
  session_id : string option;
  trace_id : string option;
  timeout_ms : int option;
}

let trim_to_option value =
  let trimmed = String.trim value in
  if String.equal trimmed "" then None else Some trimmed

let stringish_member_opt json key =
  let open Yojson.Safe.Util in
  match json |> member key with
  | `String value -> trim_to_option value
  | `Int value -> Some (Int.to_string value)
  | `Intlit value -> trim_to_option value
  | `Float value -> Some (Printf.sprintf "%.0f" value)
  | `Null -> None
  | _ -> None

let required_member json key =
  match stringish_member_opt json key with
  | Some value -> Ok value
  | None -> Error (Printf.sprintf "missing required field: %s" key)

let parse_timeout_ms json =
  let open Yojson.Safe.Util in
  match json |> member "timeout_ms" with
  | `Null -> None
  | `Int value -> Some (max 1 value)
  | `Intlit value -> (
      Stdlib.int_of_string_opt (value))
  | _ -> None

let report_of_yojson ?fallback_agent (json : Yojson.Safe.t) :
    (report, string) Result.t =
  match json with
  | `Assoc _ -> (
      match required_member json "tool_name", required_member json "message" with
      | Ok tool_name, Ok message ->
          let client_name =
            match stringish_member_opt json "client_name" with
            | Some value -> value
            | None ->
                Option.value
                  ~default:"tool-host"
                  (Option.bind fallback_agent trim_to_option)
          in
          let explicit_agent =
            Option.bind (stringish_member_opt json "agent_name") trim_to_option
          in
          let fallback_agent = Option.bind fallback_agent trim_to_option in
          let agent_name =
            match explicit_agent with
            | Some value -> value
            | None -> Option.value ~default:client_name fallback_agent
          in
          let transport =
            Option.value ~default:"mcp_http"
              (stringish_member_opt json "transport")
          in
          Ok
            {
              agent_name;
              client_name;
              tool_name;
              transport;
              phase = stringish_member_opt json "phase";
              message;
              request_id = stringish_member_opt json "request_id";
              session_id = stringish_member_opt json "session_id";
              trace_id = stringish_member_opt json "trace_id";
              timeout_ms = parse_timeout_ms json;
            }
      | Error msg, _ | _, Error msg -> Error msg)
  | _ -> Error "request body must be a JSON object"

let details_json (report : report) =
  let envelope =
    Failure_envelope.tool_host_failure ~agent_name:report.agent_name
      ~client_name:report.client_name ~tool_name:report.tool_name
      ~transport:report.transport ?phase:report.phase
      ?request_id:report.request_id ?session_id:report.session_id
      ?trace_id:report.trace_id ?timeout_ms:report.timeout_ms
      ~message:report.message ()
  in
  Failure_envelope.attach_to_details
    (`Assoc
      (List.filter_map
         Stdlib.Fun.id
         [
           Some ("client_name", `String report.client_name);
           Some ("tool_name", `String report.tool_name);
           Some ("transport", `String report.transport);
           Option.map (fun value -> ("phase", `String value)) report.phase;
           Option.map (fun value -> ("request_id", `String value)) report.request_id;
           Option.map (fun value -> ("session_id", `String value)) report.session_id;
           Option.map (fun value -> ("trace_id", `String value)) report.trace_id;
           Option.map (fun value -> ("timeout_ms", `Int value)) report.timeout_ms;
         ]))
    envelope

let ring_message (report : report) =
  let phase =
    match report.phase with
    | Some value -> Printf.sprintf "%s " value
    | None -> ""
  in
  Printf.sprintf "%s %s%s failed: %s" report.client_name phase report.tool_name
    report.message

let record ?fs config (report : report) =
  let details = details_json report in
  Log.client_tool_host_error
    ~module_name:Failure_envelope.tool_host_log_module_name ~details
    (ring_message report);
  Audit_log.log_client_tool_host_failure config ~agent_id:report.agent_name
    ~client_name:report.client_name ~tool_name:report.tool_name
    ~transport:report.transport ~message:report.message ?phase:report.phase
    ?request_id:report.request_id ?session_id:report.session_id
    ?trace_id:report.trace_id ?timeout_ms:report.timeout_ms ();
  if Option.is_some fs then
    Telemetry_eio.track_error ?fs config ~code:"client_tool_host_failure"
      ~message:report.message
      ~context:
        (Printf.sprintf "client=%s tool=%s transport=%s"
           report.client_name report.tool_name report.transport)

(** Assignment event snapshot for dashboard visibility. *)
type assignment_snapshot = {
  agent_name : string;
  profile : string;
  preset : string option;
  tool_count : int;
  assignment_id : string;
}

let record_assignment ?fs config (snapshot : assignment_snapshot) =
  Telemetry_eio.track_tool_assigned ?fs config
    ~agent_id:snapshot.agent_name
    ~profile:snapshot.profile
    ?preset:snapshot.preset
    ~tool_count:snapshot.tool_count
    ~assignment_id:snapshot.assignment_id
    ()
