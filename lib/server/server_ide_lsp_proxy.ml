(** Server IDE LSP Proxy — WebSocket bridge for Language Server Protocol
    with MASC observational overlays.

    Architecture:
    - WebSocket → JSON-RPC dispatcher
    - Per-language LSP process via Lsp_process_manager
    - Promise-based routing via Lsp_message_router
    - MASC annotation overlay via Lsp_overlay_provider
    - Per-connection Eio.Switch.run for scoped lifecycle *)

open Server_auth
open Server_utils
module Http = Http_server_eio
module Ws = Httpun_ws

(** SHA1 for httpun-ws handshake. *)
let sha1 s = Digestif.SHA1.(digest_string s |> to_raw_string)

(** Send text frame via WebSocket. *)
let send_text wsd s =
  let bytes = Bytes.unsafe_of_string s in
  Ws.Wsd.send_bytes ~kind:`Text wsd bytes ~off:0 ~len:(Bytes.length bytes)
;;

(** Read a complete frame payload into a string. *)
let read_frame_text ~len ~on_text payload =
  if len = 0
  then on_text ""
  else (
    let buffer = Bytes.create len in
    let offset = ref 0 in
    let rec schedule () =
      if !offset >= len
      then on_text (Bytes.unsafe_to_string buffer)
      else
        Ws.Payload.schedule_read
          payload
          ~on_eof:(fun () -> on_text (Bytes.sub_string buffer 0 !offset))
          ~on_read:(fun bs ~off ~len:chunk_len ->
            Bigstringaf.blit_to_bytes
              bs
              ~src_off:off
              buffer
              ~dst_off:!offset
              ~len:chunk_len;
            offset := !offset + chunk_len;
            schedule ())
    in
    schedule ())
;;

(** Per-connection state shared across frame handler and relay fibers. *)
type conn_state =
  { sw : Eio.Switch.t
  ; router : Lsp_message_router.t
  ; processes : (string, Lsp_process_manager.lsp_process) Hashtbl.t
  ; wsd : Ws.Wsd.t
  ; base_path : string
  ; proc_mgr : Eio_unix.Process.mgr_ty Eio.Resource.t
  ; workspace_root : string ref
  ; send_mutex : Eio.Mutex.t
  ; spawn_mutex : Eio.Mutex.t
  ; clock : float Eio.Time.clock_ty Eio.Resource.t
  ; on_disconnect : unit Eio.Promise.u
  ; disconnected : bool Atomic.t
  }

let base_path_of_state state = state.Mcp_server.room_config.base_path

(** Signal connection end — resolves the disconnect promise so
    [Eio.Switch.run] exits and cleans up all associated resources. *)
let disconnect cs =
  if Atomic.compare_and_set cs.disconnected false true
  then Eio.Promise.resolve cs.on_disconnect ()
;;

(** Thread-safe send: serializes WebSocket writes across fibers. *)
let send cs msg =
  Eio.Mutex.use_rw ~protect:true cs.send_mutex (fun () -> send_text cs.wsd msg)
;;

(** JSON-RPC request ID — LSP spec allows integer or string. *)
type req_id = Id_int of int | Id_string of string

let id_to_json = function
  | Id_int n -> `Int n
  | Id_string s -> `String s

let req_id_to_int = function
  | Id_int n -> n
  | Id_string s -> Hashtbl.hash s

(** Send JSON-RPC response. *)
let send_response cs id result =
  let resp = `Assoc [ "jsonrpc", `String "2.0"; "id", id_to_json id; "result", result ] in
  send cs (Yojson.Safe.to_string resp)
;;

(** Send JSON-RPC error. *)
let send_error cs id code msg =
  let resp =
    `Assoc
      [ "jsonrpc", `String "2.0"
      ; "id", id_to_json id
      ; "error", `Assoc [ "code", `Int code; "message", `String msg ]
      ]
  in
  send cs (Yojson.Safe.to_string resp)
;;

(** Send JSON-RPC notification (server → client). *)
let send_client_notification cs method_ params =
  let notif =
    `Assoc [ "jsonrpc", `String "2.0"; "method", `String method_; "params", params ]
  in
  send cs (Yojson.Safe.to_string notif)
;;

(** Extract textDocument URI from LSP params. *)
let extract_uri params =
  match params with
  | `Assoc fields ->
    (match List.assoc_opt "textDocument" fields with
     | Some (`Assoc doc) ->
       (match List.assoc_opt "uri" doc with
        | Some (`String uri) -> Some uri
        | _ -> None)
     | _ -> None)
  | _ -> None
;;

(** Decode percent-encoded URI component (e.g. [%20] -> [ ]). *)
let pct_decode s =
  let len = String.length s in
  let buf = Buffer.create len in
  let i = ref 0 in
  while !i < len do
    let c = String.get s !i in
    if c = '%' && !i + 2 < len then begin
      let hex = String.sub s (!i + 1) 2 in
      (match int_of_string_opt ("0x" ^ String.uppercase_ascii hex) with
       | Some byte -> Buffer.add_char buf (Char.chr byte); i := !i + 3
       | None -> Buffer.add_char buf c; incr i)
    end else begin
      Buffer.add_char buf c;
      incr i
    end
  done;
  Buffer.contents buf

(** Resolve file:// URI to relative path from base.
    Strips trailing slash from base and checks directory boundary. *)
let resolve_relative ~base uri =
  let prefix = "file://" in
  if not (String.starts_with ~prefix uri) then Some uri
  else
    let raw = String.sub uri (String.length prefix) (String.length uri - String.length prefix) in
    let full = pct_decode raw in
    let base =
      let len = String.length base in
      if len > 1 && String.get base (len - 1) = '/'
      then String.sub base 0 (len - 1)
      else base
    in
    let base_len = String.length base in
    let full_len = String.length full in
    if not (String.starts_with ~prefix:base full) then Some full
    else if base_len = full_len then Some ""
    else if full_len > base_len && String.get full base_len = '/' then
      Some (String.sub full (base_len + 1) (full_len - base_len - 1))
    else
      Some full
;;

(** Extract client request ID from JSON-RPC message fields. *)
let extract_id fields =
  match List.assoc_opt "id" fields with
  | Some (`Int n) -> Some (Id_int n)
  | Some (`String s) -> Some (Id_string s)
  | _ -> None
;;

(** Extract line (0-based) from LSP position params. *)
let extract_line params =
  match params with
  | `Assoc fields ->
    (match List.assoc_opt "position" fields with
     | Some (`Assoc pos) ->
       (match List.assoc_opt "line" pos with
        | Some (`Int n) -> Some n
        | _ -> None)
     | _ -> None)
  | _ -> None
;;

(** Ensure LSP process exists for a language.
    Spawns + initializes on first use, blocking until ready. *)
let ensure_lsp_process cs lang_id =
  Eio.Mutex.use_rw ~protect:true cs.spawn_mutex (fun () ->
    match Hashtbl.find_opt cs.processes lang_id with
    | Some proc -> Ok proc
    | None ->
      let workspace_root = !(cs.workspace_root) in
      (match Lsp_process_manager.spawn ~sw:cs.sw ~lang_id ~workspace_root cs.proc_mgr with
       | Error err ->
         let msg = Format.asprintf "%a" Lsp_process_manager.pp_spawn_error err in
         Log.Server.warn "LSP spawn failed for %s: %s" lang_id msg;
         Error msg
       | Ok proc ->
         Lsp_message_router.start_response_reader
           ~sw:cs.sw
           cs.router
           proc
           ~on_notification:(fun ~client_id:_ ~method_ params ->
             send_client_notification cs method_ params);
         let init_params =
           `Assoc
             [ "rootUri", `String ("file://" ^ workspace_root)
             ; "rootPath", `String workspace_root
             ; "processId", `Int (Unix.getpid ())
             ; "capabilities", `Assoc []
             ]
         in
         let promise =
           Lsp_message_router.send_request
             cs.router
             proc
             ~method_:"initialize"
             ~params:init_params
             ~client_id:(-1)
         in
         let init_result =
           try
             Ok (Eio.Time.with_timeout_exn cs.clock 10.0 (fun () ->
               Eio.Promise.await promise))
           with Eio.Time.Timeout ->
             Error (Printf.sprintf "LSP initialize timeout for %s (10s)" lang_id)
         in
         (match init_result with
          | Ok (Ok _) ->
            Lsp_message_router.send_notification
              cs.router
              proc
              ~method_:"initialized"
              ~params:(`Assoc []);
            Hashtbl.add cs.processes lang_id proc;
            Log.Server.info "LSP server ready: %s" lang_id;
            Ok proc
          | Ok (Error msg) ->
            Log.Server.warn "LSP initialize failed for %s: %s" lang_id msg;
            Error msg
          | Error msg ->
            Log.Server.warn "LSP initialize timeout for %s" lang_id;
            Error msg)))
;;

(** Forward a request to LSP process, await response, relay to client. *)
let forward_request cs lang_id method_ params id =
  match ensure_lsp_process cs lang_id with
  | Error msg -> send_error cs id (-32603) msg
  | Ok proc ->
    let promise =
      Lsp_message_router.send_request cs.router proc ~method_ ~params ~client_id:(req_id_to_int id)
    in
    (match Eio.Promise.await promise with
     | Ok result -> send_response cs id result
     | Error msg -> send_error cs id (-32603) msg)
;;

(** Forward a notification to LSP process. *)
let forward_notification cs lang_id method_ params =
  match ensure_lsp_process cs lang_id with
  | Error msg -> Log.Server.warn "Cannot forward %s: %s" method_ msg
  | Ok proc -> Lsp_message_router.send_notification cs.router proc ~method_ ~params
;;

(** Handle textDocument/codeLens — merge LSP response with MASC overlays. *)
let handle_codelens cs params id =
  match extract_uri params with
  | None -> send_response cs id (`List [])
  | Some uri ->
    let base = cs.base_path in
    let relative = resolve_relative ~base uri |> Option.value ~default:"" in
    let masc = Lsp_overlay_provider.codelenses ~base_dir:base ~file_path:relative in
    let lang_id = Lsp_process_manager.lang_of_path relative in
    if lang_id = "unknown"
    then send_response cs id (`List masc)
    else (
      match ensure_lsp_process cs lang_id with
      | Error _ -> send_response cs id (`List masc)
      | Ok proc ->
        let promise =
          Lsp_message_router.send_request
            cs.router
            proc
            ~method_:"textDocument/codeLens"
            ~params
            ~client_id:(req_id_to_int id)
        in
        (match Eio.Promise.await promise with
         | Ok (`List items) -> send_response cs id (`List (items @ masc))
         | Ok other -> send_response cs id other
         | Error msg -> send_error cs id (-32603) msg))
;;

(** Handle textDocument/inlayHint — merge LSP response with MASC overlays. *)
let handle_inlay_hint cs params id =
  match extract_uri params with
  | None -> send_response cs id (`List [])
  | Some uri ->
    let base = cs.base_path in
    let relative = resolve_relative ~base uri |> Option.value ~default:"" in
    let masc = Lsp_overlay_provider.inlay_hints ~base_dir:base ~file_path:relative in
    let lang_id = Lsp_process_manager.lang_of_path relative in
    if lang_id = "unknown"
    then send_response cs id (`List masc)
    else (
      match ensure_lsp_process cs lang_id with
      | Error _ -> send_response cs id (`List masc)
      | Ok proc ->
        let promise =
          Lsp_message_router.send_request
            cs.router
            proc
            ~method_:"textDocument/inlayHint"
            ~params
            ~client_id:(req_id_to_int id)
        in
        (match Eio.Promise.await promise with
         | Ok (`List items) -> send_response cs id (`List (items @ masc))
         | Ok other -> send_response cs id other
         | Error msg -> send_error cs id (-32603) msg))
;;

(** Handle textDocument/diagnostic — merge LSP response with MASC diagnostics. *)
let handle_diagnostic cs params id =
  match extract_uri params with
  | None -> send_response cs id (`Assoc [ "items", `List [] ])
  | Some uri ->
    let base = cs.base_path in
    let relative = resolve_relative ~base uri |> Option.value ~default:"" in
    let lang_id = Lsp_process_manager.lang_of_path relative in
    if lang_id = "unknown"
    then (
      let diags =
        Lsp_overlay_provider.diagnostics
          ~base_dir:base
          ~file_path:relative
          ~lsp_diagnostics:[]
      in
      send_response cs id (`Assoc [ "items", `List diags ]))
    else (
      match ensure_lsp_process cs lang_id with
      | Error _ ->
        let diags =
          Lsp_overlay_provider.diagnostics
            ~base_dir:base
            ~file_path:relative
            ~lsp_diagnostics:[]
        in
        send_response cs id (`Assoc [ "items", `List diags ])
      | Ok proc ->
        let promise =
          Lsp_message_router.send_request
            cs.router
            proc
            ~method_:"textDocument/diagnostic"
            ~params
            ~client_id:(req_id_to_int id)
        in
        (match Eio.Promise.await promise with
         | Ok (`Assoc rfields) ->
           let existing =
             match List.assoc_opt "items" rfields with
             | Some (`List diags) -> diags
             | _ -> []
           in
           let merged =
             Lsp_overlay_provider.diagnostics
               ~base_dir:base
               ~file_path:relative
               ~lsp_diagnostics:existing
           in
           send_response cs id (`Assoc [ "items", `List merged ])
         | Ok other -> send_response cs id other
         | Error msg -> send_error cs id (-32603) msg))
;;

(** Handle textDocument/hover — enrich LSP response with MASC annotations. *)
let handle_hover cs params id =
  match extract_uri params with
  | None -> send_response cs id `Null
  | Some uri ->
    let base = cs.base_path in
    let relative = resolve_relative ~base uri |> Option.value ~default:"" in
    let line = extract_line params |> Option.value ~default:(-1) in
    let lang_id = Lsp_process_manager.lang_of_path relative in
    if lang_id = "unknown"
    then (
      if line >= 0 && Lsp_overlay_provider.has_annotations_at_line ~base_dir:base ~file_path:relative ~line
      then (
        let enriched =
          Lsp_overlay_provider.enrich_hover
            ~base_dir:base
            ~file_path:relative
            ~line
            (`Assoc [ ("contents", `Assoc [ ("kind", `String "markdown"); ("value", `String "") ]) ])
        in
        send_response cs id enriched)
      else send_response cs id `Null)
    else (
      match ensure_lsp_process cs lang_id with
      | Error msg -> send_error cs id (-32603) msg
      | Ok proc ->
        let promise =
          Lsp_message_router.send_request
            cs.router
            proc
            ~method_:"textDocument/hover"
            ~params
            ~client_id:(req_id_to_int id)
        in
        (match Eio.Promise.await promise with
         | Ok result ->
           if line >= 0
           then
             send_response cs id
               (Lsp_overlay_provider.enrich_hover
                  ~base_dir:base
                  ~file_path:relative
                  ~line
                  result)
           else send_response cs id result
         | Error msg -> send_error cs id (-32603) msg))
;;

(** Dispatch an incoming LSP message to the appropriate handler. *)
let dispatch_message cs msg =
  try
    let json = Yojson.Safe.from_string msg in
    match json with
    | `Assoc fields ->
      let method_opt =
        match List.assoc_opt "method" fields with
        | Some (`String m) -> Some m
        | _ -> None
      in
      let params = List.assoc_opt "params" fields |> Option.value ~default:`Null in
      let id = extract_id fields in
      (match method_opt, id with
       (* Client lifecycle *)
       | Some "initialize", Some n ->
         let root_uri =
           match params with
           | `Assoc pf ->
             (match List.assoc_opt "rootUri" pf with
              | Some (`String u) -> u
              | _ -> cs.base_path)
           | _ -> cs.base_path
         in
         let root =
           if String.starts_with ~prefix:"file://" root_uri
           then String.sub root_uri 7 (String.length root_uri - 7)
           else root_uri
         in
         cs.workspace_root := root;
         send_response
           cs
           n
           (`Assoc
               [ ( "capabilities"
                 , `Assoc
                     [ "textDocumentSync", `Int 2
                     ; "completionProvider", `Assoc [ "resolveProvider", `Bool true ]
                     ; "hoverProvider", `Bool true
                     ; "definitionProvider", `Bool true
                     ; "referencesProvider", `Bool true
                     ; "documentHighlightProvider", `Bool true
                     ; "documentSymbolProvider", `Bool true
                     ; "foldingRangeProvider", `Bool true
                     ; "selectionRangeProvider", `Bool true
                     ; "documentLinkProvider", `Bool true
                     ; "codeLensProvider", `Assoc [ "resolveProvider", `Bool false ]
                     ; "inlayHintProvider", `Bool true
                     ; "diagnosticProvider", `Assoc [ "interFileDependencies", `Bool false; "workspaceDiagnostics", `Bool false ]
                     ] )
               ])
       | Some "initialized", _ -> ()
       | Some "shutdown", Some n -> send_response cs n `Null
       | Some "exit", _ -> disconnect cs
       (* MASC-overlay-aware handlers *)
       | Some "textDocument/hover", Some n -> handle_hover cs params n
       | Some "textDocument/codeLens", Some n -> handle_codelens cs params n
       | Some "textDocument/inlayHint", Some n -> handle_inlay_hint cs params n
       | Some "textDocument/diagnostic", Some n -> handle_diagnostic cs params n
       (* File notifications → forward to appropriate LSP process *)
       | Some m, _ when String.starts_with ~prefix:"textDocument/did" m ->
         (match extract_uri params with
          | Some uri ->
            let relative =
              resolve_relative ~base:cs.base_path uri |> Option.value ~default:""
            in
            if String.equal m "textDocument/didSave" then
              Lsp_overlay_provider.invalidate_cache
                ~base_dir:cs.base_path
                ~file_path:relative;
            let lang_id = Lsp_process_manager.lang_of_path relative in
            if lang_id <> "unknown" then forward_notification cs lang_id m params
          | None -> ())
       (* Other requests with textDocument URI → forward to LSP *)
       | Some m, Some n ->
         (match extract_uri params with
          | Some uri ->
            let relative =
              resolve_relative ~base:cs.base_path uri |> Option.value ~default:""
            in
            let lang_id = Lsp_process_manager.lang_of_path relative in
            if lang_id <> "unknown"
            then forward_request cs lang_id m params n
            else send_error cs n (-32801) ("No LSP server for: " ^ relative)
          | None -> send_error cs n (-32601) ("Unhandled method: " ^ m))
       (* Server-initiated notification broadcast *)
       | Some m, None ->
         Hashtbl.iter
           (fun _lang_id proc ->
              Lsp_message_router.send_notification cs.router proc ~method_:m ~params)
           cs.processes
       (* No method field *)
       | None, Some n -> send_error cs n (-32600) "Missing method field"
       | None, None -> ())
    | _ ->
      (match
         extract_id
           (match json with
            | `Assoc f -> f
            | _ -> [])
       with
       | Some n -> send_error cs n (-32700) "Parse error"
       | None -> ())
  with
  | exn -> Log.Server.error "LSP dispatch error: %s" (Printexc.to_string exn)
;;

(** Register the /api/v1/ide/lsp WebSocket endpoint. *)
let add_routes ~sw ~clock router =
  let router =
    Http.Router.get
      "/api/v1/ide/lsp"
      (fun request reqd ->
         with_public_read
           (fun state _req reqd ->
              let origin =
                match Http.Request.header request "origin" with
                | Some o -> o
                | None -> "localhost"
              in
              (match state.Mcp_server.proc_mgr with
               | None -> Log.Server.warn "LSP WebSocket: no proc_mgr available"
               | Some proc_mgr ->
               Ws.Handshake.respond_with_upgrade ~sha1 reqd (fun () ->
                 Eio.Switch.run (fun conn_sw ->
                   let done_promise, done_resolver = Eio.Promise.create () in
                   let ws_conn =
                     Ws.Server_connection.create_websocket (fun wsd ->
                       Log.Server.info "LSP WebSocket connected from %s" origin;
                       let cs =
                         { sw = conn_sw
                         ; router = Lsp_message_router.create ()
                         ; processes = Hashtbl.create 4
                         ; wsd
                         ; base_path = base_path_of_state state
                         ; proc_mgr
                         ; workspace_root = ref (base_path_of_state state)
                         ; send_mutex = Eio.Mutex.create ()
                         ; spawn_mutex = Eio.Mutex.create ()
                         ; clock
                         ; on_disconnect = done_resolver
                         ; disconnected = Atomic.make false
                         }
                      in
                      { Ws.Websocket_connection.frame =
                          (fun ~opcode ~is_fin:_ ~len payload ->
                            match opcode with
                            | `Text | `Binary ->
                              read_frame_text
                                ~len
                                ~on_text:(fun msg -> dispatch_message cs msg)
                                payload
                            | `Ping ->
                              (try Ws.Wsd.send_pong wsd with
                               | exn ->
                                 Log.Server.debug
                                   "LSP send_pong failed: %s"
                                   (Printexc.to_string exn));
                              Ws.Payload.close payload
                            | `Connection_close ->
                              Log.Server.info "LSP WebSocket disconnecting";
                              disconnect cs;
                              Ws.Payload.close payload
                            | `Pong | `Continuation | `Other _ -> Ws.Payload.close payload)
                      ; eof =
                          (fun ?error:_ () ->
                            Log.Server.info "LSP WebSocket EOF";
                            disconnect cs)
                      })
                  in
                  ignore ws_conn;
                  ignore (Eio.Promise.await done_promise)))
              |> function
              | Ok () -> ()
              | Error e -> Log.Server.warn "WebSocket upgrade failed: %s" e))
           request
           reqd)
      router
  in
  router
;;
