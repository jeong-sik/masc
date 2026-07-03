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
module Ws_endpoint = Ws_direct_core.Endpoint
module Ws_wsd = Ws_direct_core.Endpoint.Wsd
module Ws_msg = Ws_direct_core.Connection.Message

(** Send text frame via WebSocket. *)
let send_text wsd s = Ws_wsd.send_text wsd s
;;

(** Per-connection state shared across frame handler and relay fibers.

    [sw] is the server-lifetime switch (LSP processes + their reader
    fibers are spawned on it).  Per-connection reclamation is explicit
    via {!disconnect} rather than switch teardown, because under the
    Gluten upgrade model ({!Server_mcp_transport_ws.respond_and_drive_upgrade})
    the upgrade handler cannot block to hold a per-connection switch
    open.  RFC-0281 Phase 2. *)
(** Per-language LSP health (task-1691). A language is [Connected] once its
    LSP process is spawned and initialized; it is [Overlay_only] (carrying the
    last error) when the process could not be started/initialized, so only
    MASC observational overlays are served for that language. Degradation is
    per-language — the whole LSP process is unavailable, not one method — so a
    single state covers every handler. Every degraded handler records this
    instead of either failing the request (old hover) or silently returning
    overlays as if the LSP answered (old 9 handlers + diagnostic), so the
    [masc/lspStatus] notification can report the degradation to the dashboard. *)
type lang_health =
  | Connected
  | Overlay_only of string

type conn_state =
  { sw : Eio.Switch.t
  ; router : Lsp_message_router.t
  ; processes : (string, Lsp_process_manager.lsp_process) Hashtbl.t
  ; health : (string, lang_health) Hashtbl.t
  ; wsd : Ws_wsd.t
  ; base_path : string
  ; proc_mgr : Eio_unix.Process.mgr_ty Eio.Resource.t
  ; workspace_root : string ref
  ; send_mutex : Eio.Mutex.t
  ; spawn_mutex : Eio.Mutex.t
  ; clock : float Eio.Time.clock_ty Eio.Resource.t
  ; disconnected : bool Atomic.t
        (* RFC-0287: fragment reassembly + size caps now live in the ws-direct
           Endpoint, which delivers complete messages to [on_message]; the
           former shared [Ws_inbound] reassembler field is gone. *)
  }

let base_path_of_state state = (Mcp_server.workspace_config state).base_path

(** Signal connection end.  Idempotent (guarded by [disconnected]).

    Explicitly shuts down every spawned LSP process.
    [Lsp_process_manager.shutdown] closes the process stdin/stdout/stderr
    flows, which makes the response-reader and stderr-drain fibers' reads
    raise so those fibers exit — so this reclaims the processes AND their
    fibers without a switch teardown.  Required because [cs.sw] is the
    server switch: without explicit shutdown the processes would leak
    until server shutdown (RFC-0261).  Taken under [spawn_mutex] so it
    cannot race a concurrent {!ensure_lsp_process}.  RFC-0281 Phase 2. *)
let disconnect cs =
  if Atomic.compare_and_set cs.disconnected false true
  then
    Eio.Mutex.use_rw ~protect:true cs.spawn_mutex (fun () ->
      Hashtbl.iter (fun _ proc -> Lsp_process_manager.shutdown proc) cs.processes;
      Hashtbl.clear cs.processes)
;;

(** Thread-safe send: serializes WebSocket writes across fibers. *)
let send cs msg =
  if Atomic.get cs.disconnected
  then ()
  else
    Eio.Mutex.use_rw ~protect:true cs.send_mutex (fun () ->
      if not (Atomic.get cs.disconnected) then send_text cs.wsd msg)
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

(** Send JSON-RPC error. [code] is the wire integer — callers use
    [Mcp_error_code.to_wire_code] for typed codes. *)
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

(* --- LSP health status (task-1691) --- *)

(* Pure projection of one language's health into the [masc/lspStatus] wire
   shape: [connected] / [overlay_only] / [command] (the configured LSP
   executable, [null] when none is mapped) / [last_error] / [last_method]. *)
let lang_status_json ~lang_id (health : lang_health) : Yojson.Safe.t =
  let command =
    match Lsp_process_manager.command_for_lang lang_id with
    | Some (exe, _argv) -> `String exe
    | None -> `Null
  in
  let connected, overlay_only, last_error =
    match health with
    | Connected -> (true, false, `Null)
    | Overlay_only err -> (false, true, `String err)
  in
  `Assoc
    [ "lang", `String lang_id
    ; "connected", `Bool connected
    ; "overlay_only", `Bool overlay_only
    ; "command", command
    ; "last_error", last_error
    ]
;;

(* Pure snapshot of all tracked languages, sorted by lang id for a stable
   wire order. *)
let status_snapshot_json (healths : (string * lang_health) list) : Yojson.Safe.t =
  let sorted = List.sort (fun (a, _) (b, _) -> String.compare a b) healths in
  `Assoc
    [ "langs", `List (List.map (fun (l, h) -> lang_status_json ~lang_id:l h) sorted) ]
;;

let current_status_json cs =
  status_snapshot_json (Hashtbl.fold (fun l h acc -> (l, h) :: acc) cs.health [])
;;

(* Push the current status to the client as a [masc/lspStatus] notification,
   so the dashboard reacts to a health transition without polling. *)
let push_lsp_status cs = send_client_notification cs "masc/lspStatus" (current_status_json cs)

(* Record [lang_id]'s health, notifying the client only when it actually
   changed (so a stream of requests while degraded does not spam
   notifications). *)
let set_health cs ~lang_id health =
  let changed =
    match Hashtbl.find_opt cs.health lang_id with
    | Some prev -> prev <> health
    | None -> true
  in
  Hashtbl.replace cs.health lang_id health;
  if changed then push_lsp_status cs
;;

(* Unified degraded path shared by every overlay handler (task-1691): mark
   the language overlay-only, log a typed WARN, and notify the client. The
   caller then serves its MASC overlay, so the request never fails and the
   keeper cycle is never blocked by an unavailable LSP. *)
let note_overlay_only cs ~lang_id ~error =
  Log.Server.warn "LSP overlay-only for %s: %s" lang_id error;
  set_health cs ~lang_id (Overlay_only error)
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

let strip_trailing_slash path =
  let len = String.length path in
  if len > 1 && String.get path (len - 1) = '/'
  then String.sub path 0 (len - 1)
  else path
;;

let path_of_file_uri uri =
  let prefix = "file://" in
  if String.starts_with ~prefix uri
  then (
    let raw =
      String.sub uri (String.length prefix) (String.length uri - String.length prefix)
    in
    pct_decode raw)
  else uri
;;

let path_within ~base path =
  let base = strip_trailing_slash base in
  let path = strip_trailing_slash path in
  let base_len = String.length base in
  String.equal path base
  || (String.starts_with ~prefix:base path
      && String.length path > base_len
      && Char.equal (String.get path base_len) '/')
;;

let workspace_root_for_initialize ~base_path root_uri =
  let candidate = root_uri |> path_of_file_uri |> strip_trailing_slash in
  let base = strip_trailing_slash base_path in
  if path_within ~base candidate then candidate else base
;;

(** Resolve file:// URI to relative path from base.
    Strips trailing slash from base and checks directory boundary. *)
let resolve_relative ~base uri =
  if not (String.starts_with ~prefix:"file://" uri)
  then Some uri
  else (
    let full = path_of_file_uri uri |> strip_trailing_slash in
    let base = strip_trailing_slash base in
    let base_len = String.length base in
    let full_len = String.length full in
    if not (path_within ~base full)
    then None
    else if base_len = full_len
    then Some ""
    else Some (String.sub full (base_len + 1) (full_len - base_len - 1)))
;;

let initialize_capabilities_json () =
  `Assoc
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
    ; "codeActionProvider", `Bool true
    ; "inlayHintProvider", `Bool true
    ; ( "diagnosticProvider"
      , `Assoc [ "interFileDependencies", `Bool false; "workspaceDiagnostics", `Bool false ]
      )
    ]
;;

let initialize_result_json () =
  `Assoc [ "capabilities", initialize_capabilities_json () ]
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
  if Atomic.get cs.disconnected
  then Error "connection closed"
  else
    Eio.Mutex.use_rw ~protect:true cs.spawn_mutex (fun () ->
      if Atomic.get cs.disconnected
      then Error "connection closed"
      else
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
            set_health cs ~lang_id Connected;
            Log.Server.info "LSP server ready: %s" lang_id;
            Ok proc
          | Ok (Error msg) ->
            Log.Server.warn "LSP initialize failed for %s: %s" lang_id msg;
            Lsp_process_manager.shutdown proc;
            Error msg
          | Error msg ->
            Log.Server.warn "LSP initialize timeout for %s" lang_id;
            Lsp_process_manager.shutdown proc;
            Error msg)))
;;

(** Forward a request to LSP process, await response, relay to client. *)
let forward_request cs lang_id method_ params id =
  match ensure_lsp_process cs lang_id with
  | Error msg ->
    (* No MASC overlay exists for a passthrough method, so this stays a
       JSON-RPC error — but still record the per-language degradation so
       [masc/lspStatus] reflects it (task-1691). *)
    note_overlay_only cs ~lang_id ~error:msg;
    send_error cs id Mcp_error_code.(to_wire_code Internal_error) msg
  | Ok proc ->
    let promise =
      Lsp_message_router.send_request cs.router proc ~method_ ~params ~client_id:(req_id_to_int id)
    in
    (match Eio.Promise.await promise with
     | Ok result -> send_response cs id result
     | Error msg -> send_error cs id Mcp_error_code.(to_wire_code Internal_error) msg)
;;

(** Forward a notification to LSP process. *)
let forward_notification cs lang_id method_ params =
  match ensure_lsp_process cs lang_id with
  | Error msg -> Log.Server.warn "Cannot forward %s: %s" method_ msg
  | Ok proc -> Lsp_message_router.send_notification cs.router proc ~method_ ~params
;;

(* Read-only method allowlist for the catch-all forwarder (task-1692). The
   observation plane must never forward a write-adjacent request — rename,
   any formatting, executeCommand, applyEdit, willSaveWaitUntil — to the
   language server. The overlay methods handled explicitly above (hover,
   codeAction, ...) are all read-only and never reach the catch-all; this
   closes the "forward any other textDocument request" hole.

   Default-deny by a typed variant, not a string-prefix classifier: only a
   listed read method forwards, so a new or unrecognized method is rejected
   rather than silently passed through, and adding a method forces an explicit
   classification (RFC-0194 / workaround §2 — no substring allowlist). *)
type method_disposition =
  | Forward_read_only
  | Reject_write_adjacent

let classify_forwarded_method = function
  | "textDocument/signatureHelp"
  | "textDocument/declaration"
  | "textDocument/typeDefinition"
  | "textDocument/implementation"
  | "textDocument/documentColor"
  | "textDocument/colorPresentation"
  | "textDocument/documentLink"
  | "textDocument/selectionRange"
  | "textDocument/linkedEditingRange"
  | "textDocument/moniker"
  | "textDocument/prepareCallHierarchy"
  | "textDocument/prepareTypeHierarchy"
  | "textDocument/semanticTokens/full"
  | "textDocument/semanticTokens/full/delta"
  | "textDocument/semanticTokens/range" -> Forward_read_only
  (* Everything else — textDocument/rename, prepareRename, formatting,
     rangeFormatting, onTypeFormatting, willSaveWaitUntil,
     workspace/executeCommand, workspace/applyEdit, and any unrecognized
     method — is denied. *)
  | _ -> Reject_write_adjacent
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
      | Error msg ->
        note_overlay_only cs ~lang_id ~error:msg;
        send_response cs id (`List masc)
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
         | Error msg -> send_error cs id Mcp_error_code.(to_wire_code Internal_error) msg))
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
      | Error msg ->
        note_overlay_only cs ~lang_id ~error:msg;
        send_response cs id (`List masc)
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
         | Error msg -> send_error cs id Mcp_error_code.(to_wire_code Internal_error) msg))
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
      | Error msg ->
        note_overlay_only cs ~lang_id ~error:msg;
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
         | Error msg -> send_error cs id Mcp_error_code.(to_wire_code Internal_error) msg))
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
      | Error msg ->
        (* Unified with the other handlers (task-1691): fall back to the MASC
           overlay hover instead of the old JSON-RPC Internal_error, which
           broke the client on an unavailable LSP. Mirrors the unknown-lang
           branch above. *)
        note_overlay_only cs ~lang_id ~error:msg;
        if line >= 0
           && Lsp_overlay_provider.has_annotations_at_line ~base_dir:base
                ~file_path:relative ~line
        then
          send_response cs id
            (Lsp_overlay_provider.enrich_hover ~base_dir:base ~file_path:relative
               ~line
               (`Assoc
                  [ ( "contents"
                    , `Assoc
                        [ ("kind", `String "markdown"); ("value", `String "") ] )
                  ]))
        else send_response cs id `Null
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
         | Error msg -> send_error cs id Mcp_error_code.(to_wire_code Internal_error) msg))
;;

(** Handle textDocument/definition — merge LSP response with MASC annotation links. *)
let handle_definition cs params id =
  match extract_uri params with
  | None -> send_response cs id (`List [])
  | Some uri ->
    let base = cs.base_path in
    let relative = resolve_relative ~base uri |> Option.value ~default:"" in
    let line = extract_line params |> Option.value ~default:(-1) in
    let masc =
      if line >= 0 then
        Lsp_overlay_provider.definition_links ~base_dir:base ~file_path:relative ~line
      else []
    in
    let lang_id = Lsp_process_manager.lang_of_path relative in
    if lang_id = "unknown"
    then send_response cs id (`List masc)
    else (
      match ensure_lsp_process cs lang_id with
      | Error msg ->
        note_overlay_only cs ~lang_id ~error:msg;
        send_response cs id (`List masc)
      | Ok proc ->
        let promise =
          Lsp_message_router.send_request
            cs.router proc
            ~method_:"textDocument/definition"
            ~params ~client_id:(req_id_to_int id)
        in
        (match Eio.Promise.await promise with
         | Ok (`List items) -> send_response cs id (`List (items @ masc))
         | Ok other -> send_response cs id other
         | Error msg -> send_error cs id Mcp_error_code.(to_wire_code Internal_error) msg))
;;

(** Handle textDocument/references — merge LSP response with MASC annotation locations. *)
let handle_references cs params id =
  match extract_uri params with
  | None -> send_response cs id (`List [])
  | Some uri ->
    let base = cs.base_path in
    let relative = resolve_relative ~base uri |> Option.value ~default:"" in
    let line = extract_line params |> Option.value ~default:(-1) in
    let masc =
      if line >= 0 then
        Lsp_overlay_provider.reference_locations
          ~base_dir:base ~file_path:relative ~line ~include_declaration:true
      else []
    in
    let lang_id = Lsp_process_manager.lang_of_path relative in
    if lang_id = "unknown"
    then send_response cs id (`List masc)
    else (
      match ensure_lsp_process cs lang_id with
      | Error msg ->
        note_overlay_only cs ~lang_id ~error:msg;
        send_response cs id (`List masc)
      | Ok proc ->
        let promise =
          Lsp_message_router.send_request
            cs.router proc
            ~method_:"textDocument/references"
            ~params ~client_id:(req_id_to_int id)
        in
        (match Eio.Promise.await promise with
         | Ok (`List items) -> send_response cs id (`List (items @ masc))
         | Ok other -> send_response cs id other
         | Error msg -> send_error cs id Mcp_error_code.(to_wire_code Internal_error) msg))
;;

(** Handle textDocument/completion — merge LSP response with MASC annotation snippets. *)
let handle_completion cs params id =
  match extract_uri params with
  | None -> send_response cs id (`List [])
  | Some uri ->
    let base = cs.base_path in
    let relative = resolve_relative ~base uri |> Option.value ~default:"" in
    let line = extract_line params |> Option.value ~default:(-1) in
    let masc =
      if line >= 0 then
        Lsp_overlay_provider.completion_items ~base_dir:base ~file_path:relative ~line
      else []
    in
    let lang_id = Lsp_process_manager.lang_of_path relative in
    if lang_id = "unknown"
    then send_response cs id (`List masc)
    else (
      match ensure_lsp_process cs lang_id with
      | Error msg ->
        note_overlay_only cs ~lang_id ~error:msg;
        send_response cs id (`List masc)
      | Ok proc ->
        let promise =
          Lsp_message_router.send_request
            cs.router proc
            ~method_:"textDocument/completion"
            ~params ~client_id:(req_id_to_int id)
        in
        (match Eio.Promise.await promise with
         | Ok (`List items) -> send_response cs id (`List (items @ masc))
         | Ok other -> send_response cs id other
         | Error msg -> send_error cs id Mcp_error_code.(to_wire_code Internal_error) msg))
;;

(** Handle textDocument/codeAction — inject MASC annotation actions. *)
let handle_code_action cs params id =
  match extract_uri params with
  | None -> send_response cs id (`List [])
  | Some uri ->
    let base = cs.base_path in
    let relative = resolve_relative ~base uri |> Option.value ~default:"" in
    let line = extract_line params |> Option.value ~default:(-1) in
    let masc =
      if line >= 0 then
        Lsp_overlay_provider.code_actions
          ~base_dir:base ~file_path:relative ~line ~diagnostics:[]
      else []
    in
    let lang_id = Lsp_process_manager.lang_of_path relative in
    if lang_id = "unknown"
    then send_response cs id (`List masc)
    else (
      match ensure_lsp_process cs lang_id with
      | Error msg ->
        note_overlay_only cs ~lang_id ~error:msg;
        send_response cs id (`List masc)
      | Ok proc ->
        let promise =
          Lsp_message_router.send_request
            cs.router proc
            ~method_:"textDocument/codeAction"
            ~params ~client_id:(req_id_to_int id)
        in
        (match Eio.Promise.await promise with
         | Ok (`List items) -> send_response cs id (`List (items @ masc))
         | Ok other -> send_response cs id other
         | Error msg -> send_error cs id Mcp_error_code.(to_wire_code Internal_error) msg))
;;

(** Handle textDocument/documentSymbol — inject MASC annotation symbols. *)
let handle_document_symbol cs params id =
  match extract_uri params with
  | None -> send_response cs id (`List [])
  | Some uri ->
    let base = cs.base_path in
    let relative = resolve_relative ~base uri |> Option.value ~default:"" in
    let masc = Lsp_overlay_provider.document_symbols ~base_dir:base ~file_path:relative in
    let lang_id = Lsp_process_manager.lang_of_path relative in
    if lang_id = "unknown"
    then send_response cs id (`List masc)
    else (
      match ensure_lsp_process cs lang_id with
      | Error msg ->
        note_overlay_only cs ~lang_id ~error:msg;
        send_response cs id (`List masc)
      | Ok proc ->
        let promise =
          Lsp_message_router.send_request
            cs.router proc
            ~method_:"textDocument/documentSymbol"
            ~params ~client_id:(req_id_to_int id)
        in
        (match Eio.Promise.await promise with
         | Ok (`List items) -> send_response cs id (`List (items @ masc))
         | Ok other -> send_response cs id other
         | Error msg -> send_error cs id Mcp_error_code.(to_wire_code Internal_error) msg))
;;

(** Handle textDocument/foldingRange — inject MASC annotation folding ranges. *)
let handle_folding_range cs params id =
  match extract_uri params with
  | None -> send_response cs id (`List [])
  | Some uri ->
    let base = cs.base_path in
    let relative = resolve_relative ~base uri |> Option.value ~default:"" in
    let masc = Lsp_overlay_provider.folding_ranges ~base_dir:base ~file_path:relative in
    let lang_id = Lsp_process_manager.lang_of_path relative in
    if lang_id = "unknown"
    then send_response cs id (`List masc)
    else (
      match ensure_lsp_process cs lang_id with
      | Error msg ->
        note_overlay_only cs ~lang_id ~error:msg;
        send_response cs id (`List masc)
      | Ok proc ->
        let promise =
          Lsp_message_router.send_request
            cs.router proc
            ~method_:"textDocument/foldingRange"
            ~params ~client_id:(req_id_to_int id)
        in
        (match Eio.Promise.await promise with
         | Ok (`List items) -> send_response cs id (`List (items @ masc))
         | Ok other -> send_response cs id other
         | Error msg -> send_error cs id Mcp_error_code.(to_wire_code Internal_error) msg))
;;

(** Handle textDocument/documentHighlight — highlight related MASC annotations. *)
let handle_document_highlight cs params id =
  match extract_uri params with
  | None -> send_response cs id (`List [])
  | Some uri ->
    let base = cs.base_path in
    let relative = resolve_relative ~base uri |> Option.value ~default:"" in
    let line = extract_line params |> Option.value ~default:(-1) in
    let masc =
      if line >= 0 then
        Lsp_overlay_provider.document_highlights ~base_dir:base ~file_path:relative ~line
      else []
    in
    let lang_id = Lsp_process_manager.lang_of_path relative in
    if lang_id = "unknown"
    then send_response cs id (`List masc)
    else (
      match ensure_lsp_process cs lang_id with
      | Error msg ->
        note_overlay_only cs ~lang_id ~error:msg;
        send_response cs id (`List masc)
      | Ok proc ->
        let promise =
          Lsp_message_router.send_request
            cs.router proc
            ~method_:"textDocument/documentHighlight"
            ~params ~client_id:(req_id_to_int id)
        in
        (match Eio.Promise.await promise with
         | Ok (`List items) -> send_response cs id (`List (items @ masc))
         | Ok other -> send_response cs id other
         | Error msg -> send_error cs id Mcp_error_code.(to_wire_code Internal_error) msg))
;;

(** Dispatch an incoming LSP message to the appropriate handler. *)
let dispatch_message cs msg =
  if Atomic.get cs.disconnected
  then ()
  else
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
         let root = workspace_root_for_initialize ~base_path:cs.base_path root_uri in
         cs.workspace_root := root;
         send_response cs n (initialize_result_json ())
       | Some "initialized", _ -> ()
       | Some "shutdown", Some n -> send_response cs n `Null
       | Some "exit", _ -> disconnect cs
       (* Typed LSP health for the dashboard (task-1691): per-language
          connected / overlay_only / command / last_error. *)
       | Some "masc/lspStatus", Some n -> send_response cs n (current_status_json cs)
       (* MASC-overlay-aware handlers *)
       | Some "textDocument/hover", Some n -> handle_hover cs params n
       | Some "textDocument/codeLens", Some n -> handle_codelens cs params n
       | Some "textDocument/inlayHint", Some n -> handle_inlay_hint cs params n
       | Some "textDocument/diagnostic", Some n -> handle_diagnostic cs params n
       | Some "textDocument/definition", Some n -> handle_definition cs params n
       | Some "textDocument/references", Some n -> handle_references cs params n
       | Some "textDocument/completion", Some n -> handle_completion cs params n
       | Some "textDocument/codeAction", Some n -> handle_code_action cs params n
       | Some "textDocument/documentSymbol", Some n -> handle_document_symbol cs params n
       | Some "textDocument/foldingRange", Some n -> handle_folding_range cs params n
       | Some "textDocument/documentHighlight", Some n -> handle_document_highlight cs params n
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
       (* Other read-only requests with a textDocument URI → forward to LSP.
          Write-adjacent / unrecognized methods are rejected here (task-1692)
          rather than forwarded, so the observation plane never mutates the
          workspace through the language server. *)
       | Some m, Some n ->
         (match classify_forwarded_method m with
          | Reject_write_adjacent ->
            send_error cs n
              Mcp_error_code.(to_wire_code Invalid_request)
              ("Read-only LSP proxy: method not permitted: " ^ m)
          | Forward_read_only ->
            (match extract_uri params with
             | None ->
               send_error cs n
                 Mcp_error_code.(to_wire_code Method_not_found)
                 ("Unhandled method: " ^ m)
             | Some uri ->
               (* Resolve the URI explicitly: an out-of-workspace or malformed
                  URI ([None]) is rejected here rather than collapsed to a
                  path, so the forward is only reached for a resolved
                  in-workspace file. *)
               (match resolve_relative ~base:cs.base_path uri with
                | None ->
                  send_error cs n (-32801) "Path is outside the workspace"
                | Some relative ->
                  let lang_id = Lsp_process_manager.lang_of_path relative in
                  if lang_id <> "unknown"
                  then forward_request cs lang_id m params n
                  else send_error cs n (-32801) ("No LSP server for: " ^ relative))))
       (* Server-initiated notification broadcast *)
       | Some m, None ->
         Eio.Mutex.use_rw ~protect:true cs.spawn_mutex (fun () ->
           if not (Atomic.get cs.disconnected) then
             Hashtbl.iter
               (fun _lang_id proc ->
                  Lsp_message_router.send_notification cs.router proc ~method_:m ~params)
               cs.processes)
       (* No method field *)
       | None, Some n -> send_error cs n Mcp_error_code.(to_wire_code Invalid_request) "Missing method field"
       | None, None -> ())
    | _ ->
      (match
         extract_id
           (match json with
            | `Assoc f -> f
            | _ -> [])
       with
       | Some n -> send_error cs n Mcp_error_code.(to_wire_code Parse_error) "Parse error"
       | None -> ())
  with
  | exn -> Log.Server.error "LSP dispatch error: %s" (Printexc.to_string exn)
;;

(** Register the /api/v1/ide/lsp WebSocket endpoint. *)
let add_routes ~sw ~clock router =
  let router =
    Http.Router.ws_get
      "/api/v1/ide/lsp"
      (fun ~upgrade request reqd ->
         with_public_read
           (fun state _req reqd ->
              let origin =
                match Http.Request.header request "origin" with
                | Some o -> o
                | None -> "localhost"
              in
              (match state.Mcp_server.proc_mgr with
               | None ->
                 Log.Server.warn "LSP WebSocket: no proc_mgr available"
               | Some proc_mgr ->
                 (* RFC-0281: drive the upgraded connection via the shared
                    attachment SSOT.  The previous code built [ws_conn] and
                    [ignore]d it (never calling Gluten [upgrade]), so frames
                    were never read; it also blocked on a per-connection
                    [Eio.Switch.run] + promise, which the Gluten model
                    forbids.  Subprocesses are now reclaimed explicitly in
                    {!disconnect} (called from [Connection_close]/[eof]). *)
                 (* RFC-0287: drive the upgraded connection via the shared
                    ws-direct attachment SSOT. The Endpoint reassembles
                    fragments, validates UTF-8, enforces the size caps, and
                    auto-replies to pings, so [on_message] receives a complete
                    LSP message and a violation surfaces as on_close/on_error. *)
                 (match
                    Server_mcp_transport_ws.respond_and_drive_upgrade
                      ~upgrade
                      ~reqd
                      ~max_message:(Server_mcp_transport_ws.max_inbound_message_bytes ())
                      ~max_frame:(Server_mcp_transport_ws.max_inbound_frame_bytes ())
                      ~handler:(fun wsd ->
                        Log.Server.info "LSP WebSocket connected from %s" origin;
                        let cs =
                          { sw
                          ; router = Lsp_message_router.create ()
                          ; processes = Hashtbl.create 4
                          ; health = Hashtbl.create 4
                          ; wsd
                          ; base_path = base_path_of_state state
                          ; proc_mgr
                          ; workspace_root = ref (base_path_of_state state)
                          ; send_mutex = Eio.Mutex.create ()
                          ; spawn_mutex = Eio.Mutex.create ()
                          ; clock
                          ; disconnected = Atomic.make false
                          }
                        in
                        Ws_endpoint.handlers
                          ~on_message:(fun (m : Ws_msg.t) ->
                            dispatch_message cs (Bigstringaf.to_string m.Ws_msg.payload))
                          ~on_close:(fun ~code:_ ~reason:_ ->
                            Log.Server.info "LSP WebSocket disconnecting";
                            disconnect cs)
                          ~on_error:(fun reason ->
                            Log.Server.warn
                              "LSP inbound rejected (%s); disconnecting" reason;
                            disconnect cs)
                          ~on_eof:(fun () ->
                            Log.Server.info "LSP WebSocket EOF";
                            disconnect cs)
                          ())
                  with
                  | Ok () -> ()
                  | Error e -> Log.Server.warn "WebSocket upgrade failed: %s" e)))
           request
           reqd)
      router
  in
  router
;;

module For_testing = struct
  let resolve_relative = resolve_relative
  let workspace_root_for_initialize = workspace_root_for_initialize
  let initialize_result_json = initialize_result_json

  (* task-1691: the LSP health type + its pure wire projection. *)
  type health = lang_health =
    | Connected
    | Overlay_only of string

  let lang_status_json = lang_status_json
  let status_snapshot_json = status_snapshot_json

  (* task-1692: read-only method allowlist for the catch-all forwarder. *)
  type disposition = method_disposition =
    | Forward_read_only
    | Reject_write_adjacent

  let classify_forwarded_method = classify_forwarded_method
end
