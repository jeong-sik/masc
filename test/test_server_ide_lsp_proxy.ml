open Alcotest

module Lsp = Server_ide_lsp_proxy.For_testing
module Http = Masc.Http_server_eio

let member key = function
  | `Assoc fields -> List.assoc_opt key fields
  | _ -> None
;;

let test_initialize_handshake_is_read_only () =
  (* The handshake also has to hand the client the tree its document URIs
     resolve against; a browser client cannot know the host path otherwise. *)
  let result = Lsp.initialize_result_json ~workspace_root:"/workspace/masc" () in
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
    (Lsp.resolve_relative ~base "file:///workspace/masc/sub%2F..%2F..%2Fetc/passwd");
  check
    (option string)
    "localhost file authority is local"
    (Some "lib/server.ml")
    (Lsp.resolve_relative ~base
       "file://localhost/workspace/masc/lib/server.ml");
  check
    (option string)
    "remote file authority is rejected"
    None
    (Lsp.resolve_relative ~base "file://remote/workspace/masc/lib/server.ml")
;;

let test_file_uri_resolution_rejects_symlink_escape () =
  let base = Filename.temp_dir "masc-lsp-base-" "" in
  let outside = Filename.temp_dir "masc-lsp-outside-" "" in
  let outside_file = Filename.concat outside "secret.ml" in
  let link = Filename.concat base "link.ml" in
  Fun.protect
    ~finally:(fun () ->
      (try Unix.unlink link with _ -> ());
      (try Unix.unlink outside_file with _ -> ());
      (try Unix.rmdir outside with _ -> ());
      (try Unix.rmdir base with _ -> ()))
    (fun () ->
       let oc = open_out outside_file in
       close_out oc;
       Unix.symlink outside_file link;
       check
         (option string)
         "symlink target outside workspace rejected"
         None
         (Lsp.resolve_relative ~base ("file://" ^ link)))
;;

let document_params ~uri line =
  `Assoc
    [ "textDocument", `Assoc [ "uri", `String uri ]
    ; "position", `Assoc [ "line", line ]
    ]
;;

let test_document_request_is_resolved_once () =
  let base = "/workspace/masc" in
  let uri = "file:///workspace/masc/lib/server.ml" in
  match Lsp.resolve_document_request ~anchor:base (document_params ~uri (`Int 7)) with
  | Error _ -> fail "expected an in-workspace document request"
  | Ok request ->
    check string "URI retained" uri request.uri;
    check string "relative path resolved" "lib/server.ml" request.relative_path;
    check (option int) "line resolved" (Some 7) request.line;
    (match request.language with
     | Lsp.Known_lang "ocaml" -> ()
     | Lsp.Known_lang language -> failf "unexpected language: %s" language
     | Lsp.Unknown_lang -> fail "expected the .ml language to resolve")
;;

let test_document_request_keeps_decode_failures_typed () =
  let base = "/workspace/masc" in
  let missing_uri = `Assoc [ "position", `Assoc [ "line", `Int 1 ] ] in
  (match Lsp.resolve_document_request ~anchor:base missing_uri with
   | Error Lsp.Missing_document_uri -> ()
   | Error Lsp.Document_uri_outside_workspace ->
     fail "missing URI must not be classified as an out-of-workspace path"
   | Ok _ -> fail "missing URI must fail decoding");
  let outside_uri = "file:///tmp/outside.ml" in
  (match
     Lsp.resolve_document_request ~anchor:base (document_params ~uri:outside_uri (`Int 1))
   with
   | Error Lsp.Document_uri_outside_workspace -> ()
   | Error Lsp.Missing_document_uri ->
     fail "outside URI must not be classified as missing"
   | Ok _ -> fail "outside URI must fail decoding");
  let inside_uri = "file:///workspace/masc/lib/server.ml" in
  match Lsp.resolve_document_request ~anchor:base (document_params ~uri:inside_uri (`Int (-1))) with
  | Error _ -> fail "negative line must not invalidate a document path"
  | Ok request -> check (option int) "negative line is absent" None request.line
;;

let test_dispatch_workers_are_parallelized () =
  check
    bool
    "more than one worker keeps slow LSP init off the read path"
    true
    (Lsp.inbound_dispatch_worker_count > 1)
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

(* An LSP process failure is surfaced as a typed unavailable status, not
   hidden behind an empty answer that reads like a real one, nor a JSON-RPC
   error (old hover). *)
let test_unavailable_status_is_typed () =
  let j = Lsp.lang_status_json ~lang_id:"ocaml" (Lsp.Unavailable "spawn failed") in
  check bool "not connected" false (bool_field j "connected");
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

(* A connected language reports no degradation — distinct from unavailable so
   the dashboard can tell a healthy LSP from a language with no server. *)
let test_connected_status_is_typed () =
  let j = Lsp.lang_status_json ~lang_id:"ocaml" Lsp.Connected in
  check bool "connected" true (bool_field j "connected");
  check
    (option string)
    "no last_error while connected"
    None
    (string_or_null j "last_error")
;;

(* A language with no configured LSP reports a null command, still typed as
   unavailable rather than pretending to be a full LSP. *)
let test_unmapped_lang_has_null_command () =
  let j = Lsp.lang_status_json ~lang_id:"cobol" (Lsp.Unavailable "no server") in
  check (option string) "unmapped lang has null command" None (string_or_null j "command");
  check bool "still not connected" false (bool_field j "connected")
;;

(* The health is two states, so the wire says so once: [connected] carries it
   and [last_error] says why when it is false. A second boolean that is
   [connected] negated gives a reader two fields to reconcile and a way to
   disagree with itself, so the object is pinned field by field. *)
let test_status_says_the_health_once () =
  List.iter
    (fun health ->
      match Lsp.lang_status_json ~lang_id:"ocaml" health with
      | `Assoc fields ->
        check (list string) "wire fields"
          [ "lang"; "connected"; "command"; "last_error" ]
          (List.map fst fields)
      | _ -> fail "lang status must be an object")
    [ Lsp.Connected; Lsp.Unavailable "spawn failed" ]
;;

(* The snapshot the dashboard receives lists every tracked language, sorted by
   id for a stable wire order. *)
let test_status_snapshot_is_sorted_and_complete () =
  let j =
    Lsp.status_snapshot_json
      [ "python", Lsp.Unavailable "e"; "ocaml", Lsp.Connected ]
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

(* --- task-1692: read-only method allowlist --- *)

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

(* One method, one table. definition, references, documentSymbol,
   documentHighlight and inlayHint were written in both after RFC-0378 rung E
   turned them into plain relays, so two lists decided the same thing about the
   same method (#28686). *)
let test_relayed_and_handled_tables_are_disjoint () =
  let handled = Lsp.handled_lsp_methods () |> List.map fst in
  let relayed = Lsp.relayed_lsp_methods () |> List.map fst in
  let both = List.filter (fun m -> List.mem m handled) relayed in
  check (list string) "no method is named by both tables" [] (List.sort String.compare both);
  (* The five still forward — from the catalog's Read_only classification, not
     from a second copy of their names. *)
  List.iter
    (fun m ->
      check bool (m ^ " forwards from the catalog") true
        (Lsp.classify_forwarded_method m = Lsp.Forward_read_only))
    [ "textDocument/definition"
    ; "textDocument/references"
    ; "textDocument/documentSymbol"
    ; "textDocument/documentHighlight"
    ; "textDocument/inlayHint"
    ]
;;

(* Every relayed method resolves to exactly the disposition its table row
   declares, so the table is the decision and not a hint. *)
let test_relayed_table_drives_the_decision () =
  List.iter
    (fun (method_, expected) ->
      check bool (method_ ^ " matches its row") true
        (Lsp.classify_forwarded_method method_ = expected))
    (Lsp.relayed_lsp_methods ())
;;

let require_handled_method_class method_ expected =
  match Lsp.classify_handled_lsp_method method_ with
  | Some actual ->
    check bool (method_ ^ " class") true (actual = expected)
  | None -> Alcotest.fail (method_ ^ " missing from handled LSP method catalog")
;;

let test_handled_lsp_method_catalog_is_classified () =
  let catalog = Lsp.handled_lsp_methods () in
  let methods = List.map fst catalog in
  check
    int
    "no duplicate handled method names"
    (List.length methods)
    (List.length (List.sort_uniq String.compare methods));
  check
    (list string)
    "canonical handled methods"
    [ "initialize"
    ; "initialized"
    ; "shutdown"
    ; "exit"
    ; "masc/lspStatus"
    ; "textDocument/didOpen"
    ; "textDocument/didChange"
    ; "textDocument/didSave"
    ; "textDocument/didClose"
    ; "textDocument/hover"
    ; "textDocument/codeLens"
    ; "textDocument/inlayHint"
    ; "textDocument/diagnostic"
    ; "textDocument/definition"
    ; "textDocument/references"
    ; "textDocument/completion"
    ; "textDocument/codeAction"
    ; "textDocument/documentSymbol"
    ; "textDocument/foldingRange"
    ; "textDocument/documentHighlight"
    ]
    methods;
  require_handled_method_class "initialize" Lsp.Lifecycle;
  require_handled_method_class "exit" Lsp.Lifecycle;
  require_handled_method_class "masc/lspStatus" Lsp.Status;
  require_handled_method_class "textDocument/didChange" Lsp.Mutation;
  require_handled_method_class "textDocument/didSave" Lsp.Mutation;
  require_handled_method_class "textDocument/hover" Lsp.Read_only;
  require_handled_method_class "textDocument/codeAction" Lsp.Read_only;
  check
    (option bool)
    "unknown handled catalog lookup stays absent"
    None
    (Option.map
       (fun (_ : Lsp.method_class) -> true)
       (Lsp.classify_handled_lsp_method "workspace/executeCommand"));
  check
    (option bool)
    "unknown document sync notification stays absent"
    None
    (Option.map
       (fun (_ : Lsp.method_class) -> true)
       (Lsp.classify_handled_lsp_method "textDocument/didSomethingElse"));
  (match Lsp.classify_forwarded_method "textDocument/didSomethingElse" with
   | Lsp.Unknown_forwarded_method method_ ->
     check string "unknown document sync method preserved" "textDocument/didSomethingElse" method_
   | Lsp.Forward_read_only | Lsp.Reject_write_adjacent ->
     Alcotest.fail "unknown document sync method must not enter forwarding allowlists")
;;

let test_unknown_language_is_typed () =
  match Lsp.resolve_lang "README.unknown_extension_for_lsp" with
  | Lsp.Unknown_lang -> ()
  | Lsp.Known_lang lang -> Alcotest.fail ("unexpected known lang: " ^ lang)
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
        ; test_case "file uri resolution rejects symlink escape" `Quick
            test_file_uri_resolution_rejects_symlink_escape
        ; test_case "document request resolves once" `Quick
            test_document_request_is_resolved_once
        ; test_case "document request decode failures stay typed" `Quick
            test_document_request_keeps_decode_failures_typed
        ; test_case "dispatch workers are parallelized" `Quick
            test_dispatch_workers_are_parallelized
        ; test_case "/api/v1/ide/lsp is a Ws upgrade route" `Quick
            test_lsp_route_is_ws
        ] )
    ; ( "lsp_degraded_status"
      , [ test_case "LSP failure is a typed unavailable status" `Quick
            test_unavailable_status_is_typed
        ; test_case "the status says the health once" `Quick
            test_status_says_the_health_once
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
        ; test_case "handled method catalog is classified" `Quick
            test_handled_lsp_method_catalog_is_classified
        ; test_case "relayed and handled tables are disjoint" `Quick
            test_relayed_and_handled_tables_are_disjoint
        ; test_case "relayed table drives the decision" `Quick
            test_relayed_table_drives_the_decision
        ; test_case "unknown language is typed" `Quick test_unknown_language_is_typed
        ] )
    ]
;;
