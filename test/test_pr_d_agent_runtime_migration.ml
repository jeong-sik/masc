open Alcotest

(** RFC-0084 host-config-cleanup-D — retired agent scratch-file runtime.

    The old `/tmp/.masc_agent[_mcp]_<sid>` bridge was first moved behind
    [Host_config.agent_runtime_root], then removed once
    [Client_registry_eio] owned MCP-session identity continuity.  This
    ratchet keeps the old sidecar file surface from coming back in the
    dispatcher modules. *)

let pinned_tmp_agent_literal_count = 0
let pinned_agent_runtime_root_binding_count = 0

let consumer_files =
  [ "lib/mcp_server_eio_execute.ml"
  ; "lib/mcp_tool_runtime_workspace.ml"
  ]
;;

let test_no_tmp_agent_literals_in_consumers () =
  (* Both prefix variants in one sweep. *)
  let needles =
    [ "/tmp/.masc_agent_%s"
    ; "/tmp/.masc_agent_mcp_%s"
    ]
  in
  let total =
    List.fold_left
      (fun acc needle ->
        acc
        + Ast_grep.count_string_literals_across_files
            ~module_paths:consumer_files
            ~needle)
      0 needles
  in
  (check int)
    "literal occurrences of `/tmp/.masc_agent[_mcp]_<sid>` in the 2 \
     consumer modules must remain 0"
    pinned_tmp_agent_literal_count total
;;

let test_agent_runtime_root_binding_count () =
  let occurrences =
    Ast_grep.count_calls_across_files
      ~module_paths:consumer_files
      ~callee:"Host_config.host"
  in
  (check int)
    "dispatcher modules no longer bind Host_config.agent_runtime_root"
    pinned_agent_runtime_root_binding_count occurrences
;;

let test_agent_runtime_root_field_value () =
  let d = Host_config.host () in
  let expected = Filename.get_temp_dir_name () in
  (check string)
    "Host_config.host ().agent_runtime_root follows host temp dir"
    expected
    d.agent_runtime_root
;;

let () =
  run
    "agent scratch-file runtime ratchet"
    [ ( "pr-d-agent-runtime"
      , [ test_case "no-tmp-agent-literals-in-consumers" `Quick
            test_no_tmp_agent_literals_in_consumers
        ; test_case "agent-runtime-root-binding-count" `Quick
            test_agent_runtime_root_binding_count
        ; test_case "agent-runtime-root-field-value" `Quick
            test_agent_runtime_root_field_value
        ] )
    ]
;;
