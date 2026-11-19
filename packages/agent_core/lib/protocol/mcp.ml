(** MCP (Model Context Protocol) client.

    Uses a tolerant NDJSON-over-stdio client for runtime interop while
    keeping the pure SDK bridge helpers for tests. This lets AGENT_CORE talk to
    MCP servers that paginate [tools/list] and add non-standard fields. *)

include Mcp_schema
module Stdio_transport = struct
  module Transport = Mcp_protocol_eio.Stdio_transport
  type t =
    { transport : Transport.t
    ; max_size : int option
    }
  let create ~stdin ~stdout ?max_size () =
    {transport = Transport.create ~stdin ~stdout ?max_size (); max_size}
  let close t = Transport.close t.transport
  let read t =
    try Transport.read t.transport with
    | Eio.Buf_read.Buffer_limit_exceeded ->
      close t;
      Some (Error "MCP response exceeds the connection's byte limit")
    | Stack_overflow ->
      close t;
      Some (Error "MCP response nesting exceeds the parser's capacity")
  ;;
  let write t msg =
    let module J = Mcp_protocol.Jsonrpc in
    let fits msg = Option.fold ~none:true ~some:(fun max_size ->
      String.length (Yojson.Safe.to_string (J.message_to_yojson msg)) <= max_size) t.max_size in
    let refuse () = close t; Error "MCP outgoing message exceeds the connection's byte limit" in
    let fallback id =
      let reply = J.make_error ~id ~code:(-32603)
        ~message:"response exceeds byte limit" () in
      if fits reply then Transport.write t.transport reply else refuse () in
    try
      match msg with
      | J.Request _ | J.Notification _ -> Transport.write t.transport msg
      | J.Response _ | J.Error _ when fits msg -> Transport.write t.transport msg
      | J.Response response -> fallback response.id
      | J.Error response -> fallback response.id
    with Stack_overflow | Yojson.Json_error _ | Invalid_argument _ -> refuse ()
end

module Sdk_client = Mcp_protocol_eio.Generic_client.Make (Stdio_transport)

(* ── Eio stdio transport client ──────────────────────────────────── *)

type sampling_handler = Mcp_protocol.Sampling.create_message_params ->
  (Mcp_protocol.Sampling.create_message_result, string) result

let valid_response_limit = function
  | None -> Ok ()
  | Some bytes when bytes > 0 -> Ok ()
  | Some _ -> Error "max_response_bytes must be positive"
;;

module Channel = struct
  type t = Sdk_client.t

  let create ~input ~output ?max_response_bytes ?sampling_handler () =
    match valid_response_limit max_response_bytes with
    | Error detail -> Error detail
    | Ok () ->
      let transport = Stdio_transport.create ~stdin:input ~stdout:output
          ?max_size:max_response_bytes () in
      let client = Sdk_client.create ~transport () in
      let client = match sampling_handler with
        | None -> client
        | Some handler ->
          let guarded_handler params =
            try handler params with
            | Eio.Cancel.Cancelled _ as exn -> raise exn
            | exn -> Error (Printexc.to_string exn) in
          Sdk_client.on_sampling guarded_handler client in
      Ok client

  let initialize t ~client_version =
    match Sdk_client.initialize t ~client_name:"agent-core-mcp-client" ~client_version with
    | Ok _ -> Ok ()
    | Error detail -> Error (Error.Mcp (InitializeFailed { detail }))

  let list_tools_full t =
    match Sdk_client.list_tools t with
    | Error detail -> Error (Error.Mcp (ToolListFailed { detail }))
    | Ok tools -> Ok tools

  let call_tool_full t ~name ~arguments =
    let params = `Assoc [ "name", `String name; "arguments", arguments ] in
    match Sdk_client.send_request t ~method_:Mcp_protocol.Notifications.tools_call ~params () with
    | Error detail -> Error (Error.Mcp (ToolCallFailed { tool_name = name; detail }))
    | Ok json ->
      (match Mcp_protocol.Mcp_types.tool_result_of_yojson json with
       | Error detail -> Error (Error.Mcp (ToolCallFailed { tool_name = name; detail }))
       | Ok result ->
         let result = match json with
           | `Assoc fields ->
             (match List.assoc_opt "structuredContent" fields with
              | Some `Null -> { result with structured_content = Some `Null }
              | Some _ | None -> result)
           | _ -> result in
         Ok result)

  let close = Sdk_client.close
end

type t =
  { channel : Channel.t
  ; kill : unit -> unit
  ; process_id : int
  ; await_exit : unit -> Eio.Process.exit_status
  }

let text_of_tool_result (r : Sdk_types.tool_result) =
  List.filter_map
    (fun (c : Sdk_types.tool_content) ->
       match c with
       | TextContent { text; _ } -> Some text
       | ImageContent _ | AudioContent _ | ResourceContent _ | ResourceLinkContent _ ->
         None)
    r.content
  |> String.concat "\n"
;;

(** Connect to an MCP server by spawning a subprocess via Eio.
    [sw] controls the process lifetime.  [mgr] spawns the child.
    [command] is the executable path, [args] are command-line arguments.
    [env] optionally overrides the process environment. *)
let connect ~sw ~(mgr : _ Eio.Process.mgr) ~command ~args ?env ?cwd
    ?max_response_bytes ?stderr ?sampling_handler () =
  match valid_response_limit max_response_bytes with
  | Error detail -> Error (Error.Mcp (ServerStartFailed { command; detail }))
  | Ok () ->
  try
    let r_child_stdin, w_child_stdin = Eio_unix.pipe sw in
    let r_child_stdout, w_child_stdout = Eio_unix.pipe sw in
    let proc =
      Eio.Process.spawn
        ~sw
        mgr
        ~stdin:(r_child_stdin :> Eio.Flow.source_ty Eio.Resource.t)
        ~stdout:(w_child_stdout :> Eio.Flow.sink_ty Eio.Resource.t)
        ?stderr
        ?env
        ?cwd
        (command :: args)
    in
    Eio.Flow.close r_child_stdin;
    Eio.Flow.close w_child_stdout;
    let kill () =
      try Eio.Process.signal proc Sys.sigterm with
      | Unix.Unix_error _ | Eio.Io _ | Sys_error _ -> ()
    in
    (match Channel.create
        ~input:(r_child_stdout :> Eio.Flow.source_ty Eio.Resource.t)
        ~output:(w_child_stdin :> Eio.Flow.sink_ty Eio.Resource.t)
        ?max_response_bytes ?sampling_handler () with
     | Error detail ->
       kill ();
       Error (Error.Mcp (ServerStartFailed { command; detail }))
     | Ok channel ->
       Ok { channel; kill; process_id = Eio.Process.pid proc;
            await_exit = (fun () -> Eio.Process.await proc) })
  with
  | Eio.Io _ as exn ->
    Error (Error.Mcp (ServerStartFailed { command; detail = Printexc.to_string exn }))
  | Unix.Unix_error _ as exn ->
    Error (Error.Mcp (ServerStartFailed { command; detail = Printexc.to_string exn }))
  | Failure msg -> Error (Error.Mcp (ServerStartFailed { command; detail = msg }))
;;

let process_id t = t.process_id
let await_exit t = t.await_exit ()

let mcp_tool_of_json = function
  | `Assoc fields ->
    let input_schema =
      match List.assoc_opt "inputSchema" fields with
      | Some schema -> schema
      | None ->
        (match List.assoc_opt "input_schema" fields with
         | Some schema -> schema
         | None -> `Assoc [])
    in
    (match List.assoc_opt "name" fields with
     | Some (`String name) ->
       Some
         { name
         ; description =
             (match List.assoc_opt "description" fields with
              | Some (`String s) -> s
              | Some (`Assoc _ | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null)
              | None -> "")
         ; input_schema
         }
     | Some (`Assoc _ | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null) | None
       -> None)
    (* skip tools without a valid name *)
  | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null | `String _ -> None
;;

let initialize t ~client_version =
  Channel.initialize t.channel ~client_version
;;

(** Fetch tools from MCP server and return them. *)
let list_tools_full t =
  Channel.list_tools_full t.channel
;;

let call_tool_full t ~name ~arguments =
  Channel.call_tool_full t.channel ~name ~arguments
;;

(** Close the MCP client and terminate the subprocess. *)
let close_with_release ~close_client ~release ~report_release_failure =
  match close_client () with
  | () -> release ()
  | exception primary_exception ->
    let primary_backtrace = Printexc.get_raw_backtrace () in
    (match release () with
     | () -> ()
     | exception release_exception ->
       let release_backtrace = Printexc.get_raw_backtrace () in
       (match report_release_failure release_exception release_backtrace with
        | () -> ()
        | exception reporter_exception ->
          let reporter_backtrace = Printexc.get_raw_backtrace () in
          Eio.traceln
            "mcp: close release failure reporter raised: %s\n%s; release failure: %s\n%s"
            (Printexc.to_string reporter_exception)
            (Printexc.raw_backtrace_to_string reporter_backtrace)
            (Printexc.to_string release_exception)
            (Printexc.raw_backtrace_to_string release_backtrace)));
    Printexc.raise_with_backtrace primary_exception primary_backtrace
;;

let report_release_failure exception_ backtrace =
  Llm_provider.Diag.error
    "mcp"
    "client close failed and process release also raised: %s\n%s"
    (Printexc.to_string exception_)
    (Printexc.raw_backtrace_to_string backtrace)
;;

let request_stop t = t.kill ()

let close t =
  close_with_release
    ~close_client:(fun () -> Channel.close t.channel)
    ~release:t.kill
    ~report_release_failure
;;

let%test "close attempts process release and preserves the client-close exception" =
  let exception Client_close_raised in
  let exception Release_raised in
  let previous_backtrace_status = Printexc.backtrace_status () in
  Printexc.record_backtrace true;
  Fun.protect
    ~finally:(fun () -> Printexc.record_backtrace previous_backtrace_status)
    (fun () ->
       let calls = ref [] in
       let expected_backtrace = ref None in
       let observed_release = ref None in
       let close_client () =
         calls := "client" :: !calls;
         try raise Client_close_raised with
         | exn ->
           let backtrace = Printexc.get_raw_backtrace () in
           expected_backtrace := Some (Printexc.raw_backtrace_to_string backtrace);
           Printexc.raise_with_backtrace exn backtrace
       in
       let primary_backtrace =
         match
           close_with_release
             ~close_client
             ~release:(fun () ->
               calls := "release" :: !calls;
               raise Release_raised)
             ~report_release_failure:(fun exception_ backtrace ->
               observed_release := Some (exception_, backtrace))
         with
         | () -> None
         | exception Client_close_raised ->
           Some (Printexc.raw_backtrace_to_string (Printexc.get_raw_backtrace ()))
         | exception _ -> None
       in
       List.rev !calls = [ "client"; "release" ]
       && (match !observed_release with
           | Some (Release_raised, backtrace) ->
             String.length (Printexc.raw_backtrace_to_string backtrace) > 0
           | Some _ | None -> false)
       &&
       match !expected_backtrace, primary_backtrace with
       | Some expected, Some observed ->
         String.length expected > 0 && String.starts_with ~prefix:expected observed
       | None, _ | _, None -> false)
;;

[@@@coverage off]
(* === Inline tests === *)

(* Inline-test-only; the release profile strips the tests that call it. *)
let[@warning "-32"] test_tool_result ?is_error ?structured_content content =
  let fields = [ "content", Sdk_types.tool_content_list_to_yojson content ] in
  let fields =
    match is_error with
    | Some b -> ("isError", `Bool b) :: fields
    | None -> fields
  in
  let fields =
    match structured_content with
    | Some json -> ("structuredContent", json) :: fields
    | None -> fields
  in
  match Sdk_types.tool_result_of_yojson (`Assoc fields) with
  | Ok result -> result
  | Error detail -> failwith ("tool_result_of_yojson failed: " ^ detail)
;;

let%test "text_of_tool_result extracts text content" =
  let r : Sdk_types.tool_result =
    test_tool_result
      [ Sdk_types.TextContent { type_ = "text"; text = "hello"; annotations = None }
      ; Sdk_types.TextContent { type_ = "text"; text = "world"; annotations = None }
      ]
  in
  text_of_tool_result r = "hello\nworld"
;;

let%test "text_of_tool_result empty content" =
  let r : Sdk_types.tool_result = test_tool_result [] in
  text_of_tool_result r = ""
;;

let%test "text_of_tool_result preserves large text exactly" =
  let text = String.make 100_000 'x' in
  let r : Sdk_types.tool_result =
    test_tool_result
      [ Sdk_types.TextContent { type_ = "text"; text; annotations = None } ]
  in
  String.equal (text_of_tool_result r) text
;;

let%test "mcp_tool_of_json valid tool" =
  let json =
    `Assoc
      [ "name", `String "test_tool"
      ; "description", `String "A test tool"
      ; "inputSchema", `Assoc [ "type", `String "object" ]
      ]
  in
  match mcp_tool_of_json json with
  | Some tool -> tool.name = "test_tool" && tool.description = "A test tool"
  | None -> false
;;

let%test "mcp_tool_of_json with input_schema variant" =
  let json =
    `Assoc
      [ "name", `String "tool2"; "input_schema", `Assoc [ "type", `String "object" ] ]
  in
  match mcp_tool_of_json json with
  | Some tool ->
    tool.name = "tool2" && tool.input_schema = `Assoc [ "type", `String "object" ]
  | None -> false
;;

let%test "mcp_tool_of_json missing name returns None" =
  let json = `Assoc [ "description", `String "no name" ] in
  mcp_tool_of_json json = None
;;

let%test "mcp_tool_of_json non-assoc returns None" =
  mcp_tool_of_json (`String "bad") = None
;;

let%test "mcp_tool_of_json name not a string returns None" =
  let json = `Assoc [ "name", `Int 42 ] in
  mcp_tool_of_json json = None
;;

let%test "mcp_tool_of_json missing description defaults to empty" =
  let json = `Assoc [ "name", `String "minimal" ] in
  match mcp_tool_of_json json with
  | Some tool -> tool.description = ""
  | None -> false
;;

let%test "mcp_tool_of_json missing schema defaults to empty assoc" =
  let json = `Assoc [ "name", `String "no_schema" ] in
  match mcp_tool_of_json json with
  | Some tool -> tool.input_schema = `Assoc []
  | None -> false
;;

let%test "text_of_tool_result skips non-text content" =
  let r : Sdk_types.tool_result =
    test_tool_result
      [ Sdk_types.ImageContent
          { type_ = "image"; data = "abc"; mime_type = "image/png"; annotations = None }
      ; Sdk_types.TextContent { type_ = "text"; text = "only_text"; annotations = None }
      ]
  in
  text_of_tool_result r = "only_text"
;;

let%test "mcp_tool_of_json description not a string defaults to empty" =
  let json = `Assoc [ "name", `String "tool_desc"; "description", `Int 42 ] in
  match mcp_tool_of_json json with
  | Some tool -> tool.description = ""
  | None -> false
;;
