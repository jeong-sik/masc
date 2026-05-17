open Alcotest

(** RFC-0084 host-config-cleanup-E — Fleet worker sandbox root migration.

    PR-E migrates [lib/worker_dev_tools.ml:85] from the ad-hoc
    hard-coded home workspace literal to
    [Host_config.host ()].sandbox_workspace_root,
    closing the first of the 11 host-hardcode call-sites that PR-12
    surfaced as typed-but-dormant.

    The pins guard against:
    - the literal regressing into [worker_dev_tools.ml]
      ([pinned_home_me_literal_count = 0])
    - the [sandbox_workspace_root] field drifting away from the
      [MASC_BASE_PATH] / [/tmp/masc-fleet] contract
      (also covered by [test_host_config_resolution] but pinned
      here so the migration intent is explicit). *)

(** The old home workspace literal must not appear in
    [lib/worker_dev_tools.ml] after PR-E. *)
let pinned_home_me_literal_count = 0
let old_home_me_literal = String.concat " " [ "Filename.concat"; "home"; {|"me"|} ]

let count_literal_occurrences ~path ~literal =
  match In_channel.with_open_text path In_channel.input_all with
  | exception _ -> -1
  | content ->
    let rec loop i acc =
      let next = String.index_from_opt content i literal.[0] in
      match next with
      | None -> acc
      | Some j ->
        let len = String.length literal in
        if j + len <= String.length content
           && String.sub content j len = literal
        then loop (j + len) (acc + 1)
        else loop (j + 1) acc
    in
    loop 0 0
;;

let test_no_home_me_literal_in_worker_dev_tools () =
  let path = "lib/worker_dev_tools.ml" in
  let occurrences =
    count_literal_occurrences ~path ~literal:old_home_me_literal
  in
  (check int)
    (Printf.sprintf
       "old home workspace literal in %s must be 0 after PR-E \
        (Host_config.sandbox_workspace_root migration)"
       path)
    pinned_home_me_literal_count occurrences
;;

let test_sandbox_workspace_root_contract () =
  let d = Host_config.host () in
  let acceptable_roots =
    match Sys.getenv_opt "MASC_BASE_PATH" with
    | Some root when String.trim root <> "" ->
      [ Env_config_core.normalize_masc_base_path_input root ]
    | _ -> [ "/tmp/masc-fleet" ]
  in
  let actual = d.sandbox_workspace_root in
  let matched = List.exists (String.equal actual) acceptable_roots in
  (check bool)
    (Printf.sprintf
       "Host_config.host ().sandbox_workspace_root = %S must \
        be one of [%s]"
       actual
       (String.concat "; " acceptable_roots))
    true matched
;;

let test_host_config_call_in_worker_dev_tools () =
  let path = "lib/worker_dev_tools.ml" in
  let occurrences =
    count_literal_occurrences ~path
      ~literal:"Host_config.host"
  in
  (check bool)
    "Host_config.host must be called from \
     lib/worker_dev_tools.ml after PR-E"
    true (occurrences >= 1)
;;

let () =
  run
    "PR-E host-config-cleanup-E (sandbox_workspace_root)"
    [ ( "pr-e-sandbox-root"
      , [ test_case "no-home-me-literal-in-worker-dev-tools" `Quick
            test_no_home_me_literal_in_worker_dev_tools
        ; test_case "sandbox-workspace-root-contract" `Quick
            test_sandbox_workspace_root_contract
        ; test_case "host-config-call-in-worker-dev-tools" `Quick
            test_host_config_call_in_worker_dev_tools
        ] )
    ]
;;
