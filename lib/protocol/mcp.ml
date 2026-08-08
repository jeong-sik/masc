(** MCP (Model Context Protocol) client.

    Uses a tolerant NDJSON-over-stdio client for runtime interop while
    keeping the pure SDK bridge helpers for tests. This lets OAS talk to
    MCP servers that paginate [tools/list] and add non-standard fields. *)

open Types
open Result_syntax
include Mcp_schema
module Sdk_client = Mcp_protocol_eio.Client

(* ── Eio stdio transport client ──────────────────────────────────── *)

type t =
  { client : Sdk_client.t
  ; kill : unit -> unit
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
let connect ~sw ~(mgr : _ Eio.Process.mgr) ~command ~args ?env () =
  try
    let r_child_stdin, w_child_stdin = Eio_unix.pipe sw in
    let r_child_stdout, w_child_stdout = Eio_unix.pipe sw in
    let proc =
      Eio.Process.spawn
        ~sw
        mgr
        ~stdin:(r_child_stdin :> Eio.Flow.source_ty Eio.Resource.t)
        ~stdout:(w_child_stdout :> Eio.Flow.sink_ty Eio.Resource.t)
        ?env
        (command :: args)
    in
    Eio.Flow.close r_child_stdin;
    Eio.Flow.close w_child_stdout;
    let client =
      Sdk_client.create
        ~stdin:(r_child_stdout :> _ Eio.Flow.source)
        ~stdout:(w_child_stdin :> _ Eio.Flow.sink)
        ()
    in
    let kill () =
      try Eio.Process.signal proc Sys.sigterm with
      | Unix.Unix_error _ | Eio.Io _ | Sys_error _ -> ()
    in
    Ok { client; kill }
  with
  | Eio.Io _ as exn ->
    Error (Error.Mcp (ServerStartFailed { command; detail = Printexc.to_string exn }))
  | Unix.Unix_error _ as exn ->
    Error (Error.Mcp (ServerStartFailed { command; detail = Printexc.to_string exn }))
  | Failure msg -> Error (Error.Mcp (ServerStartFailed { command; detail = msg }))
;;

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

let initialize t =
  match
    Sdk_client.initialize t.client ~client_name:"oas-mcp-client" ~client_version:"0.10.0"
  with
  | Ok _ -> Ok ()
  | Error detail -> Error (Error.Mcp (InitializeFailed { detail }))
;;

(** Fetch tools from MCP server and return them. *)
let list_tools t =
  match Sdk_client.list_tools_all t.client with
  | Error detail -> Error (Error.Mcp (ToolListFailed { detail }))
  | Ok tools -> Ok (List.map mcp_tool_of_sdk_tool tools)
;;

let decode_items field decode result_json =
  let open Yojson.Safe.Util in
  match result_json |> member field with
  | `List items ->
    let rec loop acc = function
      | [] -> Ok (List.rev acc)
      | item :: rest ->
        (match decode item with
         | Ok value -> loop (value :: acc) rest
         | Error detail ->
           Error
             (Error.Serialization
                (JsonParseError
                   { detail = Printf.sprintf "MCP %s decode failed: %s" field detail })))
    in
    loop [] items
  | _ -> Ok []
;;

let list_resources t =
  match Sdk_client.list_resources_all t.client with
  | Error detail -> Error (Error.Mcp (ToolListFailed { detail }))
  | Ok resources -> Ok resources
;;

let read_resource t ~uri =
  match Sdk_client.read_resource t.client ~uri with
  | Error detail -> Error (Error.Mcp (ToolCallFailed { tool_name = uri; detail }))
  | Ok contents -> Ok contents
;;

let list_prompts t =
  match Sdk_client.list_prompts_all t.client with
  | Error detail -> Error (Error.Mcp (ToolListFailed { detail }))
  | Ok prompts -> Ok prompts
;;

let get_prompt t ~name ?(arguments = []) () =
  match Sdk_client.get_prompt t.client ~name ~arguments () with
  | Ok prompt_result -> Ok prompt_result
  | Error detail -> Error (Error.Mcp (ToolCallFailed { tool_name = name; detail }))
;;

(** Invoke a tool on the MCP server.
    Returns the concatenated text content on success. *)
let call_tool t ~name ~arguments : Types.tool_result =
  match Sdk_client.call_tool t.client ~name ~arguments () with
  | Error detail ->
    Error
      { message = Printf.sprintf "MCP tools/call '%s' failed: %s" name detail
      ; recoverable = true
      ; error_class = None
      }
  | Ok result ->
    let text = text_of_tool_result result in
    if Option.value ~default:false result.Sdk_types.is_error
    then Error { message = text; recoverable = true; error_class = None }
    else Ok { content = text; _meta = None }
;;

(** Convert MCP tools to SDK [Tool.t] list.
    Each tool's handler delegates to {!call_tool} on [t]. *)
let to_tools t (tools : mcp_tool list) =
  let schema_error detail =
    Error.Config (InvalidConfig { field = "mcp.tools"; detail })
  in
  List.fold_right
    (fun (mt : mcp_tool) acc ->
       let* tools = acc in
       let call_fn input = call_tool t ~name:mt.name ~arguments:input in
       match mcp_tool_to_sdk_tool_result ~call_fn mt with
       | Ok tool_ -> Ok (tool_ :: tools)
       | Error detail -> Error (schema_error detail))
    tools
    (Ok [])
;;

(** Check if the MCP server subprocess is still responsive.
    Sends a [ping] request and returns [true] if a response arrives. *)
let is_alive t =
  try
    match Sdk_client.ping t.client with
    | Ok _ -> true
    | Error _ -> false
  with
  | End_of_file | Eio.Io _ | Unix.Unix_error _ | Failure _ -> false
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

let close t =
  close_with_release
    ~close_client:(fun () -> Sdk_client.close t.client)
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

(* ── Managed lifecycle ─────────────────────────────────────────── *)

(** Server start specification.
    [command] is the executable, [args] its arguments.
    [env] contains explicit overrides applied to the inherited process
    environment. [name] identifies the server. OAS passes the caller's argv
    unchanged and does not infer command meaning. *)
type server_spec =
  { command : string
  ; args : string list
  ; env : (string * string) list
  ; name : string
  }

(** Transport backend for a managed MCP connection. *)
type transport =
  | Stdio of
      { client : t
      ; spec : server_spec
      }
  | Http of
      { close_fn : unit -> unit
      ; base_url : string
      ; headers : (string * string) list
      }

(** A connected MCP server together with its converted SDK tools. *)
type managed =
  { tools : Tool.t list
  ; name : string
  ; transport : transport
  }

(** Merge extra key-value pairs into the current process environment.
    Existing keys listed in [extras] are overridden. *)
let merge_env extras =
  if extras = []
  then Unix.environment ()
  else (
    let extra_keys = List.map fst extras in
    let base_filtered =
      Array.to_list (Unix.environment ())
      |> List.filter (fun entry ->
        let key =
          match String.split_on_char '=' entry with
          | k :: _ -> k
          | [] -> ""
        in
        not (List.mem key extra_keys))
    in
    let extra_entries = List.map (fun (k, v) -> k ^ "=" ^ v) extras in
    Array.of_list (base_filtered @ extra_entries))
;;

(** Close a single managed MCP connection (transport-aware). *)
let close_managed m =
  match m.transport with
  | Stdio { client; _ } ->
    (try close client with
     | Eio.Io _ | Unix.Unix_error _ | Failure _ -> ())
  | Http { close_fn; _ } ->
    (try close_fn () with
     | Eio.Io _ | Unix.Unix_error _ | Failure _ -> ())
;;

(** Close all managed MCP server connections.
    Exceptions from individual servers are swallowed (best-effort). *)
let close_all managed_list = List.iter close_managed managed_list

(** Connect to an MCP server, perform the initialize handshake, fetch
    tools, and convert them to SDK [Tool.t] values.
    On any failure the subprocess is closed before returning [Error]. *)
let connect_and_load ~sw ~mgr (spec : server_spec) =
  Llm_provider.Diag.info "mcp" "spawn %s: args=%d" spec.name (List.length spec.args);
  let env = merge_env spec.env in
  match connect ~sw ~mgr ~command:spec.command ~args:spec.args ~env () with
  | Error e -> Error e
  | Ok client ->
    (try
       match initialize client with
       | Error e ->
         close client;
         Error e
       | Ok () ->
         (match list_tools client with
          | Error e ->
            close client;
            Error e
          | Ok mcp_tools ->
            (match to_tools client mcp_tools with
             | Ok tools ->
               Ok { tools; name = spec.name; transport = Stdio { client; spec } }
             | Error e ->
               close client;
               Error e))
     with
     | Out_of_memory ->
       close client;
       raise Out_of_memory
     | Stack_overflow ->
       close client;
       raise Stack_overflow
     | Sys.Break ->
       close client;
       raise Sys.Break
     | exn ->
       close client;
       Error
         (Error.Mcp
            (InitializeFailed
               { detail =
                   Printf.sprintf "MCP server '%s': %s" spec.name (Printexc.to_string exn)
               })))
;;

(** Connect to multiple MCP servers sequentially.
    If any server fails, all previously-connected servers are closed
    and the first error is returned. *)
let connect_all ~sw ~mgr specs =
  let rec loop acc = function
    | [] -> Ok (List.rev acc)
    | spec :: rest ->
      (match connect_and_load ~sw ~mgr spec with
       | Error e ->
         close_all (List.rev acc);
         Error e
       | Ok m -> loop (m :: acc) rest)
  in
  loop [] specs
;;

(** Reconnect a managed MCP server by closing the old connection
    and starting a fresh one from its spec.
    Returns the new managed value on success.
    Only stdio transports can be reconnected (HTTP has no persistent spec). *)
let reconnect ~sw ~mgr (m : managed) =
  match m.transport with
  | Stdio { client; spec } ->
    (try close client with
     | Eio.Io _ | Unix.Unix_error _ | Failure _ -> ());
    connect_and_load ~sw ~mgr spec
  | Http _ ->
    Error
      (Error.Mcp
         (InitializeFailed
            { detail = Printf.sprintf "Cannot reconnect HTTP MCP server '%s'" m.name }))
;;

(** Connect to multiple MCP servers, returning all that succeed.
    Failed servers are reported in the second element of the pair
    but do not prevent other servers from connecting. *)
let connect_all_best_effort ~sw ~mgr specs =
  let rec loop ok_acc err_acc = function
    | [] -> List.rev ok_acc, List.rev err_acc
    | spec :: rest ->
      (match connect_and_load ~sw ~mgr spec with
       | Error e -> loop ok_acc ((spec.name, e) :: err_acc) rest
       | Ok m -> loop (m :: ok_acc) err_acc rest)
  in
  loop [] [] specs
;;

[@@@coverage off]
(* === Inline tests === *)

let test_tool_result ?is_error ?structured_content content =
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

let%test "merge_env empty extras returns environment unchanged" =
  let env = merge_env [] in
  Array.length env = Array.length (Unix.environment ())
;;

let%test "merge_env adds new entries" =
  let env = merge_env [ "__OAS_TEST_VAR_INLINE__", "test_value" ] in
  Array.exists (fun entry -> entry = "__OAS_TEST_VAR_INLINE__=test_value") env
;;

let%test "merge_env overrides existing keys" =
  let env = merge_env [ "PATH", "/override/path" ] in
  let path_entries =
    Array.to_list env
    |> List.filter (fun e -> String.length e >= 5 && String.sub e 0 5 = "PATH=")
  in
  match path_entries with
  | [ entry ] -> entry = "PATH=/override/path"
  | _ -> false
;;

let%test "decode_items empty list returns Ok []" =
  let json = `Assoc [ "items", `List [] ] in
  decode_items "items" (fun _ -> Ok "x") json = Ok []
;;

let%test "decode_items missing field returns Ok []" =
  let json = `Assoc [] in
  decode_items "items" (fun _ -> Ok "x") json = Ok []
;;

let%test "decode_items decodes successfully" =
  let json = `Assoc [ "items", `List [ `String "a"; `String "b" ] ] in
  match
    decode_items
      "items"
      (fun j ->
         match j with
         | `String s -> Ok s
         | _ -> Error "bad")
      json
  with
  | Ok [ "a"; "b" ] -> true
  | _ -> false
;;

let%test "decode_items propagates decode error" =
  let json = `Assoc [ "items", `List [ `Int 42 ] ] in
  match decode_items "items" (fun _ -> Error "decode failed") json with
  | Error _ -> true
  | Ok _ -> false
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

let%test "decode_items with single successful item" =
  let json = `Assoc [ "items", `List [ `String "only" ] ] in
  match
    decode_items
      "items"
      (fun j ->
         match j with
         | `String s -> Ok s
         | _ -> Error "bad")
      json
  with
  | Ok [ "only" ] -> true
  | _ -> false
;;

let%test "decode_items field is not a list returns Ok []" =
  let json = `Assoc [ "items", `String "not a list" ] in
  decode_items "items" (fun _ -> Ok "x") json = Ok []
;;

let%test "merge_env multiple overrides" =
  let env = merge_env [ "__OAS_TEST_A__", "val_a"; "__OAS_TEST_B__", "val_b" ] in
  Array.exists (fun e -> e = "__OAS_TEST_A__=val_a") env
  && Array.exists (fun e -> e = "__OAS_TEST_B__=val_b") env
;;
