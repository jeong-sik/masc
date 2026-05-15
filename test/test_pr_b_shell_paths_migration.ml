open Alcotest

(** RFC-0084 host-config-cleanup-B — shell binary path migration.

    PR-B migrates the absolute literals for the host bash + zsh
    binaries to the typed [Host_config.host_bash] / [host_zsh]
    fields.

    bash sites:
    - lib/keeper/keeper_shell_bash.ml (2 sites: keeper_bash exec
      argv) — single [let host_bash = ...] binding at module top

    zsh sites:
    - lib/keeper/keeper_gh_shared.ml (1 site: gh cache fetch argv)
    - lib/keeper/keeper_exec_preflight.ml (2 sites: gh auth status
      + preflight cache fetch argv)
    - lib/keeper/keeper_tool_pr_review.ml (1 site: PR review argv)

    Each module has its own module-init binding (rather than one
    shared SSOT) because the modules don't share a common ancestor
    other than [Host_config] itself, and per-module bindings keep
    the dependency local.

    Behaviour byte-identical today; a future PR can flip
    [Host_config.host] to PATH-resolved binaries
    for NixOS / Alpine portability without touching this PR's call
    sites.

    [lib/exec/test/test_exec_run_json.ml:89] also contains a
    [/bin/bash] literal but lives in the [lib/exec/test/] sub-tree
    (separate dune stanza) and is a *test fixture*, not a production
    dispatch path — out of PR-B scope. *)

let pinned_bash_literal_count = 0
let pinned_zsh_literal_count = 0
let pinned_bash_binding_count = 1
let pinned_zsh_binding_count = 3

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

let bash_consumer_files = [ "lib/keeper/keeper_shell_bash.ml" ]

let zsh_consumer_files =
  [ "lib/keeper/keeper_gh_shared.ml"
  ; "lib/keeper/keeper_exec_preflight.ml"
  ; "lib/keeper/keeper_tool_pr_review.ml"
  ]
;;

let test_no_bash_literals_in_consumer_files () =
  let occurrences =
    count_across_files ~files:bash_consumer_files
      ~needle:{|"/bin/bash"|}
  in
  (check int)
    "literal `\"/bin/bash\"` in 1 keeper consumer file must be 0 after PR-B"
    pinned_bash_literal_count occurrences
;;

let test_no_zsh_literals_in_consumer_files () =
  let occurrences =
    count_across_files ~files:zsh_consumer_files
      ~needle:{|"/bin/zsh"|}
  in
  (check int)
    "literal `\"/bin/zsh\"` in 3 keeper consumer files must be 0 after PR-B"
    pinned_zsh_literal_count occurrences
;;

let test_bash_binding_invoked_exactly_once () =
  let occurrences =
    count_across_files ~files:bash_consumer_files
      ~needle:"Host_config.host"
  in
  (check int)
    "Host_config.host invoked exactly once across \
     bash consumer files"
    pinned_bash_binding_count occurrences
;;

let test_zsh_binding_invoked_per_module () =
  let occurrences =
    count_across_files ~files:zsh_consumer_files
      ~needle:"Host_config.host"
  in
  (check int)
    "Host_config.host invoked once per zsh consumer \
     module (3 modules)"
    pinned_zsh_binding_count occurrences
;;

let test_host_config_field_values () =
  let d = Masc_mcp.Host_config.host () in
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
            test_bash_binding_invoked_exactly_once
        ; test_case "zsh-binding-invoked-per-module" `Quick
            test_zsh_binding_invoked_per_module
        ; test_case "host-config-field-values" `Quick
            test_host_config_field_values
        ] )
    ]
;;
