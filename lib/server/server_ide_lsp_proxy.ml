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

type ws_send_msg =
  | Client_text of string
  | Stop_client_writer

type inbound_dispatch_msg =
  | Dispatch_text of string
  | Stop_dispatch_worker

module Lsp_proxy_limits = struct
  (* Per-connection backpressure limits.  These are named here because the
     ws-direct endpoint owns frame sizing, while this module owns post-frame
     LSP dispatch and outbound writes. *)
  let outbound_send_queue_capacity = 128
  let inbound_dispatch_queue_capacity = outbound_send_queue_capacity

  (* More than one dispatch worker keeps a slow LSP spawn/init from stopping
     unrelated status/lifecycle messages on the WebSocket reader path. *)
  let inbound_dispatch_worker_count = 4

  (* LSP initialize is the only request whose timeout is owned by this proxy;
     downstream request timeouts belong to the language server/client contract. *)
  let initialize_timeout_sec = 10.0
end

type resolved_lang =
  | Known_lang of string
  | Unknown_lang

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

(** Typed LSP method variant for the methods handled explicitly by the proxy
    (lifecycle, MASC status, and overlay-aware textDocument methods).  Using a
    variant removes duplicated wire strings from dispatch and handler sites and
    makes adding a new handled method a compile-time decision. *)
type lsp_method =
  | Initialize
  | Initialized
  | Shutdown
  | Exit
  | Masc_lsp_status
  | Hover
  | CodeLens
  | InlayHint
  | Diagnostic
  | Definition
  | References
  | Completion
  | CodeAction
  | Document_symbol
  | Folding_range
  | Document_highlight

let lsp_method_of_string = function
  | "initialize" -> Some Initialize
  | "initialized" -> Some Initialized
  | "shutdown" -> Some Shutdown
  | "exit" -> Some Exit
  | "masc/lspStatus" -> Some Masc_lsp_status
  | "textDocument/hover" -> Some Hover
  | "textDocument/codeLens" -> Some CodeLens
  | "textDocument/inlayHint" -> Some InlayHint
  | "textDocument/diagnostic" -> Some Diagnostic
  | "textDocument/definition" -> Some Definition
  | "textDocument/references" -> Some References
  | "textDocument/completion" -> Some Completion
  | "textDocument/codeAction" -> Some CodeAction
  | "textDocument/documentSymbol" -> Some Document_symbol
  | "textDocument/foldingRange" -> Some Folding_range
  | "textDocument/documentHighlight" -> Some Document_highlight
  | _ -> None
;;

let lsp_method_to_string = function
  | Initialize -> "initialize"
  | Initialized -> "initialized"
  | Shutdown -> "shutdown"
  | Exit -> "exit"
  | Masc_lsp_status -> "masc/lspStatus"
  | Hover -> "textDocument/hover"
  | CodeLens -> "textDocument/codeLens"
  | InlayHint -> "textDocument/inlayHint"
  | Diagnostic -> "textDocument/diagnostic"
  | Definition -> "textDocument/definition"
  | References -> "textDocument/references"
  | Completion -> "textDocument/completion"
  | CodeAction -> "textDocument/codeAction"
  | Document_symbol -> "textDocument/documentSymbol"
  | Folding_range -> "textDocument/foldingRange"
  | Document_highlight -> "textDocument/documentHighlight"
;;

type conn_state =
  { sw : Eio.Switch.t
  ; router : Lsp_message_router.t
  ; processes : (string, Lsp_process_manager.lsp_process) Hashtbl.t
  ; process_mutex : Eio.Mutex.t
  ; spawn_locks : (string, Eio.Mutex.t) Hashtbl.t
  ; health : (string, lang_health) Hashtbl.t
  ; health_mutex : Eio.Mutex.t
  ; wsd : Ws_wsd.t
  ; base_path : string
  ; proc_mgr : Eio_unix.Process.mgr_ty Eio.Resource.t
  ; workspace_root : string ref
  ; send_queue : ws_send_msg Eio.Stream.t
  ; dispatch_queue : inbound_dispatch_msg Eio.Stream.t
  ; clock : float Eio.Time.clock_ty Eio.Resource.t
  ; disconnected : bool Atomic.t
        (* RFC-0287: fragment reassembly + size caps now live in the ws-direct
           Endpoint, which delivers complete messages to [on_message]; the
           former shared [Ws_inbound] reassembler field is gone. *)
  }

let base_path_of_state state = (Mcp_server.workspace_config state).base_path

let process_snapshot cs =
  Eio.Mutex.use_ro cs.process_mutex (fun () ->
    Hashtbl.fold (fun lang_id proc acc -> (lang_id, proc) :: acc) cs.processes [])
;;

let find_process cs lang_id =
  Eio.Mutex.use_ro cs.process_mutex (fun () -> Hashtbl.find_opt cs.processes lang_id)
;;

let add_process cs lang_id proc =
  Eio.Mutex.use_rw ~protect:true cs.process_mutex (fun () ->
    Hashtbl.replace cs.processes lang_id proc)
;;

let remove_process_if_current cs lang_id proc =
  Eio.Mutex.use_rw ~protect:true cs.process_mutex (fun () ->
    match Hashtbl.find_opt cs.processes lang_id with
    | Some current when current == proc ->
      Hashtbl.remove cs.processes lang_id;
      true
    | Some _ | None -> false)
;;

let spawn_lock_for cs lang_id =
  Eio.Mutex.use_rw ~protect:true cs.process_mutex (fun () ->
    match Hashtbl.find_opt cs.spawn_locks lang_id with
    | Some mutex -> mutex
    | None ->
      let mutex = Eio.Mutex.create () in
      Hashtbl.add cs.spawn_locks lang_id mutex;
      mutex)
;;

let stop_send_writer cs =
  try Eio.Fiber.fork ~sw:cs.sw (fun () -> Eio.Stream.add cs.send_queue Stop_client_writer)
  with
  | exn ->
    Log.Server.warn
      "LSP WebSocket writer stop signal failed: %s"
      (Printexc.to_string exn)
;;

let stop_dispatch_workers cs =
  try
    Eio.Fiber.fork ~sw:cs.sw (fun () ->
      for _ = 1 to Lsp_proxy_limits.inbound_dispatch_worker_count do
        Eio.Stream.add cs.dispatch_queue Stop_dispatch_worker
      done)
  with
  | exn ->
    Log.Server.warn
      "LSP dispatch worker stop signal failed: %s"
      (Printexc.to_string exn)
;;

(** Signal connection end.  Idempotent (guarded by [disconnected]).

    Explicitly shuts down every spawned LSP process.
    [Lsp_process_manager.shutdown] closes the process stdin/stdout/stderr
    flows, which makes the response-reader and stderr-drain fibers' reads
    raise so those fibers exit — so this reclaims the processes AND their
    fibers without a switch teardown.  Required because [cs.sw] is the
    server switch: without explicit shutdown the processes would leak
    until server shutdown (RFC-0261).  The process table is drained under
    [process_mutex]; concurrent spawns re-check [disconnected] before they can
    publish a process.  RFC-0281 Phase 2. *)
let disconnect cs =
  if Atomic.compare_and_set cs.disconnected false true
  then (
    let processes =
      Eio.Mutex.use_rw ~protect:true cs.process_mutex (fun () ->
        let processes =
          Hashtbl.fold (fun _ proc acc -> proc :: acc) cs.processes []
        in
        Hashtbl.clear cs.processes;
        Hashtbl.clear cs.spawn_locks;
        processes)
    in
    List.iter Lsp_process_manager.shutdown processes;
    stop_dispatch_workers cs;
    stop_send_writer cs)
;;

(** Queue outbound frames behind a single writer fiber.  Callers backpressure on
    the bounded stream instead of contending on the WebSocket write itself. *)
let send cs msg =
  if not (Atomic.get cs.disconnected) then Eio.Stream.add cs.send_queue (Client_text msg)
;;

let start_send_writer cs =
  Eio.Fiber.fork_daemon ~sw:cs.sw (fun () ->
    let rec loop () =
      match Eio.Stream.take cs.send_queue with
      | Stop_client_writer -> `Stop_daemon
      | Client_text msg ->
        if not (Atomic.get cs.disconnected) then send_text cs.wsd msg;
        loop ()
    in
    try loop () with
    | Eio.Cancel.Cancelled _ as exn -> raise exn
    | exn ->
      Log.Server.warn "LSP WebSocket writer stopped: %s" (Printexc.to_string exn);
      disconnect cs;
      `Stop_daemon)
;;

let enqueue_dispatch cs msg =
  if not (Atomic.get cs.disconnected)
  then Eio.Stream.add cs.dispatch_queue (Dispatch_text msg)
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
   executable, [null] when none is mapped) / [last_error]. *)
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
  Eio.Mutex.use_ro cs.health_mutex (fun () ->
    status_snapshot_json (Hashtbl.fold (fun l h acc -> (l, h) :: acc) cs.health []))
;;

(* Push the current status to the client as a [masc/lspStatus] notification,
   so the dashboard reacts to a health transition without polling. *)
let push_lsp_status cs status =
  send_client_notification cs (lsp_method_to_string Masc_lsp_status) status
;;

(* Record [lang_id]'s health, notifying the client only when it actually
   changed (so a stream of requests while degraded does not spam
   notifications). *)
let set_health cs ~lang_id health =
  let status =
    Eio.Mutex.use_rw ~protect:true cs.health_mutex (fun () ->
      let changed =
        match Hashtbl.find_opt cs.health lang_id with
        | Some prev -> prev <> health
        | None -> true
      in
      Hashtbl.replace cs.health lang_id health;
      if changed
      then
        Some
          (status_snapshot_json
             (Hashtbl.fold (fun l h acc -> (l, h) :: acc) cs.health []))
      else None)
  in
  match status with
  | Some status -> push_lsp_status cs status
  | None -> ()
;;

(* Unified degraded path shared by every overlay handler (task-1691): mark
   the language overlay-only, log a typed WARN, and notify the client. The
   caller then serves its MASC overlay, so the request never fails and the
   keeper cycle is never blocked by an unavailable LSP. *)
let note_overlay_only cs ~lang_id ~error =
  Log.Server.warn "LSP overlay-only for %s: %s" lang_id error;
  set_health cs ~lang_id (Overlay_only error)
;;

let note_process_exit cs (proc : Lsp_process_manager.lsp_process) ~reason =
  if remove_process_if_current cs proc.lang_id proc
  then
    note_overlay_only
      cs
      ~lang_id:proc.lang_id
      ~error:("LSP process exited: " ^ reason)
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

(** [fpath_within ~base path] is [Some rel] when the normalized absolute
    [path] sits inside normalized absolute [base].  The returned relative path
    contains no [..] segments, so percent-decoded traversal such as
    [%2F..%2F..] is rejected after normalization. *)
let fpath_within ~base path =
  match Fpath.of_string base, Fpath.of_string path with
  | Ok base, Ok path when Fpath.is_abs base && Fpath.is_abs path ->
    (* Qualify explicitly instead of [Fpath.(...)]: inside the local open the
       identifier [base] resolves to [Fpath.base] (t -> t) and shadows the local
       [base] value, which fails to type-check under fpath 0.7.3. *)
    let base = Fpath.rem_empty_seg (Fpath.normalize base) in
    let path = Fpath.rem_empty_seg (Fpath.normalize path) in
    (match Fpath.relativize ~root:base path with
     | Some rel ->
       if List.exists (String.equal "..") (Fpath.segs rel) then None else Some rel
     | None -> None)
  | _ -> None
;;

let relative_to_string rel =
  let s = Fpath.to_string rel in
  if String.equal s "." then "" else s
;;

let realpath_scoped_relative ~base relative =
  let lexical =
    if String.equal relative ""
    then Fpath.v base
    else Fpath.append (Fpath.v base) (Fpath.v relative)
  in
  try
    let resolved = Fs_compat.realpath (Fpath.to_string lexical) in
    match fpath_within ~base resolved with
    | Some rel -> Some (relative_to_string rel)
    | None -> None
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | _ ->
    (* Unsaved IDE buffers often have no filesystem target yet.  Lexical
       containment is still enough in that case; the realpath guard applies
       when a target exists and can resolve symlinks. *)
    Some relative
;;

let workspace_root_for_initialize ~base_path root_uri =
  let candidate = root_uri |> path_of_file_uri in
  match
    Option.bind candidate (fun s ->
      match Fpath.of_string s with
      | Ok p when Fpath.is_abs p -> Some Fpath.(rem_empty_seg (normalize p))
      | _ -> None)
  with
  | Some candidate ->
    (match fpath_within ~base:base_path (Fpath.to_string candidate) with
     | Some _ -> Fpath.to_string candidate
     | None -> base_path)
  | None -> base_path
;;

(** Resolve file:// URI to relative path from base.
    Uses Fpath normalization and [Fpath.relativize], and rejects traversal
    introduced by percent-decoded separators such as [%2F..]. *)
let resolve_relative ~base uri =
  if not (String.starts_with ~prefix:"file://" uri)
  then Some uri
  else (
    let decoded = path_of_file_uri uri in
    match Fpath.of_string decoded with
    | Ok full when Fpath.is_abs full ->
      (match fpath_within ~base (Fpath.to_string full) with
       | Some rel ->
         realpath_scoped_relative ~base (relative_to_string rel)
       | None -> None)
    | _ -> None)
;;

let resolve_lang relative =
  match Lsp_process_manager.lang_of_path relative with
  | "unknown" -> Unknown_lang
  | lang_id -> Known_lang lang_id
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
    let spawn_mutex = spawn_lock_for cs lang_id in
    Eio.Mutex.use_rw ~protect:true spawn_mutex (fun () ->
      if Atomic.get cs.disconnected
      then Error "connection closed"
      else
    match find_process cs lang_id with
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
           ~on_exit:(Some (fun ~reason -> note_process_exit cs proc ~reason))
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
             ~method_:(lsp_method_to_string Initialize)
             ~params:init_params
             ~client_id:(-1)
         in
         let init_result =
           try
             Ok
               (Eio.Time.with_timeout_exn
                  cs.clock
                  Lsp_proxy_limits.initialize_timeout_sec
                  (fun () -> Eio.Promise.await promise))
           with Eio.Time.Timeout ->
             Error
               (Printf.sprintf
                  "LSP initialize timeout for %s (%.0fs)"
                  lang_id
                  Lsp_proxy_limits.initialize_timeout_sec)
         in
         (match init_result with
          | Ok (Ok _) ->
            Lsp_message_router.send_notification
              cs.router
              proc
              ~method_:(lsp_method_to_string Initialized)
              ~params:(`Assoc []);
            if Atomic.get cs.disconnected
            then (
              Lsp_process_manager.shutdown proc;
              Error "connection closed")
            else (
              add_process cs lang_id proc;
              set_health cs ~lang_id Connected;
              Log.Server.info "LSP server ready: %s" lang_id;
              Ok proc)
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
  | Error msg ->
    note_overlay_only cs ~lang_id ~error:msg;
    Log.Server.warn "Cannot forward %s: %s" method_ msg
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
  | Unknown_forwarded_method of string

let classify_forwarded_method method_ =
  match method_ with
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
     workspace/executeCommand, workspace/applyEdit — is denied explicitly.
     Unrecognized methods preserve their wire spelling for diagnostics. *)
  | "textDocument/rename"
  | "textDocument/prepareRename"
  | "textDocument/formatting"
  | "textDocument/rangeFormatting"
  | "textDocument/onTypeFormatting"
  | "textDocument/willSaveWaitUntil"
  | "workspace/executeCommand"
  | "workspace/applyEdit" -> Reject_write_adjacent
  (* workspace/symbol and the LSP */resolve methods intentionally stay out of
     the forward set: their payloads do not carry a [textDocument.uri], and this
     multi-language proxy has no SSOT for selecting one server process. They are
     rejected below as [Unknown_forwarded_method] with the original method name. *)
  | unknown -> Unknown_forwarded_method unknown
;;

(** Handle textDocument/codeLens — merge LSP response with MASC overlays. *)
let handle_codelens cs params id =
  match extract_uri params with
  | None -> send_response cs id (`List [])
  | Some uri ->
    let base = cs.base_path in
    let relative = resolve_relative ~base uri |> Option.value ~default:"" in
    let masc = Lsp_overlay_provider.codelenses ~base_dir:base ~file_path:relative in
    (match resolve_lang relative with
     | Unknown_lang -> send_response cs id (`List masc)
     | Known_lang lang_id ->
      match ensure_lsp_process cs lang_id with
      | Error msg ->
        note_overlay_only cs ~lang_id ~error:msg;
        send_response cs id (`List masc)
      | Ok proc ->
        let promise =
          Lsp_message_router.send_request
            cs.router
            proc
            ~method_:(lsp_method_to_string CodeLens)
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
    (match resolve_lang relative with
     | Unknown_lang -> send_response cs id (`List masc)
     | Known_lang lang_id ->
      match ensure_lsp_process cs lang_id with
      | Error msg ->
        note_overlay_only cs ~lang_id ~error:msg;
        send_response cs id (`List masc)
      | Ok proc ->
        let promise =
          Lsp_message_router.send_request
            cs.router
            proc
            ~method_:(lsp_method_to_string InlayHint)
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
    (match resolve_lang relative with
     | Unknown_lang ->
      let diags =
        Lsp_overlay_provider.diagnostics
          ~base_dir:base
          ~file_path:relative
          ~lsp_diagnostics:[]
      in
      send_response cs id (`Assoc [ "items", `List diags ])
     | Known_lang lang_id ->
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
            ~method_:(lsp_method_to_string Diagnostic)
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
    (match resolve_lang relative with
     | Unknown_lang ->
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
      else send_response cs id `Null
     | Known_lang lang_id ->
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
            ~method_:(lsp_method_to_string Hover)
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
    (match resolve_lang relative with
     | Unknown_lang -> send_response cs id (`List masc)
     | Known_lang lang_id ->
      match ensure_lsp_process cs lang_id with
      | Error msg ->
        note_overlay_only cs ~lang_id ~error:msg;
        send_response cs id (`List masc)
      | Ok proc ->
        let promise =
          Lsp_message_router.send_request
            cs.router proc
            ~method_:(lsp_method_to_string Definition)
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
    (match resolve_lang relative with
     | Unknown_lang -> send_response cs id (`List masc)
     | Known_lang lang_id ->
      match ensure_lsp_process cs lang_id with
      | Error msg ->
        note_overlay_only cs ~lang_id ~error:msg;
        send_response cs id (`List masc)
      | Ok proc ->
        let promise =
          Lsp_message_router.send_request
            cs.router proc
            ~method_:(lsp_method_to_string References)
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
    (match resolve_lang relative with
     | Unknown_lang -> send_response cs id (`List masc)
     | Known_lang lang_id ->
      match ensure_lsp_process cs lang_id with
      | Error msg ->
        note_overlay_only cs ~lang_id ~error:msg;
        send_response cs id (`List masc)
      | Ok proc ->
        let promise =
          Lsp_message_router.send_request
            cs.router proc
            ~method_:(lsp_method_to_string Completion)
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
    (match resolve_lang relative with
     | Unknown_lang -> send_response cs id (`List masc)
     | Known_lang lang_id ->
      match ensure_lsp_process cs lang_id with
      | Error msg ->
        note_overlay_only cs ~lang_id ~error:msg;
        send_response cs id (`List masc)
      | Ok proc ->
        let promise =
          Lsp_message_router.send_request
            cs.router proc
            ~method_:(lsp_method_to_string CodeAction)
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
    (match resolve_lang relative with
     | Unknown_lang -> send_response cs id (`List masc)
     | Known_lang lang_id ->
      match ensure_lsp_process cs lang_id with
      | Error msg ->
        note_overlay_only cs ~lang_id ~error:msg;
        send_response cs id (`List masc)
      | Ok proc ->
        let promise =
          Lsp_message_router.send_request
            cs.router proc
            ~method_:(lsp_method_to_string Document_symbol)
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
    (match resolve_lang relative with
     | Unknown_lang -> send_response cs id (`List masc)
     | Known_lang lang_id ->
      match ensure_lsp_process cs lang_id with
      | Error msg ->
        note_overlay_only cs ~lang_id ~error:msg;
        send_response cs id (`List masc)
      | Ok proc ->
        let promise =
          Lsp_message_router.send_request
            cs.router proc
            ~method_:(lsp_method_to_string Folding_range)
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
    (match resolve_lang relative with
     | Unknown_lang -> send_response cs id (`List masc)
     | Known_lang lang_id ->
      match ensure_lsp_process cs lang_id with
      | Error msg ->
        note_overlay_only cs ~lang_id ~error:msg;
        send_response cs id (`List masc)
      | Ok proc ->
        let promise =
          Lsp_message_router.send_request
            cs.router proc
            ~method_:(lsp_method_to_string Document_highlight)
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
       | Some method_str, id_opt ->
         (match lsp_method_of_string method_str, id_opt with
          (* Client lifecycle *)
          | Some Initialize, Some n ->
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
          | Some Initialized, _ -> ()
          | Some Shutdown, Some n -> send_response cs n `Null
          | Some Exit, _ -> disconnect cs
          (* Typed LSP health for the dashboard (task-1691): per-language
             connected / overlay_only / command / last_error. *)
          | Some Masc_lsp_status, Some n -> send_response cs n (current_status_json cs)
          | Some Masc_lsp_status, None -> ()
          (* MASC-overlay-aware handlers *)
          | Some Hover, Some n -> handle_hover cs params n
          | Some CodeLens, Some n -> handle_codelens cs params n
          | Some InlayHint, Some n -> handle_inlay_hint cs params n
          | Some Diagnostic, Some n -> handle_diagnostic cs params n
          | Some Definition, Some n -> handle_definition cs params n
          | Some References, Some n -> handle_references cs params n
          | Some Completion, Some n -> handle_completion cs params n
          | Some CodeAction, Some n -> handle_code_action cs params n
          | Some Document_symbol, Some n -> handle_document_symbol cs params n
          | Some Folding_range, Some n -> handle_folding_range cs params n
          | Some Document_highlight, Some n -> handle_document_highlight cs params n
          | _ ->
            (* File notifications → forward to appropriate LSP process *)
            if String.starts_with ~prefix:"textDocument/did" method_str
            then
              (match extract_uri params with
               | Some uri ->
                 (match resolve_relative ~base:cs.base_path uri with
                  | None -> ()
                  | Some relative ->
                    if String.equal method_str "textDocument/didSave"
                    then
                      Lsp_overlay_provider.invalidate_cache
                        ~base_dir:cs.base_path
                        ~file_path:relative;
                    (match resolve_lang relative with
                     | Unknown_lang -> ()
                     | Known_lang lang_id -> forward_notification cs lang_id method_str params))
               | None -> ())
            else
              (match id_opt with
               | Some n ->
                 (* Other read-only requests with a textDocument URI → forward to LSP.
                    Write-adjacent / unrecognized methods are rejected here (task-1692)
                    rather than forwarded, so the observation plane never mutates the
                    workspace through the language server. *)
                 (match classify_forwarded_method method_str with
                  | Reject_write_adjacent ->
                    send_error cs n
                      Mcp_error_code.(to_wire_code Invalid_request)
                      ("Read-only LSP proxy: method not permitted: " ^ method_str)
                  | Unknown_forwarded_method unknown ->
                    send_error cs n
                      Mcp_error_code.(to_wire_code Method_not_found)
                      ("Read-only LSP proxy: unknown method not permitted: " ^ unknown)
                  | Forward_read_only ->
                    (match extract_uri params with
                     | None ->
                       send_error cs n
                         Mcp_error_code.(to_wire_code Method_not_found)
                         ("Unhandled method: " ^ method_str)
                     | Some uri ->
                       (* Resolve the URI explicitly: an out-of-workspace or malformed
                          URI ([None]) is rejected here rather than collapsed to a
                          path, so the forward is only reached for a resolved
                          in-workspace file. *)
                       (match resolve_relative ~base:cs.base_path uri with
                        | None ->
                          send_error
                            cs
                            n
                            Mcp_error_code.(to_wire_code Invalid_params)
                            "Path is outside the workspace"
                        | Some relative ->
                          (match resolve_lang relative with
                           | Known_lang lang_id -> forward_request cs lang_id method_str params n
                           | Unknown_lang ->
                             send_error
                               cs
                               n
                               Mcp_error_code.(to_wire_code Invalid_params)
                               ("No LSP server for: " ^ relative)))))
               | None ->
                 (* Server-initiated notification broadcast *)
                 if not (Atomic.get cs.disconnected)
                 then
                   List.iter
                     (fun (_lang_id, proc) ->
                        Lsp_message_router.send_notification cs.router proc ~method_:method_str ~params)
                     (process_snapshot cs)))
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

let start_dispatch_workers cs =
  for _ = 1 to Lsp_proxy_limits.inbound_dispatch_worker_count do
    Eio.Fiber.fork_daemon ~sw:cs.sw (fun () ->
      let rec loop () =
        match Eio.Stream.take cs.dispatch_queue with
        | Stop_dispatch_worker -> `Stop_daemon
        | Dispatch_text msg ->
          if not (Atomic.get cs.disconnected) then dispatch_message cs msg;
          loop ()
      in
      try loop () with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn ->
        Log.Server.warn "LSP dispatch worker stopped: %s" (Printexc.to_string exn);
        `Stop_daemon)
  done
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
                          ; process_mutex = Eio.Mutex.create ()
                          ; spawn_locks = Hashtbl.create 4
                          ; health = Hashtbl.create 4
                          ; health_mutex = Eio.Mutex.create ()
                          ; wsd
                          ; base_path = base_path_of_state state
                          ; proc_mgr
                          ; workspace_root = ref (base_path_of_state state)
                          ; send_queue =
                              Eio.Stream.create
                                Lsp_proxy_limits.outbound_send_queue_capacity
                          ; dispatch_queue =
                              Eio.Stream.create
                                Lsp_proxy_limits.inbound_dispatch_queue_capacity
                          ; clock
                          ; disconnected = Atomic.make false
                          }
                        in
                        start_send_writer cs;
                        start_dispatch_workers cs;
                        Ws_endpoint.handlers
                          ~on_message:(fun (m : Ws_msg.t) ->
                            enqueue_dispatch cs (Bigstringaf.to_string m.Ws_msg.payload))
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
  let inbound_dispatch_worker_count = Lsp_proxy_limits.inbound_dispatch_worker_count

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
    | Unknown_forwarded_method of string

  let classify_forwarded_method = classify_forwarded_method

  type lang = resolved_lang =
    | Known_lang of string
    | Unknown_lang

  let resolve_lang = resolve_lang
end
