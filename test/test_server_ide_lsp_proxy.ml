open Alcotest

module Lsp = Server_ide_lsp_proxy.For_testing
module Http = Masc.Http_server_eio

let member key = function
  | `Assoc fields -> List.assoc_opt key fields
  | _ -> None
;;

let test_initialize_handshake_is_read_only () =
  let result = Lsp.initialize_result_json () in
  let capabilities =
    match member "capabilities" result with
    | Some (`Assoc fields) -> fields
    | _ -> fail "initialize result must expose capabilities"
  in
  check bool "hover supported" true (List.mem_assoc "hoverProvider" capabilities);
  check
    bool
    "references supported"
    true
    (List.mem_assoc "referencesProvider" capabilities);
  check
    bool
    "execute command provider is not advertised"
    false
    (List.mem_assoc "executeCommandProvider" capabilities);
  check
    bool
    "workspace edit/applyEdit is not advertised"
    false
    (List.mem_assoc "workspace" capabilities)
;;

let test_workspace_root_initialize_stays_in_base () =
  let base_path = "/workspace/masc" in
  check
    string
    "inside root accepted"
    "/workspace/masc/subdir"
    (Lsp.workspace_root_for_initialize
       ~base_path
       "file:///workspace/masc/subdir/");
  check
    string
    "sibling root rejected"
    base_path
    (Lsp.workspace_root_for_initialize ~base_path "file:///workspace/masc-other");
  check
    string
    "outside root rejected"
    base_path
    (Lsp.workspace_root_for_initialize ~base_path "file:///tmp/outside")
;;

let test_file_uri_resolution_is_workspace_scoped () =
  let base = "/workspace/masc" in
  check
    (option string)
    "inside file becomes relative"
    (Some "lib/server.ml")
    (Lsp.resolve_relative ~base "file:///workspace/masc/lib/server.ml");
  check
    (option string)
    "encoded inside file decodes"
    (Some "docs/with space.md")
    (Lsp.resolve_relative ~base "file:///workspace/masc/docs/with%20space.md");
  check
    (option string)
    "lexical parent segment stays scoped"
    (Some "server.ml")
    (Lsp.resolve_relative ~base "file:///workspace/masc/lib/../server.ml");
  check
    (option string)
    "sibling prefix is rejected"
    None
    (Lsp.resolve_relative ~base "file:///workspace/masc-other/lib/server.ml");
  check
    (option string)
    "outside file is rejected"
    None
    (Lsp.resolve_relative ~base "file:///tmp/outside.ml");
  check
    (option string)
    "encoded traversal is rejected after decode"
    None
    (Lsp.resolve_relative ~base "file:///workspace/masc/sub%2F..%2F..%2Fetc/passwd")
;;

(* RFC-0281 Phase 2: [/api/v1/ide/lsp] must be a typed WebSocket-upgrade
   route ([Router.Ws]).  Only a Ws route receives the Gluten [upgrade]
   capability, so a regression to [Router.Plain] would silently
   reintroduce the undriven-socket defect (frames never read).  [add_routes]
   only registers the closure here — no process is spawned — so the
   [Eio_main.run] just supplies the switch + clock it captures. *)
let test_lsp_route_is_ws () =
  Eio_main.run (fun env ->
    Eio.Switch.run (fun sw ->
      let clock = Eio.Stdenv.clock env in
      let router =
        Server_ide_lsp_proxy.add_routes ~sw ~clock (Http.Router.create ())
      in
      let request = Httpun.Request.create `GET "/api/v1/ide/lsp" in
      match Http.Router.resolve router request with
      | `Matched route ->
        (match route.Http.Router.handler with
         | Http.Router.Ws _ -> ()
         | Http.Router.Plain _ ->
           fail "/api/v1/ide/lsp must be a Router.Ws route, not Plain")
      | `Method_not_allowed | `Not_found ->
        fail "/api/v1/ide/lsp route must resolve"))
;;

(* --- task-1691: typed LSP degraded-state contract --- *)

let bool_field j key =
  match member key j with
  | Some (`Bool b) -> b
  | _ -> fail (key ^ " must be a bool")
;;

(* [None] for a JSON null, [Some s] for a string, else fail. *)
let string_or_null j key =
  match member key j with
  | Some (`String s) -> Some s
  | Some `Null -> None
  | _ -> fail (key ^ " must be a string or null")
;;

(* An LSP process failure is surfaced as a typed overlay-only status, not
   hidden behind an overlay success (the old 9 handlers) nor a JSON-RPC error
   (old hover). *)
let test_overlay_only_status_is_typed () =
  let j = Lsp.lang_status_json ~lang_id:"ocaml" (Lsp.Overlay_only "spawn failed") in
  check bool "not connected" false (bool_field j "connected");
  check bool "overlay_only surfaced" true (bool_field j "overlay_only");
  check
    (option string)
    "last_error surfaced"
    (Some "spawn failed")
    (string_or_null j "last_error");
  check
    (option string)
    "command reflects the language mapping"
    (Some "ocamllsp")
    (string_or_null j "command")
;;

(* A connected language reports no degradation — distinct from overlay-only so
   the dashboard can tell a healthy LSP from a fallback. *)
let test_connected_status_is_typed () =
  let j = Lsp.lang_status_json ~lang_id:"ocaml" Lsp.Connected in
  check bool "connected" true (bool_field j "connected");
  check bool "not overlay_only" false (bool_field j "overlay_only");
  check
    (option string)
    "no last_error while connected"
    None
    (string_or_null j "last_error")
;;

(* A language with no configured LSP reports a null command, still typed as
   overlay-only rather than pretending to be a full LSP. *)
let test_unmapped_lang_has_null_command () =
  let j = Lsp.lang_status_json ~lang_id:"cobol" (Lsp.Overlay_only "no server") in
  check (option string) "unmapped lang has null command" None (string_or_null j "command");
  check bool "still typed overlay_only" true (bool_field j "overlay_only")
;;

(* The snapshot the dashboard receives lists every tracked language, sorted by
   id for a stable wire order. *)
let test_status_snapshot_is_sorted_and_complete () =
  let j =
    Lsp.status_snapshot_json
      [ "python", Lsp.Overlay_only "e"; "ocaml", Lsp.Connected ]
  in
  let langs =
    match member "langs" j with
    | Some (`List l) -> l
    | _ -> fail "snapshot must expose a langs list"
  in
  check int "one entry per tracked language" 2 (List.length langs);
  let lang_of = function
    | `Assoc f ->
      (match List.assoc_opt "lang" f with
       | Some (`String s) -> s
       | _ -> fail "entry missing lang")
    | _ -> fail "entry must be an object"
  in
  check (list string) "sorted by lang id" [ "ocaml"; "python" ] (List.map lang_of langs)
;;

(* --- task-1692: read-only method allowlist + no overlay write edits --- *)

(* Read-only navigation methods that reach the catch-all forwarder are
   proxied to the language server. *)
let test_read_methods_forward () =
  List.iter
    (fun m ->
      check
        bool
        (m ^ " forwards")
        true
        (Lsp.classify_forwarded_method m = Lsp.Forward_read_only))
    [ "textDocument/signatureHelp"
    ; "textDocument/typeDefinition"
    ; "textDocument/implementation"
    ; "textDocument/declaration"
    ; "textDocument/semanticTokens/full"
    ]
;;

(* Write-adjacent methods are refused so the observation plane never mutates
   the workspace. *)
let test_write_and_unknown_methods_rejected () =
  List.iter
    (fun m ->
      check
        bool
        (m ^ " rejected")
        true
        (Lsp.classify_forwarded_method m = Lsp.Reject_write_adjacent))
    [ "textDocument/rename"
    ; "textDocument/prepareRename"
    ; "textDocument/formatting"
    ; "textDocument/rangeFormatting"
    ; "textDocument/onTypeFormatting"
    ; "textDocument/willSaveWaitUntil"
    ; "workspace/executeCommand"
    ; "workspace/applyEdit"
    ];
  (match Lsp.classify_forwarded_method "textDocument/totallyMadeUpMethod" with
   | Lsp.Unknown_forwarded_method method_ ->
     check string "unknown method preserved" "textDocument/totallyMadeUpMethod" method_
   | Lsp.Forward_read_only | Lsp.Reject_write_adjacent ->
     Alcotest.fail "unknown method must stay diagnostic, not coerce")
;;

let rec json_contains_key key = function
  | `Assoc fields ->
    List.exists (fun (k, v) -> String.equal k key || json_contains_key key v) fields
  | `List items -> List.exists (json_contains_key key) items
  | _ -> false
;;

(* Overlay code actions must not carry a WorkspaceEdit/newText that writes the
   source buffer; the create affordance is offered through a MASC command
   instead (a separate write lane). *)
let test_code_actions_have_no_workspace_edit () =
  (* code_actions reads the annotation cache, which takes an Eio mutex, so it
     must run inside an Eio context. A fresh temp dir yields no annotations but
     still exercises the create action that used to carry the edit. *)
  Eio_main.run (fun env ->
    Fs_compat.set_fs (Eio.Stdenv.fs env);
    let base_dir = Filename.temp_dir "masc-lsp-proxy-" "" in
    Fun.protect
      ~finally:(fun () -> try Unix.rmdir base_dir with _ -> ())
      (fun () ->
         let actions =
           Lsp_overlay_provider.code_actions
             ~base_dir
             ~file_path:"a.ml"
             ~line:0
             ~diagnostics:[]
         in
         let j = `List actions in
         check bool "no WorkspaceEdit in code actions" false (json_contains_key "edit" j);
         check bool "no newText in code actions" false (json_contains_key "newText" j);
         check
           bool
           "create action offered via a command lane"
           true
           (json_contains_key "command" j)))
;;

let () =
  run
    "server_ide_lsp_proxy"
    [ ( "lsp_proxy"
      , [ test_case "initialize handshake is read-only" `Quick
            test_initialize_handshake_is_read_only
        ; test_case "initialize root stays inside workspace" `Quick
            test_workspace_root_initialize_stays_in_base
        ; test_case "file uri resolution is workspace scoped" `Quick
            test_file_uri_resolution_is_workspace_scoped
        ; test_case "/api/v1/ide/lsp is a Ws upgrade route" `Quick
            test_lsp_route_is_ws
        ] )
    ; ( "lsp_degraded_status"
      , [ test_case "LSP failure is a typed overlay_only status" `Quick
            test_overlay_only_status_is_typed
        ; test_case "connected status is typed and distinct" `Quick
            test_connected_status_is_typed
        ; test_case "unmapped language has null command" `Quick
            test_unmapped_lang_has_null_command
        ; test_case "status snapshot is sorted and complete" `Quick
            test_status_snapshot_is_sorted_and_complete
        ] )
    ; ( "lsp_read_only_allowlist"
      , [ test_case "read-only methods forward" `Quick test_read_methods_forward
        ; test_case "write/unknown methods are rejected" `Quick
            test_write_and_unknown_methods_rejected
        ; test_case "overlay code actions carry no write edit" `Quick
            test_code_actions_have_no_workspace_edit
        ] )
    ]
;;
