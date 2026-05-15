open Alcotest

(** RFC-0084 PR-I-2.a — Tool_metrics typed post-hook migration.

    PR-I-2.a migrates [lib/tool_metrics.ml]'s [install] from
    [Tool_dispatch.register_post_hook] (legacy mutating signature
    fired inside [dispatch] on the [Handled] arm only) to
    [Tool_dispatch.register_typed_post_hook] (typed observer fired
    from [guarded_dispatch] on every {!Dispatch_outcome.t} arm).

    The migration is *behaviour-preserving*: [record] is only
    invoked when [outcome = Handled && result = Some _], so today's
    metric counts remain identical.  Adding per-arm counters for
    the non-[Handled] outcomes is out of scope; a separate
    follow-up may layer that on top.

    Pins:
    - [Tool_dispatch.register_post_hook] no longer appears in
      [lib/tool_metrics.ml] (0 occurrences)
    - [Tool_dispatch.register_typed_post_hook] appears exactly once
    - the [Handled] guard is preserved (regression guard against
      accidental "count every dispatch" overcounting). *)

let pinned_legacy_register_count = 0
let pinned_typed_register_count = 1

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

let test_no_legacy_register_in_tool_metrics () =
  let content = read_file "lib/tool_metrics.ml" in
  let occurrences =
    count_substring ~haystack:content
      ~needle:"Tool_dispatch.register_post_hook"
  in
  (check int)
    "Tool_dispatch.register_post_hook must not appear in \
     lib/tool_metrics.ml after PR-I-2.a"
    pinned_legacy_register_count occurrences
;;

let test_typed_register_present_in_tool_metrics () =
  let content = read_file "lib/tool_metrics.ml" in
  let occurrences =
    count_substring ~haystack:content
      ~needle:"Tool_dispatch.register_typed_post_hook"
  in
  (check int)
    "Tool_dispatch.register_typed_post_hook appears exactly once \
     in lib/tool_metrics.ml after PR-I-2.a"
    pinned_typed_register_count occurrences
;;

let test_handled_guard_preserved () =
  let content = read_file "lib/tool_metrics.ml" in
  (* The [Handled, Some r] guard is the behaviour-preserving seam:
     [record] runs only on the success arm, matching the legacy
     post_hook semantics. *)
  let occurrences =
    count_substring ~haystack:content
      ~needle:"Dispatch_outcome.Handled, Some"
  in
  (check bool)
    "lib/tool_metrics.ml must guard [record] with the (Handled, \
     Some _) match arm so non-Handled outcomes do not overcount"
    true (occurrences >= 1)
;;

let () =
  run
    "PR-I-2.a Tool_metrics typed post-hook"
    [ ( "pr-i-2a-tool-metrics"
      , [ test_case "no-legacy-register-in-tool-metrics" `Quick
            test_no_legacy_register_in_tool_metrics
        ; test_case "typed-register-present-in-tool-metrics" `Quick
            test_typed_register_present_in_tool_metrics
        ; test_case "handled-guard-preserved" `Quick
            test_handled_guard_preserved
        ] )
    ]
;;
