type principal = Keeper of string | Authenticated_agent of string | Host_actor of string | Operator | Anonymous
type companion = {socket_path:string;invocation_id:string;max_message_bytes:int}
type t = { tool : string; arguments : Yojson.Safe.t; principal : principal;
  controller : Machine_controller_contract.admission option;companion:companion option }
let companion_to_json value=`Assoc ["socket_path",`String value.socket_path;
  "invocation_id",`String value.invocation_id;"max_message_bytes",`Int value.max_message_bytes]
let companion_of_json = function
  | `Assoc fields when List.sort String.compare (List.map fst fields)
      =["invocation_id";"max_message_bytes";"socket_path"] ->
      (match List.assoc "socket_path" fields,List.assoc "invocation_id" fields,List.assoc "max_message_bytes" fields with
       | `String socket_path,`String invocation_id,`Int max_message_bytes
          when not (Filename.is_relative socket_path) && not (String.contains socket_path '\000')
            && String.length invocation_id=64 && max_message_bytes>0
            && String.for_all (fun c -> (c>='0' && c<='9') || (c>='a' && c<='f')) invocation_id ->
          Ok {socket_path;invocation_id;max_message_bytes}
       | _ -> Error "invalid private companion context")
  | _ -> Error "invalid private companion context"
let tool_name = "lane_call"
let principal_to_json = function
  | Keeper name -> `Assoc ["kind", `String "keeper"; "name", `String name]
  | Authenticated_agent name -> `Assoc ["kind", `String "agent"; "name", `String name]
  | Host_actor name -> `Assoc ["kind", `String "host_actor"; "name", `String name]
  | Operator -> `Assoc ["kind", `String "operator"]
  | Anonymous -> `Assoc ["kind", `String "anonymous"]
let to_json_with_controller ~controller ~companion ~tool ~arguments ~principal =
  `Assoc (["tool", `String tool; "arguments", arguments; "caller", principal_to_json principal]
    @ (match controller with None -> [] | Some admission ->
      ["controller", Machine_controller_contract.admission_to_json admission])
    @ (match companion with None -> [] | Some value -> ["companion",companion_to_json value]))
let to_json = to_json_with_controller ~controller:None ~companion:None
let object_fields expected = function
  | `Assoc fields when List.sort String.compare (List.map fst fields)
      = List.sort String.compare expected -> Ok fields
  | _ -> Error "invalid or duplicate Lane call context fields"
let ( let* ) = Result.bind
let of_json json =
  let expected = ["tool";"arguments";"caller"] @ (match json with
    | `Assoc fields -> List.filter (fun key -> List.mem_assoc key fields) ["controller";"companion"]
    | _ -> []) in
  let* fields = object_fields expected json in
  let* controller = match List.assoc_opt "controller" fields with
    | None -> Ok None
    | Some value -> Result.map Option.some (Machine_controller_contract.admission_of_json value) in
  let* companion = match List.assoc_opt "companion" fields with
    | None -> Ok None | Some value -> Result.map Option.some (companion_of_json value) in
  let* tool = match List.assoc "tool" fields with
    | `String name when name <> "" && String.equal name (String.trim name) -> Ok name
    | _ -> Error "Lane call context requires a tool name" in
  let* arguments = match List.assoc "arguments" fields with
    | `Assoc _ as value -> Ok value
    | _ -> Error "Lane tool arguments must be an object" in
  let* principal = match List.assoc "caller" fields with
    | `Assoc [("kind", `String "operator")] -> Ok Operator
    | `Assoc [("kind", `String "anonymous")] -> Ok Anonymous
    | value ->
        let* caller = object_fields ["kind";"name"] value in
        match List.assoc "kind" caller, List.assoc "name" caller with
        | `String "keeper", `String name when name <> "" && String.equal name (String.trim name) -> Ok (Keeper name)
        | `String "agent", `String name when name <> "" && String.equal name (String.trim name) -> Ok (Authenticated_agent name)
        | `String "host_actor", `String name when name <> "" && String.equal name (String.trim name) -> Ok (Host_actor name)
        | _ -> Error "invalid Lane call principal" in
  Ok {tool;arguments;principal;controller;companion}

let input_schema = `Assoc [
  "type", `String "object"; "additionalProperties", `Bool false;
  "required", `List (List.map (fun s -> `String s) ["tool";"arguments";"caller"]);
  "properties", `Assoc [
    "tool", `Assoc ["type", `String "string"];
    "arguments", `Assoc ["type", `String "object"];
    "caller", `Assoc ["type", `String "object"];
    "controller", Machine_controller_contract.admission_schema;
    "companion",`Assoc ["type",`String "object";"additionalProperties",`Bool false;
      "required",`List [`String "socket_path";`String "invocation_id";`String "max_message_bytes"];
      "properties",`Assoc ["socket_path",`Assoc ["type",`String "string"];
        "invocation_id",`Assoc ["type",`String "string"];"max_message_bytes",`Assoc ["type",`String "integer"]]]]]

let actor_label = function
  | Keeper name -> "keeper/" ^ name
  | Authenticated_agent name -> "agent/" ^ name
  | Host_actor name -> "actor/" ^ name
  | Operator -> "operator"
  | Anonymous -> "anonymous"

type host_refusal = Rejected of string | Unavailable of string
  | Activity_disabled of string | Activity_unobserved of string
type invocation_error = Host_refusal of host_refusal | Transport_error of string

(** Host mediation obtains credential admission before any worker RPC mutex.
    Each RPC is serialized independently. Keep admission through [invoke]; the
    worker rechecks the observed holder atomically before effects. A failed
    snapshot is never an empty controller. Lifecycle callers may use
    [release_controller] under an already held credential transaction. *)
type mediation =
  release_controller:(holder:string -> reason:Machine_controller_contract.holder_departure ->
    (Mcp_protocol.Mcp_types.tool_result, invocation_error) result) ->
  snapshot:(unit -> (string option, string) result) ->
  invoke:(Machine_controller_contract.admission option -> (Mcp_protocol.Mcp_types.tool_result, invocation_error) result) ->
  (Mcp_protocol.Mcp_types.tool_result, invocation_error) result
