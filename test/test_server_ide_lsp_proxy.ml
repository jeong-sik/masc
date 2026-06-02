open Alcotest

module Lsp = Masc_mcp.Server_ide_lsp_proxy.For_testing

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
  let base_path = "/workspace/masc-mcp" in
  check
    string
    "inside root accepted"
    "/workspace/masc-mcp/subdir"
    (Lsp.workspace_root_for_initialize
       ~base_path
       "file:///workspace/masc-mcp/subdir/");
  check
    string
    "sibling root rejected"
    base_path
    (Lsp.workspace_root_for_initialize ~base_path "file:///workspace/masc-mcp-other");
  check
    string
    "outside root rejected"
    base_path
    (Lsp.workspace_root_for_initialize ~base_path "file:///tmp/outside")
;;

let test_file_uri_resolution_is_workspace_scoped () =
  let base = "/workspace/masc-mcp" in
  check
    (option string)
    "inside file becomes relative"
    (Some "lib/server.ml")
    (Lsp.resolve_relative ~base "file:///workspace/masc-mcp/lib/server.ml");
  check
    (option string)
    "encoded inside file decodes"
    (Some "docs/with space.md")
    (Lsp.resolve_relative ~base "file:///workspace/masc-mcp/docs/with%20space.md");
  check
    (option string)
    "sibling prefix is rejected"
    None
    (Lsp.resolve_relative ~base "file:///workspace/masc-mcp-other/lib/server.ml");
  check
    (option string)
    "outside file is rejected"
    None
    (Lsp.resolve_relative ~base "file:///tmp/outside.ml")
;;

let test_missing_proc_mgr_does_not_upgrade () =
  check
    bool
    "missing process manager blocks websocket upgrade"
    true
    (match Lsp.route_admission ~has_proc_mgr:false with
     | Lsp.Missing_process_manager -> true
     | Lsp.Upgrade_websocket -> false);
  check
    bool
    "process manager allows websocket upgrade"
    true
    (match Lsp.route_admission ~has_proc_mgr:true with
     | Lsp.Upgrade_websocket -> true
     | Lsp.Missing_process_manager -> false)
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
        ; test_case "missing proc_mgr blocks websocket upgrade" `Quick
            test_missing_proc_mgr_does_not_upgrade
        ] )
    ]
;;
