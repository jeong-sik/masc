open Alcotest

(** RFC-0084 PR-I-2.e — server_bootstrap_loops typed post-hook
    migration.  Last of the 5 observer migrations sketched in
    Dispatch_outcome.mli.  Behaviour-preserving: Tool_metrics.record
    + Tool_metrics_persist.enqueue fire only on (Handled, Some r). *)

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

let test_no_legacy_register_in_bootstrap_loops () =
  let content = read_file "lib/server/server_bootstrap_loops.ml" in
  (check int)
    "Tool_dispatch.register_post_hook must be 0 in \
     lib/server/server_bootstrap_loops.ml after PR-I-2.e"
    0
    (count_substring ~haystack:content
       ~needle:"Tool_dispatch.register_post_hook")
;;

let test_typed_register_present_in_bootstrap_loops () =
  let content = read_file "lib/server/server_bootstrap_loops.ml" in
  (check bool)
    "Tool_dispatch.register_typed_post_hook appears (>= 1) in \
     lib/server/server_bootstrap_loops.ml after PR-I-2.e"
    true
    (count_substring ~haystack:content
       ~needle:"Tool_dispatch.register_typed_post_hook" >= 1)
;;

let test_handled_guard_preserved () =
  let content = read_file "lib/server/server_bootstrap_loops.ml" in
  (check bool)
    "bootstrap_loops must guard the persist hook with (Handled, Some _)"
    true
    (count_substring ~haystack:content
       ~needle:"Dispatch_outcome.Handled, Some" >= 1)
;;

(** Verify all 5 in-tree register_post_hook callers are now migrated
    (PR-I-2.e is the last of the 5). *)
let test_no_legacy_callers_in_tree () =
  let files =
    [ "lib/tool_metrics.ml"
    ; "lib/tool_usage_log.ml"
    ; "lib/otel/otel_dispatch_hook.ml"
    ; "lib/tool_output_validation.ml"
    ; "lib/server/server_bootstrap_loops.ml"
    ]
  in
  let total =
    List.fold_left
      (fun acc path ->
        acc + count_substring ~haystack:(read_file path)
                ~needle:"Tool_dispatch.register_post_hook")
      0 files
  in
  (check int)
    "all 5 in-tree register_post_hook callers must be migrated \
     (sum across the 5 known sites = 0 after PR-I-2.e)"
    0 total
;;

let () =
  run
    "PR-I-2.e server_bootstrap_loops typed post-hook"
    [ ( "pr-i-2e-bootstrap-loops"
      , [ test_case "no-legacy-register-in-bootstrap-loops" `Quick
            test_no_legacy_register_in_bootstrap_loops
        ; test_case "typed-register-present-in-bootstrap-loops" `Quick
            test_typed_register_present_in_bootstrap_loops
        ; test_case "handled-guard-preserved" `Quick
            test_handled_guard_preserved
        ; test_case "no-legacy-callers-in-tree" `Quick
            test_no_legacy_callers_in_tree
        ] )
    ]
;;
