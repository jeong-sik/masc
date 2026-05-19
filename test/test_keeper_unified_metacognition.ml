open Alcotest

module HK = Masc_mcp.Keeper_hooks_oas

let contains_substring haystack needle =
  let hay_len = String.length haystack in
  let needle_len = String.length needle in
  let rec loop i =
    if i + needle_len > hay_len
    then false
    else if String.sub haystack i needle_len = needle
    then true
    else loop (i + 1)
  in
  needle_len = 0 || loop 0
;;

let tool_log_entry ?ts tool_name =
  let ts = Option.value ~default:(Time_compat.now ()) ts in
  `Assoc [ "tool", `String tool_name; "ts", `Float ts ]
;;

let test_on_idle_nudge_at_first_idle () =
  let decision =
    HK.on_idle_decision_with_threshold
      ~skip_at:3
      ~consecutive_idle_turns:1
      ~allowed_tools:[]
      ~tool_names:[ "keeper_board_list"; "keeper_tasks_list" ]
  in
  match decision with
  | Agent_sdk.Hooks.Nudge msg ->
    check
      bool
      "nudge mentions repeated tools"
      true
      (contains_substring msg "keeper_board_list")
  | other ->
    fail
      (Printf.sprintf
         "expected Nudge, got %s"
         (Agent_sdk.Hooks.decision_kind_to_string
            (Agent_sdk.Hooks.classify_decision other)))
;;

let test_on_idle_final_warning_before_skip () =
  let decision =
    HK.on_idle_decision_with_threshold
      ~skip_at:3
      ~consecutive_idle_turns:2
      ~allowed_tools:[]
      ~tool_names:[ "keeper_board_list" ]
  in
  match decision with
  | Agent_sdk.Hooks.Nudge msg ->
    check
      bool
      "final warning mentions stay_silent"
      true
      (contains_substring msg "stay_silent")
  | other ->
    fail
      (Printf.sprintf
         "expected Nudge (final warning), got %s"
         (Agent_sdk.Hooks.decision_kind_to_string
            (Agent_sdk.Hooks.classify_decision other)))
;;

let test_on_idle_skip_at_repeated_idle () =
  let decision =
    HK.on_idle_decision_with_threshold
      ~skip_at:3
      ~consecutive_idle_turns:3
      ~allowed_tools:[]
      ~tool_names:[ "keeper_board_list" ]
  in
  match decision with
  | Agent_sdk.Hooks.Skip -> ()
  | other ->
    fail
      (Printf.sprintf
         "expected Skip, got %s"
         (Agent_sdk.Hooks.decision_kind_to_string
            (Agent_sdk.Hooks.classify_decision other)))
;;

let test_on_idle_skip_with_custom_threshold () =
  let decision =
    HK.on_idle_decision_with_threshold
      ~skip_at:2
      ~consecutive_idle_turns:2
      ~allowed_tools:[]
      ~tool_names:[ "keeper_board_list" ]
  in
  match decision with
  | Agent_sdk.Hooks.Skip -> ()
  | other ->
    fail
      (Printf.sprintf
         "expected Skip at custom threshold 2, got %s"
         (Agent_sdk.Hooks.decision_kind_to_string
            (Agent_sdk.Hooks.classify_decision other)))
;;

let test_recent_tool_streak_count_counts_tail_matches () =
  let now = Time_compat.now () in
  let entries =
    [ tool_log_entry ~ts:(now -. 30.0) "keeper_fs_read"
    ; tool_log_entry ~ts:(now -. 20.0) "masc_status"
    ; tool_log_entry ~ts:(now -. 10.0) "masc_status"
    ]
  in
  check
    int
    "tail streak count"
    2
    (HK.recent_tool_streak_count ~tool_name:"masc_status" entries)
;;

let test_recent_tool_streak_count_ignores_stale_entries () =
  let now = Time_compat.now () in
  let entries =
    [ tool_log_entry ~ts:(now -. 1800.0) "masc_status"
    ; tool_log_entry ~ts:(now -. 10.0) "masc_status"
    ]
  in
  check
    int
    "stale entry does not extend streak"
    1
    (HK.recent_tool_streak_count ~within_sec:60.0 ~tool_name:"masc_status" entries)
;;

let () =
  run
    "keeper unified metacognition"
    [ ( "metacognition"
      , [ test_case "on_idle nudge at first idle" `Quick test_on_idle_nudge_at_first_idle
        ; test_case
            "on_idle final warning before skip"
            `Quick
            test_on_idle_final_warning_before_skip
        ; test_case
            "on_idle skip at repeated idle"
            `Quick
            test_on_idle_skip_at_repeated_idle
        ; test_case
            "on_idle skip with custom threshold"
            `Quick
            test_on_idle_skip_with_custom_threshold
        ; test_case
            "recent tool streak counts tail matches"
            `Quick
            test_recent_tool_streak_count_counts_tail_matches
        ; test_case
            "recent tool streak ignores stale entries"
            `Quick
            test_recent_tool_streak_count_ignores_stale_entries
        ] )
    ]
;;
