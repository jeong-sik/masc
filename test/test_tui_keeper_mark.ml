(** Four health readings, four marks.

    Exhaustiveness is the compiler's job; what it cannot check is that two
    readings did not quietly settle on the same character, or that a keeper
    that is not turning, or whose turns are failing, drew what a working
    keeper draws. *)

module Mark = Masc_tui_keeper_mark
module Reading = Masc.Tui_decode

let check_bool = Alcotest.(check bool)
let check_int = Alcotest.(check int)
let readings =
  [ "running", Reading.Health_running
  ; "idle", Reading.Health_idle
  ; "failing", Reading.Health_failing
  ; "offline", Reading.Health_offline
  ]

let test_the_column_legend_explains_every_letter_the_cell_draws () =
  let contains haystack needle =
    let n = String.length needle and h = String.length haystack in
    let rec go i = i + n <= h && (String.sub haystack i n = needle || go (i + 1)) in
    go 0
  in
  let modes =
    [ Reading.Activation_manual; Reading.Activation_on_demand; Reading.Activation_autonomous ]
  in
  let mode_letters = List.map Mark.activation_letter modes in
  check_int "each activation mode draws its own letter" (List.length modes)
    (List.length (List.sort_uniq String.compare mode_letters));
  let sandboxes = List.filter_map Mark.sandbox_of_profile [ "docker"; "microvm"; "remote_ssh" ] in
  check_int "the three declared profiles are sandboxes" 3 (List.length sandboxes);
  check_bool "a profile this build does not know is not one of them" true
    (Option.is_none (Mark.sandbox_of_profile "mock"));
  let sandbox_letters = List.map Mark.sandbox_letter sandboxes in
  check_int "each sandbox draws its own letter" 3
    (List.length (List.sort_uniq String.compare sandbox_letters));
  let keys = String.concat " " (List.map fst Mark.column_legend) in
  List.iter
    (fun letter -> check_bool ("the legend shows letter " ^ letter) true (contains keys letter))
    (mode_letters @ sandbox_letters);
  List.iter
    (fun header -> check_bool ("the legend names " ^ header) true (contains keys header))
    [ Mark.now_header; Mark.age_header; "LIFECYCLE"; Mark.failing_glyph; "Mode"; "S "; Mark.(badge_glyph Badge_schedule); "mem"; Masc_tui_keeper_age_ladder.cell_label; "사람 몫"
    ; Mark.pulse_header; Mark.axis_now_header; Mark.grid_now_line; Mark.grid_due_header
    ; Mark.grid_lag_header; Mark.fact_age_header
    ; Mark.librarian_header; Mark.updated_header; Mark.lag_digest_gap_header
    ; Mark.lag_stale_facts_header ]

let test_the_column_legend_names_the_failing_cell () =
  check_bool "the failing-for word is a legend key" true
    (List.exists (fun (key, _) -> String.equal key Mark.failing_since_word) Mark.column_legend)

let test_the_column_legend_names_the_pulse_cell () =
  let contains haystack needle =
    let n = String.length needle and h = String.length haystack in
    let rec go i = i + n <= h && (String.sub haystack i n = needle || go (i + 1)) in
    go 0
  in
  let pulse_marks =
    [ Mark.pulse_ok_mark
    ; Mark.pulse_rested_mark
    ; Mark.pulse_failed_mark
    ; Mark.pulse_quiet_mark
    ; Mark.unknown_mark
    ]
  in
  check_bool "one legend entry is keyed by all five pulse marks" true
    (List.exists
       (fun (key, _) -> List.for_all (fun mark -> contains key mark) pulse_marks)
       Mark.column_legend)

let test_operator_disposition_words () =
  let kinds =
    [ Masc.Keeper_execution_receipt.Disp_operator_action_required
    ; Masc.Keeper_execution_receipt.Disp_effect_review_required
    ; Masc.Keeper_execution_receipt.Disp_unknown
    ]
  in
  let words = List.map Mark.operator_disposition_word kinds in
  check_int "each operator disposition kind has its distinct word" 3
    (List.length (List.sort_uniq String.compare words));
  Alcotest.(check string) "operator action required is 사람 몫" "사람 몫"
    (Mark.operator_disposition_word Disp_operator_action_required);
  Alcotest.(check string) "effect review required is 효과 확인" "효과 확인"
    (Mark.operator_disposition_word Disp_effect_review_required);
  Alcotest.(check string) "unknown is 분류 안 됨" "분류 안 됨"
    (Mark.operator_disposition_word Disp_unknown)

let test_shows_operator_disposition_activity_filter () =
  check_bool "Running does not show disposition badge" false
    (Mark.shows_operator_disposition ~activity:Masc_tui_keeper_list_model.Running);
  check_bool "Preparing does not show disposition badge" false
    (Mark.shows_operator_disposition ~activity:Masc_tui_keeper_list_model.Preparing);
  check_bool "Streaming does not show disposition badge" false
    (Mark.shows_operator_disposition ~activity:Masc_tui_keeper_list_model.Streaming);
  check_bool "Paused does not show disposition badge" false
    (Mark.shows_operator_disposition ~activity:Masc_tui_keeper_list_model.Paused);
  check_bool "Offline does not show disposition badge" false
    (Mark.shows_operator_disposition ~activity:Masc_tui_keeper_list_model.Offline);
  check_bool "Held_call does not show disposition badge" false
    (Mark.shows_operator_disposition ~activity:Masc_tui_keeper_list_model.Held_call);
  check_bool "Question does not show disposition badge" false
    (Mark.shows_operator_disposition ~activity:Masc_tui_keeper_list_model.Question);
  check_bool "Confirmation does not show disposition badge" false
    (Mark.shows_operator_disposition ~activity:Masc_tui_keeper_list_model.Confirmation);
  check_bool "Tool_waiting does not show disposition badge" false
    (Mark.shows_operator_disposition ~activity:Masc_tui_keeper_list_model.Tool_waiting);
  check_bool "Model_waiting does not show disposition badge" false
    (Mark.shows_operator_disposition ~activity:Masc_tui_keeper_list_model.Model_waiting);
  check_bool "Async_working does not show disposition badge" false
    (Mark.shows_operator_disposition
       ~activity:(Masc_tui_keeper_list_model.Async_working 1));
  check_bool "Deferred does not show disposition badge" false
    (Mark.shows_operator_disposition ~activity:Masc_tui_keeper_list_model.Deferred);
  check_bool "Delegate_result does not show disposition badge" false
    (Mark.shows_operator_disposition ~activity:Masc_tui_keeper_list_model.Delegate_result);
  check_bool "Verifying does not show disposition badge" false
    (Mark.shows_operator_disposition ~activity:Masc_tui_keeper_list_model.Verifying);
  check_bool "External_waiting does not show disposition badge" false
    (Mark.shows_operator_disposition ~activity:Masc_tui_keeper_list_model.External_waiting);
  check_bool "Idle shows disposition badge" true
    (Mark.shows_operator_disposition ~activity:Masc_tui_keeper_list_model.Idle);
  check_bool "Attempt_failed shows disposition badge" true
    (Mark.shows_operator_disposition ~activity:Masc_tui_keeper_list_model.Attempt_failed);
  check_bool "Unknown shows disposition badge" true
    (Mark.shows_operator_disposition ~activity:Masc_tui_keeper_list_model.Unknown)
;;

let () =
  Alcotest.run "tui_keeper_mark"
    [ ( "marks"
      , [ Alcotest.test_case "the column legend explains every letter" `Quick
            test_the_column_legend_explains_every_letter_the_cell_draws
        ; Alcotest.test_case "the column legend names the failing cell" `Quick
            test_the_column_legend_names_the_failing_cell
        ; Alcotest.test_case "the column legend names the pulse cell" `Quick
            test_the_column_legend_names_the_pulse_cell
        ; Alcotest.test_case "operator disposition words are declared" `Quick
            test_operator_disposition_words
        ; Alcotest.test_case "operator disposition activity filter" `Quick
            test_shows_operator_disposition_activity_filter
        ] )
    ]
