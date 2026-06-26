open Alcotest

(** RFC-0084 host-config-cleanup-D — retired agent scratch-file runtime.

    The old `/tmp/.masc_agent[_mcp]_<sid>` bridge was first moved behind
    [Host_config.agent_runtime_root], then removed once
    [Client_registry_eio] owned MCP-session identity continuity.  This
    ratchet keeps the old sidecar file surface from coming back in the
    dispatcher modules. *)

let pinned_tmp_agent_literal_count = 0
let pinned_agent_runtime_root_binding_count = 0

let repo_path relative =
  match Sys.getenv_opt "DUNE_SOURCEROOT" with
  | Some root -> Filename.concat root relative
  | None -> relative
;;

let read_file path =
  let path = if Filename.is_relative path then repo_path path else path in
  match In_channel.with_open_text path In_channel.input_all with
  | exception exn ->
      Alcotest.failf
        "failed to read source path %S: %s"
        path
        (Printexc.to_string exn)
  | content -> content
;;

let count_substring ~haystack ~needle =
  let rec loop i acc =
    let next = String.index_from_opt haystack i needle.[0] in
    match next with
    | None -> acc
    | Some j ->
      let len = String.length needle in
      if j + len <= String.length haystack
         && String.sub haystack j len = needle
      then loop (j + len) (acc + 1)
      else loop (j + 1) acc
  in
  loop 0 0
;;

let count_across_files ~files ~needle =
  List.fold_left
    (fun acc path ->
      acc + count_substring ~haystack:(read_file path) ~needle)
    0 files
;;

let consumer_files =
  [ "lib/mcp_server_eio_execute.ml"
  ; "lib/mcp_tool_runtime_workspace.ml"
  ]
;;

let test_no_tmp_agent_literals_in_consumers () =
  (* Both prefix variants in one sweep. *)
  let needles =
    [ {|"/tmp/.masc_agent_%s"|}
    ; {|"/tmp/.masc_agent_mcp_%s"|}
    ]
  in
  let total =
    List.fold_left
      (fun acc needle -> acc + count_across_files ~files:consumer_files ~needle)
      0 needles
  in
  (check int)
    "literal occurrences of `/tmp/.masc_agent[_mcp]_<sid>` in the 2 \
     consumer modules must remain 0"
    pinned_tmp_agent_literal_count total
;;

let test_agent_runtime_root_binding_count () =
  let occurrences =
    count_across_files ~files:consumer_files
      ~needle:"Host_config.host ()"
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
