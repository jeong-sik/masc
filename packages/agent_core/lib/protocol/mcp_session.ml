(** MCP session persistence — capture and restore server connection info.

    MCP connections (OS process + stdio pipes) cannot be serialized.
    This module captures the serializable parts: server specification
    and discovered tool schemas.  On resume, the caller can reconnect
    using the saved specs.

    Intended lifecycle:
    {[
      (* Before checkpoint *)
      let infos = Mcp_session.capture_all managed_list in
      (* ... serialize infos into checkpoint JSON ... *)

      (* On resume *)
      let managed, failed_with_reasons = Mcp_session.reconnect_all ~sw ~mgr ~net infos in
      List.iter (fun (info, err) ->
        let _log = Log.create ~module_name:"mcp_session" () in
        Log.warn _log "Failed to reconnect"
          [S ("server", info.server_name); S ("error", err)]
      ) failed_with_reasons;
    ]} *)

open Types
open Result_syntax

(** Transport kind tag for serialization. *)
type transport_kind =
  | Stdio
  | Http

(** Serializable MCP session information. *)
type info =
  { server_name : string
  ; command : string (** For HTTP: "http"; for stdio: the executable *)
  ; args : string list (** For HTTP: [url]; for stdio: command-line args *)
  ; env : (string * string) list
  ; http_base_url : string option
  ; http_headers : (string * string) list
  ; tool_schemas : tool_schema list
  ; transport_kind : transport_kind
  }

(** Capture session info from a connected managed server. *)
let capture (m : Mcp.managed) : info =
  let tool_schemas = List.map (fun (t : Tool.t) -> t.schema) m.tools in
  match m.transport with
  | Mcp.Stdio { spec; _ } ->
    { server_name = m.name
    ; command = spec.command
    ; args = spec.args
    ; env = spec.env
    ; http_base_url = None
    ; http_headers = []
    ; tool_schemas
    ; transport_kind = Stdio
    }
  | Mcp.Http { base_url; headers; _ } ->
    { server_name = m.name
    ; command = "http"
    ; args = []
    ; env = []
    ; http_base_url = Some base_url
    ; http_headers = headers
    ; tool_schemas
    ; transport_kind = Http
    }
;;

(** Capture session info from all connected managed servers. *)
let capture_all (managed_list : Mcp.managed list) : info list =
  List.map capture managed_list
;;

(** Convert session info back to a server_spec for reconnection. *)
let to_server_spec (info : info) : Mcp.server_spec =
  { command = info.command; args = info.args; env = info.env; name = info.server_name }
;;

let to_http_spec (info : info) : Mcp_http.http_spec option =
  match info.http_base_url with
  | Some base_url ->
    Some { base_url; headers = info.http_headers; name = info.server_name }
  | None -> None
;;

(** Reconnect to MCP servers from saved session info.
    Returns a pair: (successfully connected, failed infos with error messages).
    Failed connections do not abort the others. *)
let reconnect_all ~sw ~mgr ~net (infos : info list)
  : Mcp.managed list * (info * Error.sdk_error) list
  =
  List.fold_left
    (fun (connected, failed) info ->
       match info.transport_kind with
       | Http ->
         (match to_http_spec info with
          | Some spec ->
            (match Mcp_http.connect_and_load_managed ~sw ~net spec with
             | Ok m -> m :: connected, failed
             | Error e -> connected, (info, e) :: failed)
          | None ->
            let e =
              Error.Mcp
                (InitializeFailed
                   { detail =
                       Printf.sprintf
                         "HTTP MCP server '%s' cannot be reconnected without \
                          http_base_url"
                         info.server_name
                   })
            in
            connected, (info, e) :: failed)
       | Stdio ->
         let spec = to_server_spec info in
         (match Mcp.connect_and_load ~sw ~mgr spec with
          | Ok m -> m :: connected, failed
          | Error e -> connected, (info, e) :: failed))
    ([], [])
    infos
  |> fun (connected, failed) -> List.rev connected, List.rev failed
;;

(* ── JSON serialization ─────────────────────────────────────────── *)

let env_pair_to_json (k, v) = `Assoc [ "key", `String k; "value", `String v ]

let env_pair_of_json json =
  let open Yojson.Safe.Util in
  try Ok (json |> member "key" |> to_string, json |> member "value" |> to_string) with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
    Error
      (Error.Serialization
         (JsonParseError
            { detail = Printf.sprintf "Invalid env pair: %s" (Printexc.to_string exn) }))
;;

let tool_schema_to_json = Types.tool_schema_to_json

let map_str_err r =
  Result.map_error
    (fun s ->
       Error.Serialization (UnknownVariant { type_name = "param_type"; value = s }))
    r
;;

let tool_schema_of_json json = map_str_err (Types.tool_schema_of_json json)

let result_all items =
  List.fold_left
    (fun acc item ->
       let* xs = acc in
       let* x = item in
       Ok (x :: xs))
    (Ok [])
    items
  |> Result.map List.rev
;;

(* ── info JSON ─────────────────────────────────────────────────── *)

let transport_kind_to_string = function
  | Stdio -> "stdio"
  | Http -> "http"
;;

let transport_kind_of_string = function
  | "stdio" -> Ok Stdio
  | "http" -> Ok Http
  | value ->
    Error
      (Error.Serialization
         (UnknownVariant { type_name = "mcp_session.transport_kind"; value }))
;;

let info_to_json (info : info) : Yojson.Safe.t =
  `Assoc
    [ "server_name", `String info.server_name
    ; "command", `String info.command
    ; "args", Util.json_of_string_list info.args
    ; "env", `List (List.map env_pair_to_json info.env)
    ; ( "http_base_url"
      , match info.http_base_url with
        | Some base_url -> `String base_url
        | None -> `Null )
    ; "http_headers", `List (List.map env_pair_to_json info.http_headers)
    ; "tool_schemas", `List (List.map tool_schema_to_json info.tool_schemas)
    ; "transport_kind", `String (transport_kind_to_string info.transport_kind)
    ]
;;

let info_of_json json : (info, Error.sdk_error) result =
  try
    let open Yojson.Safe.Util in
    let* () =
      match json with
      | `Assoc fields when List.mem_assoc "env_policy" fields ->
        Error
          (Error.Serialization
             (JsonParseError
                { detail =
                    "Mcp_session.info_of_json: legacy env_policy is not supported; MCP \
                     subprocesses inherit the caller environment"
                }))
      | `Assoc _ -> Ok ()
      | _ ->
        Error
          (Error.Serialization
             (JsonParseError { detail = "Mcp_session.info_of_json: expected object" }))
    in
    let* env = json |> member "env" |> to_list |> List.map env_pair_of_json |> result_all
    and* http_headers =
      let http_header_items =
        match json |> member "http_headers" with
        | `List items -> items
        | _ -> []
      in
      http_header_items |> List.map env_pair_of_json |> result_all
    and* tool_schemas =
      json
      |> member "tool_schemas"
      |> to_list
      |> List.map tool_schema_of_json
      |> result_all
    in
    let* transport_kind =
      match json |> member "transport_kind" |> to_string_option with
      | Some raw -> transport_kind_of_string raw
      | None ->
        Error
          (Error.Serialization
             (JsonParseError
                { detail = "Mcp_session.info_of_json: missing transport_kind" }))
    in
    let http_base_url = json |> member "http_base_url" |> to_string_option in
    match transport_kind, http_base_url with
    | Http, None ->
      Error
        (Error.Serialization
           (JsonParseError
              { detail = "Mcp_session.info_of_json: HTTP transport requires http_base_url"
              }))
    | _ ->
      Ok
        { server_name = json |> member "server_name" |> to_string
        ; command = json |> member "command" |> to_string
        ; args = json |> member "args" |> to_list |> List.map to_string
        ; env
        ; http_base_url
        ; http_headers
        ; tool_schemas
        ; transport_kind
        }
  with
  | Yojson.Safe.Util.Type_error (msg, _) ->
    Error
      (Error.Serialization
         (JsonParseError { detail = Printf.sprintf "Mcp_session.info_of_json: %s" msg }))
  | Yojson.Json_error msg ->
    Error
      (Error.Serialization
         (JsonParseError { detail = Printf.sprintf "Mcp_session.info_of_json: %s" msg }))
  | Failure msg ->
    Error
      (Error.Serialization
         (JsonParseError { detail = Printf.sprintf "Mcp_session.info_of_json: %s" msg }))
;;

let info_list_to_json (infos : info list) : Yojson.Safe.t =
  `List (List.map info_to_json infos)
;;

let info_list_of_json json : (info list, Error.sdk_error) result =
  try
    let open Yojson.Safe.Util in
    json |> to_list |> List.map info_of_json |> result_all
  with
  | Yojson.Safe.Util.Type_error (msg, _) ->
    Error
      (Error.Serialization
         (JsonParseError
            { detail = Printf.sprintf "Mcp_session.info_list_of_json: %s" msg }))
  | Yojson.Json_error msg ->
    Error
      (Error.Serialization
         (JsonParseError
            { detail = Printf.sprintf "Mcp_session.info_list_of_json: %s" msg }))
  | Failure msg ->
    Error
      (Error.Serialization
         (JsonParseError
            { detail = Printf.sprintf "Mcp_session.info_list_of_json: %s" msg }))
;;
