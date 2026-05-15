open Alcotest

(** RFC-0084 PR-I-2.b — Tool_usage_log typed post-hook migration.

    Behaviour-preserving: log_call only fires on the [Handled] arm
    with [Some r], same as the legacy register_post_hook. *)

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

let test_no_legacy_register_in_usage_log () =
  let content = read_file "lib/tool_usage_log.ml" in
  (check int)
    "Tool_dispatch.register_post_hook must not appear in \
     lib/tool_usage_log.ml after PR-I-2.b"
    0
    (count_substring ~haystack:content
       ~needle:"Tool_dispatch.register_post_hook")
;;

let test_typed_register_present_in_usage_log () =
  let content = read_file "lib/tool_usage_log.ml" in
  (check int)
    "Tool_dispatch.register_typed_post_hook appears exactly once \
     in lib/tool_usage_log.ml after PR-I-2.b"
    1
    (count_substring ~haystack:content
       ~needle:"Tool_dispatch.register_typed_post_hook")
;;

let test_handled_guard_preserved () =
  let content = read_file "lib/tool_usage_log.ml" in
  (check bool)
    "lib/tool_usage_log.ml must guard [log_call] with the (Handled, \
     Some _) match arm so non-Handled outcomes do not log"
    true
    (count_substring ~haystack:content
       ~needle:"Dispatch_outcome.Handled, Some" >= 1)
;;

let () =
  run
    "PR-I-2.b Tool_usage_log typed post-hook"
    [ ( "pr-i-2b-tool-usage-log"
      , [ test_case "no-legacy-register-in-usage-log" `Quick
            test_no_legacy_register_in_usage_log
        ; test_case "typed-register-present-in-usage-log" `Quick
            test_typed_register_present_in_usage_log
        ; test_case "handled-guard-preserved" `Quick
            test_handled_guard_preserved
        ] )
    ]
;;
