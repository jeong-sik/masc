open Alcotest

(** RFC-0084 host-config-cleanup-B — shell binary path migration.

    PR-B migrates the absolute literals for the host bash + zsh
    binaries to the typed [Host_config.host_bash] / [host_zsh]
    fields.

    bash sites:
    - none: tool_execute is Shell-IR based and no longer keeps a
      module-local host_bash binding

    zsh sites:
    - none: keeper PR review wrappers are retired from active routing,
      and the remaining legacy helpers no longer keep module-local zsh
      bindings

    Each module has its own module-init binding (rather than one
    shared SSOT) because the modules don't share a common ancestor
    other than [Host_config] itself, and per-module bindings keep
    the dependency local.

    Behaviour byte-identical today; a future PR can flip
    [Host_config.host] to PATH-resolved binaries
    for NixOS / Alpine portability without touching this PR's call
    sites.

    Background auto-promotion tests were removed with the legacy
    tool_execute background surface, so no [lib/exec/test/] bash
    fixture is exempted here. *)

let pinned_bash_literal_count = 0
let pinned_zsh_literal_count = 0
let pinned_bash_binding_count = 0
let pinned_zsh_binding_count = 0

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

let execute_consumer_files = [ "lib/keeper/keeper_tool_execute_runtime.ml" ]

let zsh_consumer_files = []

let test_no_bash_literals_in_consumer_files () =
  let occurrences =
    count_across_files ~files:execute_consumer_files
      ~needle:{|"/bin/bash"|}
  in
  (check int)
    "literal `\"/bin/bash\"` in keeper consumer files must be 0 after PR-B"
    pinned_bash_literal_count occurrences
;;

let test_no_zsh_literals_in_consumer_files () =
  let occurrences =
    count_across_files ~files:zsh_consumer_files
      ~needle:{|"/bin/zsh"|}
  in
  (check int)
    "literal `\"/bin/zsh\"` in keeper consumer files must be 0 after PR-B"
    pinned_zsh_literal_count occurrences
;;

let test_execute_binding_invoked_exactly_once () =
  let occurrences =
    count_across_files ~files:execute_consumer_files
      ~needle:"(Host_config.host ()).host_bash"
  in
  (check int)
    "Host_config.host_bash binding is no longer needed by Execute consumers"
    pinned_bash_binding_count occurrences
;;

let test_zsh_binding_invoked_per_module () =
  let occurrences =
    count_across_files ~files:zsh_consumer_files
      ~needle:"Host_config.host ()"
  in
  (check int)
    "Host_config.host zsh binding is no longer needed by Execute consumers"
    pinned_zsh_binding_count occurrences
;;

let test_host_config_field_values () =
  let d = Host_config.host () in
  (check string)
    "Host_config.host ().host_bash = /bin/bash today"
    "/bin/bash" d.host_bash;
  (check string)
    "Host_config.host ().host_zsh = /bin/zsh today"
    "/bin/zsh" d.host_zsh
;;

let () =
  run
    "PR-B host-config-cleanup-B (shell paths)"
    [ ( "pr-b-shell-paths"
      , [ test_case "no-bash-literals-in-consumer-files" `Quick
            test_no_bash_literals_in_consumer_files
        ; test_case "no-zsh-literals-in-consumer-files" `Quick
            test_no_zsh_literals_in_consumer_files
        ; test_case "bash-binding-invoked-exactly-once" `Quick
            test_execute_binding_invoked_exactly_once
        ; test_case "zsh-binding-invoked-per-module" `Quick
            test_zsh_binding_invoked_per_module
        ; test_case "host-config-field-values" `Quick
            test_host_config_field_values
        ] )
    ]
;;
