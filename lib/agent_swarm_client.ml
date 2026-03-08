(** MASC MCP client - JSON-RPC 2.0 over HTTP.
    Communicates with the MASC server at POST /mcp using the
    MCP tools/call method wrapped in JSON-RPC 2.0 envelopes. *)

type t = {
  base_url: string;
  agent_name: string;
  net: [ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t;
  mutable request_id: int;
}

let create ~net ~base_url ~agent_name =
  { base_url; agent_name; net; request_id = 0 }

(** Build a JSON-RPC 2.0 request envelope for MCP tools/call *)
let build_request t ~masc_method ~arguments =
  t.request_id <- t.request_id + 1;
  `Assoc [
    ("jsonrpc", `String "2.0");
    ("method", `String "tools/call");
    ("params", `Assoc [
      ("name", `String masc_method);
      ("arguments", `Assoc arguments);
    ]);
    ("id", `Int t.request_id);
  ]

(** Extract the result from a JSON-RPC 2.0 response.
    Returns Ok with the parsed content or Error with a description. *)
let parse_rpc_response json =
  let open Yojson.Safe.Util in
  match json |> member "error" with
  | `Null ->
    let result = json |> member "result" in
    Ok result
  | err ->
    let msg = err |> member "message" |> to_string_option
              |> Option.value ~default:(Yojson.Safe.to_string err) in
    Error (Printf.sprintf "JSON-RPC error: %s" msg)

(** Extract JSON from SSE-formatted response (Streamable HTTP).
    Finds the first "data:" line containing a JSON object. *)
let extract_json_from_sse raw =
  let lines = String.split_on_char '\n' raw in
  let rec find = function
    | [] -> Error "No data: line found in SSE response"
    | line :: rest ->
      let trimmed = String.trim line in
      if String.length trimmed > 5
         && String.sub trimmed 0 5 = "data:"
      then
        let json_str = String.trim (String.sub trimmed 5 (String.length trimmed - 5)) in
        if String.length json_str > 0 && json_str.[0] = '{'
        then Ok json_str
        else find rest
      else find rest
  in
  find lines

(** Send a JSON-RPC call to the MASC server and return the result.
    Handles both plain JSON and SSE (Streamable HTTP) responses. *)
let call_rpc ~sw t ~masc_method ~arguments =
  let body_json = build_request t ~masc_method ~arguments in
  let body_str = Yojson.Safe.to_string body_json in
  let uri = Uri.of_string (t.base_url ^ "/mcp") in
  let headers = Http.Header.of_list [
    ("Content-Type", "application/json");
    ("Accept", "application/json, text/event-stream");
  ] in
  (* MASC server runs on localhost HTTP; TLS not needed *)
  let client = Cohttp_eio.Client.make ~https:None t.net in
  try
    let resp, body =
      Cohttp_eio.Client.post ~sw client ~headers
        ~body:(Cohttp_eio.Body.of_string body_str) uri
    in
    match Cohttp.Response.status resp with
    | `OK ->
      let resp_str = Eio.Buf_read.(of_flow ~max_size:(10 * 1024 * 1024) body |> take_all) in
      let content_type =
        Cohttp.Response.headers resp
        |> (fun h -> Http.Header.get h "content-type")
        |> Option.value ~default:"application/json"
      in
      let json_str =
        if String.length content_type >= 17
           && String.sub content_type 0 17 = "text/event-stream"
        then extract_json_from_sse resp_str
        else Ok resp_str
      in
      (match json_str with
       | Error msg -> Error msg
       | Ok s ->
         (match Yojson.Safe.from_string s with
          | json -> parse_rpc_response json
          | exception Yojson.Json_error msg ->
            Error (Printf.sprintf "JSON parse error: %s" msg)))
    | status ->
      let resp_str = Eio.Buf_read.(of_flow ~max_size:(10 * 1024 * 1024) body |> take_all) in
      Error (Printf.sprintf "HTTP %s: %s"
               (Cohttp.Code.string_of_status status) resp_str)
  with exn ->
    Error (Printf.sprintf "Network error: %s" (Printexc.to_string exn))

(* --- Room lifecycle --- *)

let join ~sw t =
  call_rpc ~sw t ~masc_method:"masc_join"
    ~arguments:[("agent_name", `String t.agent_name)]

let leave ~sw t =
  call_rpc ~sw t ~masc_method:"masc_leave"
    ~arguments:[("agent_name", `String t.agent_name)]

let status ~sw t =
  call_rpc ~sw t ~masc_method:"masc_status"
    ~arguments:[]

(* --- Task operations --- *)

let list_tasks ~sw t =
  call_rpc ~sw t ~masc_method:"masc_tasks"
    ~arguments:[]

let add_task ~sw t ~title ~description =
  call_rpc ~sw t ~masc_method:"masc_add_task"
    ~arguments:[
      ("title", `String title);
      ("description", `String description);
    ]

let batch_add_tasks ~sw t ~tasks =
  let tasks_json =
    `List
      (List.map
         (fun (title, description) ->
           `Assoc
             [ ("title", `String title); ("description", `String description) ])
         tasks)
  in
  call_rpc ~sw t ~masc_method:"masc_batch_add_tasks"
    ~arguments:[("tasks", tasks_json)]

let claim ~sw t ~task_id =
  call_rpc ~sw t ~masc_method:"masc_claim"
    ~arguments:[
      ("agent_name", `String t.agent_name);
      ("task_id", `String task_id);
    ]

let claim_next ~sw t =
  call_rpc ~sw t ~masc_method:"masc_claim_next"
    ~arguments:[("agent_name", `String t.agent_name)]

let set_current_task ~sw t ~task_id =
  call_rpc ~sw t ~masc_method:"masc_plan_set_task"
    ~arguments:[
      ("task_id", `String task_id);
    ]

let done_task ~sw t ~task_id =
  call_rpc ~sw t ~masc_method:"masc_done"
    ~arguments:[
      ("agent_name", `String t.agent_name);
      ("task_id", `String task_id);
    ]

let release_task ~sw t ~task_id =
  call_rpc ~sw t ~masc_method:"masc_release"
    ~arguments:[
      ("agent_name", `String t.agent_name);
      ("task_id", `String task_id);
    ]

let cancel_task ~sw t ~task_id ~reason =
  call_rpc ~sw t ~masc_method:"masc_cancel_task"
    ~arguments:[
      ("agent_name", `String t.agent_name);
      ("task_id", `String task_id);
      ("reason", `String reason);
    ]

(* --- Communication --- *)

let broadcast ~sw t ~message =
  call_rpc ~sw t ~masc_method:"masc_broadcast"
    ~arguments:[
      ("agent_name", `String t.agent_name);
      ("message", `String message);
    ]

(** Send a direct message to a specific agent. Unlike broadcast (room-wide),
    this is private 1:1 delivery. *)
let send_direct ~sw t ~target ~message =
  call_rpc ~sw t ~masc_method:"masc_a2a_delegate"
    ~arguments:[
      ("target_agent", `String target);
      ("task_type", `String "async");
      ("message", `String message);
    ]

(** Subscribe to MASC events. Returns a subscription_id for use with poll_events.
    events: list of event type strings, e.g. ["broadcast"; "task_update"] *)
let subscribe ~sw t ~events =
  let events_json = `List (List.map (fun e -> `String e) events) in
  call_rpc ~sw t ~masc_method:"masc_a2a_subscribe"
    ~arguments:[
      ("agent_name", `String t.agent_name);
      ("events", events_json);
    ]

(** Poll buffered events from an active subscription. *)
let poll_events ~sw t ~subscription_id =
  call_rpc ~sw t ~masc_method:"masc_poll_events"
    ~arguments:[
      ("subscription_id", `String subscription_id);
    ]

(** Send a heartbeat to keep this agent's presence alive in the room. *)
let heartbeat ~sw t =
  call_rpc ~sw t ~masc_method:"masc_heartbeat"
    ~arguments:[
      ("agent_name", `String t.agent_name);
    ]
