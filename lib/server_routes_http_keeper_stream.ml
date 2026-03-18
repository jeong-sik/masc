[@@@warning "-32-33-69"]

open Types
open Server_utils
open Server_auth
open Server_tts_proxy
open Server_dashboard_http

module Mcp_eio = Mcp_server_eio

type keeper_chat_stream_request = {
  name : string;
  message : string;
  models : string list;
}

let keeper_chat_stream_error_json message =
  `Assoc
    [
      ( "error",
        `Assoc [ ("message", `String message) ] );
    ]

let contains_casefold haystack needle =
  let haystack = String.lowercase_ascii haystack in
  let needle = String.lowercase_ascii needle in
  let hlen = String.length haystack in
  let nlen = String.length needle in
  let rec loop idx =
    if nlen = 0 then true
    else if idx + nlen > hlen then false
    else if String.sub haystack idx nlen = needle then true
    else loop (idx + 1)
  in
  loop 0

let keeper_stream_timeout_sec arguments =
  let default_timeout_sec =
    float_of_int
      (Keeper_config.int_of_env_default
         "MASC_TOOL_TIMEOUT_KEEPER_MSG_SEC"
         ~default:45
         ~min_v:10
         ~max_v:300)
  in
  match Safe_ops.json_float_opt "timeout_sec" arguments with
  | None -> default_timeout_sec
  | Some raw when raw <= 0.0 -> default_timeout_sec
  | Some raw ->
      let raw_sec = int_of_float (Float.ceil raw) in
      float_of_int (max 5 (min 300 raw_sec))

let execute_keeper_stream_tool ~sw ~clock ?auth_token:_ state ~agent_name ~arguments =
  let timeout_sec = keeper_stream_timeout_sec arguments in
  let start_time = Eio.Time.now clock in
  let timeout_hit = ref false in
  let success, body =
    try
      Eio.Time.with_timeout_exn clock timeout_sec (fun () ->
          let keeper_ctx : _ Tool_keeper.context =
            {
              config = state.Mcp_server.room_config;
              agent_name;
              sw;
              clock;
              proc_mgr = state.Mcp_server.proc_mgr;
            }
          in
          match Tool_keeper.dispatch keeper_ctx ~name:"masc_keeper_msg" ~args:arguments with
          | Some result -> result
          | None -> (false, "masc_keeper_msg dispatch unavailable"))
    with
    | Eio.Cancel.Cancelled _ as exn -> raise exn
    | Eio.Time.Timeout ->
        timeout_hit := true;
        Log.Mcp.error "tools/call timeout: masc_keeper_msg after %.0fs" timeout_sec;
        ( false,
          Printf.sprintf
            "❌ Tool timed out after %.0fs: %s (env: MASC_TOOL_TIMEOUT_KEEPER_MSG_SEC)"
            timeout_sec "masc_keeper_msg" )
    | exn ->
        let err = Printexc.to_string exn in
        if contains_casefold err "Invalid_argument(\"MASC not initialized" then
          (false, Types.masc_error_to_string Types.NotInitialized)
        else (
          Log.Mcp.error "tools/call crashed: %s" err;
          (false, Printf.sprintf "❌ Internal error: %s" err))
  in
  let end_time = Eio.Time.now clock in
  let duration_ms = int_of_float ((end_time -. start_time) *. 1000.0) in
  let error_msg =
    if success then None
    else Some
      (Printf.sprintf "timeout=%d|duration_ms=%d"
         (if !timeout_hit then 1 else 0) duration_ms)
  in
  Audit_log.log_tool_call state.Mcp_server.room_config
    ~agent_id:agent_name ~tool_name:"masc_keeper_msg" ~success ~error_msg ();
  let telemetry_enabled =
    match Sys.getenv_opt "MASC_TELEMETRY_ENABLED" with
    | Some "false" | Some "0" -> false
    | _ -> true
  in
  if telemetry_enabled then (
    match state.Mcp_server.fs with
    | Some fs ->
        (try
           Telemetry_eio.track_tool_called ~fs state.Mcp_server.room_config
             ~tool_name:"masc_keeper_msg" ~agent_id:agent_name ~success ~duration_ms ()
         with exn ->
           Log.Misc.error "telemetry tracking failed: %s"
             (Printexc.to_string exn))
    | None -> ()
  );
  Tool_registry.record_call_if_known ~tool_name:"masc_keeper_msg" ~success
    ~duration_ms;
  (success, body)

let parse_keeper_chat_stream_request body_str =
  let open Yojson.Safe.Util in
  try
    let json = Yojson.Safe.from_string body_str in
    if not (match json with `Assoc _ -> true | _ -> false) then
      Error "request body must be a JSON object"
    else
      let name = json |> member "name" |> to_string_option |> Option.value ~default:"" |> String.trim in
      let message =
        json |> member "message" |> to_string_option |> Option.value ~default:""
        |> String.trim
      in
      let models =
        match json |> member "models" with
        | `Null -> Ok []
        | `List items ->
            let rec collect acc = function
              | [] -> Ok (List.rev acc)
              | `String model :: rest ->
                  let trimmed = String.trim model in
                  if trimmed = "" then
                    Error "models must be an array of non-empty strings"
                  else
                    collect (trimmed :: acc) rest
              | _ -> Error "models must be an array of non-empty strings"
            in
            collect [] items
        | _ -> Error "models must be an array of strings"
      in
      if name = "" then
        Error "name is required"
      else if message = "" then
        Error "message is required"
      else
        Result.map (fun models -> { name; message; models }) models
  with Yojson.Json_error e ->
    Error ("invalid json: " ^ e)

let strip_keeper_visible_reply (reply : string) =
  reply
  |> Keeper_alerting.strip_skill_route_lines
  |> Keeper_execution.strip_state_blocks_text
  |> String.trim

let split_keeper_reply_chunks (text : string) : string list =
  let len = String.length text in
  if len = 0 then
    []
  else
    let whitespace = function
      | ' ' | '\n' | '\t' -> true
      | _ -> false
    in
    let chunks = ref [] in
    let start = ref 0 in
    let last_space = ref None in
    let push stop =
      if stop > !start then
        chunks := String.sub text !start (stop - !start) :: !chunks;
      start := stop;
      last_space := None
    in
    for i = 0 to len - 1 do
      let ch = text.[i] in
      if ch = ' ' then last_space := Some i;
      let next_is_boundary =
        i + 1 >= len || whitespace text.[i + 1]
      in
      let hard_wrap =
        i - !start >= 180
        &&
        match !last_space with
        | Some idx -> idx > !start
        | None -> false
      in
      let should_break =
        (match ch with
         | '.' | '!' | '?' -> next_is_boundary
         | '\n' -> i + 1 < len && text.[i + 1] = '\n'
         | _ -> false)
        || hard_wrap
      in
      if should_break then
        match !last_space with
        | Some idx when hard_wrap -> push (idx + 1)
        | _ -> push (i + 1)
    done;
    if !start < len then
      chunks := String.sub text !start (len - !start) :: !chunks;
    List.rev !chunks |> List.filter (fun chunk -> String.trim chunk <> "")

let keeper_stream_send_raw writer mutex closed data =
  if !closed || Httpun.Body.Writer.is_closed writer then begin
    closed := true;
    false
  end else
    try
      Eio.Mutex.use_rw ~protect:true mutex (fun () ->
          Httpun.Body.Writer.write_string writer data;
          Httpun.Body.Writer.flush writer (fun _ -> ()));
      true
    with exn ->
      Log.Keeper.warn "keeper_stream_send_raw write failed: %s" (Printexc.to_string exn);
      closed := true;
      false

let keeper_stream_send_event writer mutex closed event =
  keeper_stream_send_raw writer mutex closed (Ag_ui.event_to_sse event)

(** Execute keeper dispatch with real-time streaming.
    Calls [dispatch_stream] which forwards LLM text deltas to [on_text_delta].
    Returns the same [(bool, string)] result as the batch path.
    Includes timeout, audit, and telemetry — same bookkeeping as the batch path. *)
let execute_keeper_stream_tool_streaming ~sw ~clock ?auth_token:_ state
    ~agent_name ~arguments ~on_text_delta =
  let timeout_sec = keeper_stream_timeout_sec arguments in
  let start_time = Eio.Time.now clock in
  let timeout_hit = ref false in
  let success, body =
    try
      Eio.Time.with_timeout_exn clock timeout_sec (fun () ->
          let keeper_ctx : _ Tool_keeper.context =
            {
              config = state.Mcp_server.room_config;
              agent_name;
              sw;
              clock;
              proc_mgr = state.Mcp_server.proc_mgr;
            }
          in
          match
            Tool_keeper.dispatch_stream ~on_text_delta keeper_ctx
              ~name:"masc_keeper_msg" ~args:arguments
          with
          | Some result -> result
          | None -> (false, "masc_keeper_msg stream dispatch unavailable"))
    with
    | Eio.Cancel.Cancelled _ as exn -> raise exn
    | Eio.Time.Timeout ->
        timeout_hit := true;
        Log.Mcp.error "tools/call timeout: masc_keeper_msg (stream) after %.0fs"
          timeout_sec;
        ( false,
          Printf.sprintf
            "Tool timed out after %.0fs: %s (env: MASC_TOOL_TIMEOUT_KEEPER_MSG_SEC)"
            timeout_sec "masc_keeper_msg" )
    | exn ->
        let err = Printexc.to_string exn in
        if contains_casefold err "Invalid_argument(\"MASC not initialized" then
          (false, Types.masc_error_to_string Types.NotInitialized)
        else (
          Log.Mcp.error "tools/call crashed (stream): %s" err;
          (false, Printf.sprintf "Internal error: %s" err))
  in
  let end_time = Eio.Time.now clock in
  let duration_ms = int_of_float ((end_time -. start_time) *. 1000.0) in
  let error_msg =
    if success then None
    else
      Some
        (Printf.sprintf "timeout=%d|duration_ms=%d"
           (if !timeout_hit then 1 else 0)
           duration_ms)
  in
  Audit_log.log_tool_call state.Mcp_server.room_config ~agent_id:agent_name
    ~tool_name:"masc_keeper_msg" ~success ~error_msg ();
  let telemetry_enabled =
    match Sys.getenv_opt "MASC_TELEMETRY_ENABLED" with
    | Some "false" | Some "0" -> false
    | _ -> true
  in
  if telemetry_enabled then (
    match state.Mcp_server.fs with
    | Some fs ->
        (try
           Telemetry_eio.track_tool_called ~fs state.Mcp_server.room_config
             ~tool_name:"masc_keeper_msg" ~agent_id:agent_name ~success
             ~duration_ms ()
         with exn ->
           Log.Misc.error "telemetry tracking failed: %s"
             (Printexc.to_string exn))
    | None -> ());
  Tool_registry.record_call_if_known ~tool_name:"masc_keeper_msg" ~success
    ~duration_ms;
  (success, body)

(** Send a Run_error AG-UI event with the given message. *)
let send_keeper_error writer mutex closed ~thread_id ~run_id err =
  ignore
    (keeper_stream_send_event writer mutex closed
       Ag_ui.(
         make_event ~thread_id ~run_id:(Some run_id)
           ~custom_name:(Some "KEEPER_CHAT_ERROR")
           ~custom_value:(Some (`Assoc [ ("message", `String err) ]))
           Run_error))

(** Send Text_message_end + Run_finished sequence to complete the stream. *)
let send_keeper_stream_finish writer mutex closed ~thread_id ~run_id
    ~message_id =
  ignore
    (keeper_stream_send_event writer mutex closed
       Ag_ui.(
         make_event ~thread_id ~run_id:(Some run_id)
           ~message_id:(Some message_id) Text_message_end));
  ignore
    (keeper_stream_send_event writer mutex closed
       Ag_ui.(make_event ~thread_id ~run_id:(Some run_id) Run_finished))

(** Extract visible reply from the keeper pipeline result body.
    Parses JSON if possible and strips internal markers. *)
let extract_visible_reply body =
  let payload_json_opt =
    try Some (Yojson.Safe.from_string body)
    with Yojson.Json_error _ -> None
  in
  let visible_reply =
    match payload_json_opt with
    | Some payload_json ->
        let reply_raw =
          payload_json
          |> Yojson.Safe.Util.member "reply"
          |> Yojson.Safe.Util.to_string_option
          |> Option.value ~default:""
        in
        let visible =
          if String.trim reply_raw = "" then String.trim body
          else strip_keeper_visible_reply reply_raw
        in
        if visible = "" then
          Option.value ~default:"(empty reply)"
            (Yojson.Safe.Util.to_string_option payload_json)
        else visible
    | None ->
        let visible = strip_keeper_visible_reply body in
        if visible = "" then "(empty reply)" else visible
  in
  (payload_json_opt, visible_reply)

let handle_keeper_chat_stream ~sw ~clock state request reqd payload =
  let origin = get_origin request in
  let headers =
    Httpun.Headers.of_list
      ([
         ("content-type", "text/event-stream");
         ("cache-control", "no-cache");
         ("connection", "keep-alive");
         ("x-accel-buffering", "no");
       ]
      @ cors_headers origin)
  in
  let response = Httpun.Response.create ~headers `OK in
  let writer = Httpun.Reqd.respond_with_streaming reqd response in
  let mutex = Eio.Mutex.create () in
  let closed = ref false in
  let close_stream () =
    if not !closed then begin
      closed := true;
      (try Httpun.Body.Writer.close writer
       with exn ->
         Log.Misc.warn "keeper_stream writer close: %s"
           (Printexc.to_string exn))
    end
  in
  let now_id () = int_of_float (Time_compat.now () *. 1000.0) in
  let thread_id = "keeper:" ^ payload.name in
  let run_id = Printf.sprintf "keeper-run-%d" (now_id ()) in
  let message_id = Printf.sprintf "keeper-msg-%d" (now_id ()) in
  ignore (keeper_stream_send_raw writer mutex closed "retry: 1500\n\n");
  Eio.Fiber.fork ~sw (fun () ->
      Fun.protect ~finally:close_stream (fun () ->
          (* --- 1. Lifecycle: Run_started + Text_message_start --- *)
          ignore
            (keeper_stream_send_event writer mutex closed
               Ag_ui.(
                 make_event ~thread_id ~run_id:(Some run_id) Run_started));
          ignore
            (keeper_stream_send_event writer mutex closed
               Ag_ui.(
                 make_event ~thread_id ~run_id:(Some run_id)
                   ~message_id:(Some message_id)
                   ~role:(Some Assistant) Text_message_start));
          let args =
            `Assoc
              ([ ("name", `String payload.name);
                 ("message", `String payload.message) ]
              @
              (if payload.models = [] then []
               else
                 [ ("models",
                    `List
                      (List.map
                         (fun model -> `String model)
                         payload.models)) ]))
          in
          let agent_name =
            match agent_from_request request with
            | Some raw when String.trim raw <> "" -> String.trim raw
            | _ -> "unknown"
          in
          (* Track whether any text deltas were streamed to the client.
             When streaming is active, the LLM text is sent token-by-token
             during the call; we only need to send the final batch chunks
             if no deltas were emitted (fallback path). *)
          let deltas_sent = ref false in
          let on_text_delta text =
            if String.length text > 0 then begin
              deltas_sent := true;
              ignore
                (keeper_stream_send_event writer mutex closed
                   Ag_ui.(
                     make_event ~thread_id ~run_id:(Some run_id)
                       ~message_id:(Some message_id)
                       ~delta:(Some text) Text_message_content))
            end
          in

          (* --- 2. Try real streaming path first --- *)
          let dispatch_result =
            try
              Ok
                (execute_keeper_stream_tool_streaming ~sw ~clock
                   ?auth_token:(auth_token_from_request request)
                   state ~agent_name ~arguments:args ~on_text_delta)
            with exn ->
              Log.Keeper.warn
                "keeper_stream: streaming dispatch raised: %s"
                (Printexc.to_string exn);
              (* --- 3. Fallback to batch on exception --- *)
              (try
                 Ok
                   (execute_keeper_stream_tool ~sw ~clock
                      ?auth_token:(auth_token_from_request request)
                      state ~agent_name ~arguments:args)
               with exn2 -> Error (Printexc.to_string exn2))
          in
          match dispatch_result with
          | Error err ->
              send_keeper_error writer mutex closed ~thread_id ~run_id err
          | Ok (false, err) ->
              send_keeper_error writer mutex closed ~thread_id ~run_id err
          | Ok (true, body) -> (
              try
                let payload_json_opt, visible_reply =
                  extract_visible_reply body
                in
                (* If no deltas were streamed during the LLM call
                   (batch fallback or tool-call-only response),
                   send the visible reply as chunked content now. *)
                if not !deltas_sent then
                  split_keeper_reply_chunks visible_reply
                  |> List.iter (fun chunk ->
                         ignore
                           (keeper_stream_send_event writer mutex closed
                              Ag_ui.(
                                make_event ~thread_id
                                  ~run_id:(Some run_id)
                                  ~message_id:(Some message_id)
                                  ~delta:(Some chunk)
                                  Text_message_content)));
                (* Always send the structured reply details *)
                (match payload_json_opt with
                 | Some payload_json ->
                     ignore
                       (keeper_stream_send_event writer mutex closed
                          Ag_ui.(
                            make_event ~thread_id ~run_id:(Some run_id)
                              ~custom_name:(Some "KEEPER_REPLY_DETAILS")
                              ~custom_value:(Some payload_json) Custom))
                 | None -> ());
                send_keeper_stream_finish writer mutex closed ~thread_id
                  ~run_id ~message_id
              with exn ->
                send_keeper_error writer mutex closed ~thread_id ~run_id
                  (Printexc.to_string exn))))

(** Build routes for MCP server *)
