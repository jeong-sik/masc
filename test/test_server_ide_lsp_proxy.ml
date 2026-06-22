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
    "sibling prefix is rejected"
    None
    (Lsp.resolve_relative ~base "file:///workspace/masc-other/lib/server.ml");
  check
    (option string)
    "outside file is rejected"
    None
    (Lsp.resolve_relative ~base "file:///tmp/outside.ml")
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
    ]
;;
