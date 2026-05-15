open Alcotest

(** RFC-0084 PR-I-2.c — otel_dispatch_hook typed post-hook migration. *)

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

let test_no_legacy_register_in_otel_hook () =
  let content = read_file "lib/otel/otel_dispatch_hook.ml" in
  (check int)
    "Tool_dispatch.register_post_hook must be 0 in \
     lib/otel/otel_dispatch_hook.ml after PR-I-2.c"
    0
    (count_substring ~haystack:content
       ~needle:"Tool_dispatch.register_post_hook")
;;

let test_typed_register_present_in_otel_hook () =
  let content = read_file "lib/otel/otel_dispatch_hook.ml" in
  (check int)
    "Tool_dispatch.register_typed_post_hook appears exactly once \
     in lib/otel/otel_dispatch_hook.ml after PR-I-2.c"
    1
    (count_substring ~haystack:content
       ~needle:"Tool_dispatch.register_typed_post_hook")
;;

let test_handled_guard_preserved () =
  let content = read_file "lib/otel/otel_dispatch_hook.ml" in
  (check bool)
    "lib/otel/otel_dispatch_hook.ml must guard [on_tool_result] with \
     (Handled, Some _)"
    true
    (count_substring ~haystack:content
       ~needle:"Dispatch_outcome.Handled, Some" >= 1)
;;

let () =
  run
    "PR-I-2.c otel_dispatch_hook typed post-hook"
    [ ( "pr-i-2c-otel-hook"
      , [ test_case "no-legacy-register-in-otel-hook" `Quick
            test_no_legacy_register_in_otel_hook
        ; test_case "typed-register-present-in-otel-hook" `Quick
            test_typed_register_present_in_otel_hook
        ; test_case "handled-guard-preserved" `Quick
            test_handled_guard_preserved
        ] )
    ]
;;
