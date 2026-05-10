(** Server IDE LSP Proxy — WebSocket bridge for Language Server Protocol
    with MASC observational overlays (Keeper annotations, traces, goals).

    This proxy:
    - Manages per-language LSP server processes (ocaml-lsp, tsserver, etc.)
    - Forwards LSP messages between client (CodeMirror) and language servers
    - Injects MASC-specific metadata into responses (codeLens, inlayHints, diagnostics)
    - Handles workspace synchronization for .masc-ide/ annotations *)

open Server_auth
open Server_utils

module Http = Http_server_eio
module Ws = Httpun_ws

(* Log via Log.Server directly *)

(** SHA1 function required by httpun-ws handshake. *)
let sha1 s =
  Digestif.SHA1.(digest_string s |> to_raw_string)

(** Send a text frame via WebSocket using httpun-ws {Wsd.send_bytes}. *)
let send_text wsd s =
  let bytes = Bytes.unsafe_of_string s in
  Ws.Wsd.send_bytes ~kind:`Text wsd bytes ~off:0 ~len:(Bytes.length bytes)

(** LSP server process descriptor *)
type lsp_server = {
  lang_id : string;
  workspace_root : string;
  mutable next_request_id : int;
  pending_requests : (int * Yojson.Safe.t option) list;
}

(** MASC overlay data for LSP responses *)
type masc_overlay = {
  keeper_annotations : (int * int * string) list;  (* line_start, line_end, content *)
  keeper_traces : (int * string * string) list;    (* line, keeper_id, action *)
  goal_bindings : (int * string) list;             (* line, goal_id *)
}

let empty_overlay = {
  keeper_annotations = [];
  keeper_traces = [];
  goal_bindings = [];
}

(** Extract workspace base from state *)
let base_path_of_state state = state.Mcp_server.room_config.base_path

(** Resolve .masc-ide/ annotations for a given file *)
let load_annotations_for_file ~base_path ~file_path =
  let masc_ide_dir = Filename.concat base_path ".masc-ide" in
  let annotations_dir = Filename.concat masc_ide_dir "annotations" in
  if not (Sys.file_exists annotations_dir) then begin
    Log.Server.debug "No .masc-ide/annotations directory for %s" file_path;
    empty_overlay
  end else begin
    (* TODO: Wire to ide_annotations.ml for actual loading *)
    empty_overlay
  end

(** Get LSP server command for a language *)
let lsp_command_for_lang lang_id =
  match lang_id with
  | "ocaml" -> Some ("ocaml-lsp-server", [||])
  | "typescript" | "javascript" -> Some ("typescript-language-server", [|"--stdio"|])
  | "python" -> Some ("pylsp", [||])
  | "rust" -> Some ("rust-analyzer", [||])
  | "go" -> Some ("gopls", [||])
  | _ -> None

(** Create LSP server process for a language *)
let create_lsp_server ~lang_id ~workspace_root =
  match lsp_command_for_lang lang_id with
  | None ->
      Log.Server.warn "No LSP server configured for language: %s" lang_id;
      None
  | Some (cmd, args) ->
      try
        let cmd_exists = Sys.command (Printf.sprintf "which %s 2>/dev/null" cmd) = 0 in
        if not cmd_exists then begin
          Log.Server.warn "LSP server not found: %s" cmd;
          None
        end else begin
          Log.Server.info "Starting LSP server for %s: %s %s" lang_id cmd
            (String.concat " " (Array.to_list args));
          (* TODO: Actually spawn process with Eio.Process *)
          Some {
            lang_id;
            workspace_root;
            next_request_id = 1;
            pending_requests = [];
          }
        end
      with exn ->
        Log.Server.error "Failed to start LSP server for %s: %s" lang_id (Printexc.to_string exn);
        None

(** Inject MASC overlay into LSP CodeLens response *)
let inject_masc_codelens ~overlay ~lsp_response =
  match overlay.keeper_annotations with
  | [] -> lsp_response
  | annotations ->
      let codelens_list =
        match lsp_response with
        | `Assoc fields ->
            (match List.assoc_opt "result" fields with
            | Some (`List existing) -> existing
            | _ -> [])
        | _ -> []
      in
      let new_codelens =
        List.mapi (fun _i (line_start, line_end, content) ->
          `Assoc [
            ("range", `Assoc [
              ("start", `Assoc [("line", `Int line_start); ("character", `Int 0)]);
              ("end", `Assoc [("line", `Int line_end); ("character", `Int 0)]);
            ]);
            ("command", `Assoc [
              ("title", `String ("Keeper: " ^ String.sub content 0 (min 50 (String.length content))));
              ("command", `String "masc-ide.showAnnotation");
            ]);
          ])
          annotations
      in
      let merged = List.append codelens_list new_codelens in
      `Assoc [
        ("jsonrpc", `String "2.0");
        ("id", `Int 1);
        ("result", `List merged);
      ]

(** Detect language from file path *)
let lang_id_of_path file_path =
  let ext =
    try Filename.extension file_path |> String.lowercase_ascii
    with _ -> ""
  in
  match ext with
  | ".ml" | ".mli" -> "ocaml"
  | ".ts" | ".tsx" -> "typescript"
  | ".js" | ".jsx" -> "javascript"
  | ".py" -> "python"
  | ".rs" -> "rust"
  | ".go" -> "go"
  | _ -> "unknown"

(** Handle LSP initialize request *)
let handle_initialize ~state ~params:_ ~workspace_root =
  Log.Server.info "LSP initialize for workspace: %s" workspace_root;
  `Assoc [
    ("jsonrpc", `String "2.0");
    ("id", `Int 1);
    ("result", `Assoc [
      ("capabilities", `Assoc [
        ("textDocumentSync", `Int 2);  (* Incremental *)
        ("hoverProvider", `Bool true);
        ("definitionProvider", `Bool true);
        ("referencesProvider", `Bool true);
        ("documentSymbolProvider", `Bool true);
        ("codeLensProvider", `Assoc [
          ("resolveProvider", `Bool false);
        ]);
        ("inlayHintProvider", `Bool true);
        ("diagnosticProvider", `Bool true);
      ]);
    ]);
  ]

(** Handle textDocument/codeLens request with MASC overlay *)
let handle_code_lens ~state ~params =
  let file_path, overlay =
    match params with
    | `Assoc fields ->
        (match List.assoc_opt "textDocument" fields with
        | Some (`Assoc doc_fields) ->
            (match List.assoc_opt "uri" doc_fields with
            | Some (`String uri) ->
                let base = base_path_of_state state in
                let relative_path =
                  if String.starts_with ~prefix:"file://" uri then
                    let full_path = String.sub uri 7 (String.length uri - 7) in
                    if String.starts_with ~prefix:base full_path then
                      String.sub full_path (String.length base + 1) (String.length full_path - String.length base - 1)
                    else
                      full_path
                  else
                    uri
                in
                (relative_path, load_annotations_for_file ~base_path:base ~file_path:relative_path)
            | _ -> ("", empty_overlay))
        | _ -> ("", empty_overlay))
    | _ -> ("", empty_overlay)
  in
  Log.Server.debug "CodeLens for %s with %d annotations" file_path (List.length overlay.keeper_annotations);
  inject_masc_codelens ~overlay ~lsp_response:(`Assoc [
    ("jsonrpc", `String "2.0");
    ("id", `Int 1);
    ("result", `List []);
  ])

(** Handle textDocument/diagnostic request *)
let handle_diagnostics ~state:_ ~params =
  let file_path =
    match params with
    | `Assoc fields ->
        (match List.assoc_opt "textDocument" fields with
        | Some (`Assoc doc_fields) ->
            (match List.assoc_opt "uri" doc_fields with
            | Some (`String uri) -> uri
            | _ -> "")
        | _ -> "")
    | _ -> ""
  in
  Log.Server.debug "Diagnostics for %s" file_path;
  `Assoc [
    ("jsonrpc", `String "2.0");
    ("id", `Int 1);
    ("result", `List []);  (* TODO: Wire to actual LSP diagnostics *)
  ]

(** Read a complete frame payload into a string via [Payload.schedule_read]. *)
let read_frame_text ~len ~on_text payload =
  if len = 0 then on_text ""
  else begin
    let buffer = Bytes.create len in
    let offset = ref 0 in
    let rec schedule () =
      if !offset >= len then
        on_text (Bytes.unsafe_to_string buffer)
      else
        Ws.Payload.schedule_read payload
          ~on_eof:(fun () ->
            on_text (Bytes.sub_string buffer 0 !offset))
          ~on_read:(fun bs ~off ~len:chunk_len ->
            Bigstringaf.blit_to_bytes bs ~src_off:off buffer
              ~dst_off:!offset ~len:chunk_len;
            offset := !offset + chunk_len;
            schedule ())
    in
    schedule ()
  end

(** Dispatch an LSP message string to the appropriate handler. *)
let handle_lsp_message ~state ~wsd ~lsp_servers ~active_file msg =
  try
    let json = Yojson.Safe.from_string msg in
    let response =
      match json with
      | `Assoc fields ->
          (match List.assoc_opt "method" fields with
          | Some (`String "initialize") ->
              let workspace_root =
                match List.assoc_opt "params" fields with
                | Some (`Assoc pfields) ->
                    (match List.assoc_opt "rootUri" pfields with
                    | Some (`String uri) ->
                        if String.starts_with ~prefix:"file://" uri then
                          String.sub uri 7 (String.length uri - 7)
                        else
                          uri
                    | _ -> base_path_of_state state)
                | _ -> base_path_of_state state
              in
              handle_initialize ~state ~params:(List.assoc_opt "params" fields |> Option.value ~default:`Null) ~workspace_root
          | Some (`String "textDocument/codeLens") ->
              handle_code_lens ~state ~params:(List.assoc_opt "params" fields |> Option.value ~default:`Null)
          | Some (`String "textDocument/diagnostic") ->
              handle_diagnostics ~state ~params:(List.assoc_opt "params" fields |> Option.value ~default:`Null)
          | Some (`String "textDocument/didOpen") ->
              (* Track active file *)
              (match List.assoc_opt "params" fields with
              | Some (`Assoc pfields) ->
                  (match List.assoc_opt "textDocument" pfields with
                  | Some (`Assoc tfields) ->
                      (match List.assoc_opt "uri" tfields with
                      | Some (`String uri) ->
                          active_file := Some uri;
                          let lang_id = lang_id_of_path uri in
                          if not (Hashtbl.mem lsp_servers lang_id) then begin
                            match create_lsp_server ~lang_id ~workspace_root:(base_path_of_state state) with
                            | Some server ->
                                Hashtbl.add lsp_servers lang_id server;
                                Log.Server.info "Auto-started LSP server for %s" lang_id
                            | None -> ()
                          end
                      | _ -> ())
                  | _ -> ())
              | _ -> ());
              `Assoc [
                ("jsonrpc", `String "2.0");
                ("id", `Null);
                ("result", `Null);
              ]
          | Some (`String m) ->
              Log.Server.debug "Forwarding LSP method %s" m;
              (* TODO: Forward to actual LSP server process *)
              `Assoc [
                ("jsonrpc", `String "2.0");
                ("id", `Int 1);
                ("result", `Null);
              ]
          | _ ->
              Log.Server.warn "LSP message without method";
              `Assoc [
                ("jsonrpc", `String "2.0");
                ("id", `Int 1);
                ("error", `Assoc [
                  ("code", `Int (-32600));
                  ("message", `String "Invalid Request");
                ]);
              ])
      | _ ->
          Log.Server.warn "Invalid LSP message format";
          `Assoc [
            ("jsonrpc", `String "2.0");
            ("id", `Int 1);
            ("error", `Assoc [
              ("code", `Int (-32700));
              ("message", `String "Parse error");
            ]);
          ]
    in
    let response_str = Yojson.Safe.to_string response in
    send_text wsd response_str
  with exn ->
    Log.Server.error "LSP message handling error: %s" (Printexc.to_string exn)

(** Main WebSocket handler for LSP traffic using httpun-ws lifecycle. *)
let add_routes router =
  let router =
    Http.Router.get "/api/v1/ide/lsp" (fun request reqd ->
      with_public_read
        (fun state _req reqd ->
          let origin =
            match Http.Request.header request "origin" with
            | Some o -> o
            | None -> "localhost"
          in

          Ws.Handshake.respond_with_upgrade ~sha1 reqd (fun () ->
            let ws_conn =
              Ws.Server_connection.create_websocket (fun wsd ->
                Log.Server.info "LSP WebSocket connected from %s" origin;

                let lsp_servers = Hashtbl.create 8 in
                let active_file = ref None in

                let init_msg = Yojson.Safe.to_string (`Assoc [
                  ("jsonrpc", `String "2.0");
                  ("method", `String "initialized");
                ]) in
                send_text wsd init_msg;

                { Ws.Websocket_connection.
                  frame = (fun ~opcode ~is_fin:_ ~len payload ->
                    match opcode with
                    | `Text | `Binary ->
                      read_frame_text ~len ~on_text:(fun msg ->
                        handle_lsp_message ~state ~wsd ~lsp_servers ~active_file msg
                      ) payload
                    | `Ping ->
                      (try Ws.Wsd.send_pong wsd
                       with exn ->
                         Log.Server.debug "LSP proxy send_pong failed: %s"
                           (Printexc.to_string exn));
                      Ws.Payload.close payload
                    | `Connection_close ->
                      Log.Server.info "LSP WebSocket disconnected";
                      Hashtbl.iter (fun lang_id _server ->
                        Log.Server.info "Shutting down LSP server for %s" lang_id
                        (* TODO: Actually kill process *)
                      ) lsp_servers;
                      Ws.Payload.close payload
                    | `Pong | `Continuation | `Other _ ->
                      Ws.Payload.close payload
                  );
                  eof = (fun ?error:_ () ->
                    Log.Server.info "LSP WebSocket EOF";
                    Hashtbl.iter (fun lang_id _server ->
                      Log.Server.info "Shutting down LSP server for %s" lang_id
                    ) lsp_servers
                  );
                })
            in
            ignore ws_conn)
        |> function Ok () -> () | Error e ->
          Log.Server.warn "WebSocket upgrade failed: %s" e)

      request reqd)
    router
  in
  router
