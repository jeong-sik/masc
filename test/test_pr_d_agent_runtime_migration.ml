open Alcotest

(** RFC-0084 host-config-cleanup-D — agent runtime root migration.

    PR-D migrates the 7 cross-process agent-identity scratch-file
    literals (`/tmp/.masc_agent[_mcp]_<sid>`) across 2 modules to
    the typed [Host_config.agent_runtime_root] field:

    - lib/mcp_server_eio_execute.ml (5 sites at 191, 210, 253, 331,
      570 in PR-1 audit; lines may have shifted by ±N after PR-D's
      module-init binding inserted earlier in the file)
    - lib/tool_inline_dispatch_coord.ml (2 sites at 187, 267)

    Each module has its own module-init binding because the modules
    don't share a common ancestor other than [Host_config] itself.

    Out of PR-D scope (intentional, separate follow-up cleanup):
    - The [Sys.getenv_opt "TERM_SESSION_ID" |> Option.value
      ~default:"default"] silent-collision issue documented in
      03-hardcode-path-audit.md Top10 #5.  PR-D is a pure
      typed-surface migration; the [default:"default"] fail-loud
      conversion belongs in its own PR so its behaviour change
      lands in isolation. *)

let pinned_tmp_agent_literal_count = 0
let pinned_agent_runtime_root_binding_count = 2

let read_file path =
  match In_channel.with_open_text path In_channel.input_all with
  | exception _ -> ""
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
  ; "lib/tool_inline_dispatch_coord.ml"
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
     consumer modules must be 0 after PR-D"
    pinned_tmp_agent_literal_count total
;;

let test_agent_runtime_root_binding_count () =
  let occurrences =
    count_across_files ~files:consumer_files
      ~needle:"Host_config.legacy_macos_default"
  in
  (check int)
    "Host_config.legacy_macos_default invoked exactly once per \
     consumer module (2 modules)"
    pinned_agent_runtime_root_binding_count occurrences
;;

let test_agent_runtime_root_field_value () =
  let d = Masc_mcp.Host_config.legacy_macos_default () in
  (check string)
    "Host_config.legacy_macos_default ().agent_runtime_root = /tmp today"
    "/tmp" d.agent_runtime_root
;;

let () =
  run
    "PR-D host-config-cleanup-D (agent runtime root)"
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
