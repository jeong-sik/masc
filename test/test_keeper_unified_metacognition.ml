open Alcotest

module HK = Masc.Keeper_hooks_oas

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

let test_on_idle_board_get_nudge_names_post_id_discovery () =
  let decision =
    HK.on_idle_decision_with_threshold
      ~skip_at:3
      ~consecutive_idle_turns:1
      ~allowed_tools:
        [ "keeper_board_get"
        ; "keeper_board_list"
        ; "keeper_board_search"
        ]
      ~tool_names:[ "keeper_board_get" ]
  in
  match decision with
  | Agent_sdk.Hooks.Nudge msg ->
    check
      bool
      "board_get nudge names the routable tool, not the hallucinated alias"
      true
      (contains_substring msg "keeper_board_post_get requires post_id");
    check
      bool
      "board_get nudge points to board discovery tools"
      true
      (contains_substring msg "keeper_board_list or keeper_board_search");
    check
      bool
      "board_get nudge forbids empty args"
      true
      (contains_substring msg "Do not call keeper_board_post_get with {}")
  | other ->
    fail
      (Printf.sprintf
         "expected Nudge, got %s"
         (Agent_sdk.Hooks.decision_kind_to_string
            (Agent_sdk.Hooks.classify_decision other)))
;;

let test_on_idle_tools_list_loop_suggests_surface_read () =
  let decision =
    HK.on_idle_decision_with_threshold
      ~skip_at:3
      ~consecutive_idle_turns:1
      ~allowed_tools:
        [ "keeper_context_status"
        ; "keeper_tool_search"
        ; "keeper_broadcast"
        ; "keeper_tasks_list"
        ; "keeper_surface_read"
        ]
      ~tool_names:[ "keeper_tools_list" ]
  in
  match decision with
  | Agent_sdk.Hooks.Nudge msg ->
    check
      bool
      "tools_list loop nudge names surface_read"
      true
      (contains_substring msg "keeper_surface_read");
    check
      bool
      "tools_list loop nudge explains capability-list trap"
      true
      (contains_substring msg "keeper_tools_list lists capabilities");
    check
      bool
      "tools_list loop nudge points at connected-surface labels"
      true
      (contains_substring msg "Connected Surfaces");
    check
      bool
      "tools_list loop nudge does not hardcode a discord surface argument"
      false
      (contains_substring msg "surface=\"discord\"")
  | other ->
    fail
      (Printf.sprintf
         "expected Nudge, got %s"
         (Agent_sdk.Hooks.decision_kind_to_string
            (Agent_sdk.Hooks.classify_decision other)))
;;

let test_on_idle_tool_search_loop_suggests_code_search () =
  let decision =
    HK.on_idle_decision_with_threshold
      ~skip_at:3
      ~consecutive_idle_turns:1
      ~allowed_tools:
        [ "keeper_context_status"
        ; "keeper_tool_search"
        ; "Grep"
        ; "Read"
        ; "Execute"
        ]
      ~tool_names:[ "keeper_tool_search" ]
  in
  match decision with
  | Agent_sdk.Hooks.Nudge msg ->
    check
      bool
      "tool_search loop nudge explains schema-only search"
      true
      (contains_substring msg "discovers active tool schemas only");
    check
      bool
      "tool_search loop nudge says it is not repo file search"
      true
      (contains_substring msg "does not search repository files");
    check
      bool
      "tool_search loop uses visible allowed-set order"
      true
      (contains_substring
         msg
         "Available alternatives: keeper_context_status, Grep, Read, Execute");
    check
      bool
      "tool_search loop points at source symbol search"
      true
      (contains_substring msg "functions, types, or symbols")
  | other ->
    fail
      (Printf.sprintf
         "expected Nudge, got %s"
         (Agent_sdk.Hooks.decision_kind_to_string
            (Agent_sdk.Hooks.classify_decision other)))
;;

let test_on_idle_tool_search_loop_maps_internal_file_tools () =
  let decision =
    HK.on_idle_decision_with_threshold
      ~skip_at:3
      ~consecutive_idle_turns:1
      ~allowed_tools:
        [ "keeper_context_status"
        ; "keeper_tool_search"
        ; "tool_search_files"
        ; "tool_read_file"
        ; "tool_execute"
        ]
      ~tool_names:[ "keeper_tool_search" ]
  in
  match decision with
  | Agent_sdk.Hooks.Nudge msg ->
    check
      bool
      "tool_search loop maps internal search_files to Grep"
      true
      (contains_substring
         msg
         "Available alternatives: keeper_context_status, Grep, Read, Execute");
    check
      bool
      "tool_search loop does not include a hardcoded switch chain"
      false
      (contains_substring msg "switch to Grep then Read then Execute");
    check
      bool
      "tool_search loop does not expose internal search_files"
      false
      (contains_substring msg "tool_search_files");
    check
      bool
      "tool_search loop does not expose internal execute"
      false
      (contains_substring msg "tool_execute")
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
      "final warning mentions direct no-work/status response"
      true
      (contains_substring msg "direct no-work/status response")
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
    [ tool_log_entry ~ts:(now -. 30.0) "tool_read_file"
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
            "on_idle board_get nudge names post_id discovery"
            `Quick
            test_on_idle_board_get_nudge_names_post_id_discovery
        ; test_case
            "on_idle tools_list loop suggests surface_read"
            `Quick
            test_on_idle_tools_list_loop_suggests_surface_read
        ; test_case
            "on_idle tool_search loop suggests code search"
            `Quick
            test_on_idle_tool_search_loop_suggests_code_search
        ; test_case
            "on_idle tool_search loop maps internal file tools"
            `Quick
            test_on_idle_tool_search_loop_maps_internal_file_tools
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
