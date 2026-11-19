module Mark = Masc_tui_keeper_mark
module Reading = Masc.Tui_decode

let check_bool = Alcotest.(check bool)
let check_int = Alcotest.(check int)

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
    [ Mark.now_header; Mark.age_header; "LIFECYCLE"; Mark.failing_glyph; "Mode"; "S "; Mark.grid_due_header; "mem"; Masc_tui_keeper_age_ladder.cell_label; "사람 몫"
    ; Mark.axis_now_header; Mark.grid_now_line; Mark.grid_due_header
    ; Mark.grid_lag_header; Mark.grid_librarian_header; Mark.grid_digest_header
    ; Mark.grid_gap_header; Mark.grid_facts_by_age_header; Mark.grid_saved_header
    ; Mark.grid_stale_header; Mark.grid_facts_header ]

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
  let words_ko = List.map (Mark.operator_disposition_word ~ko:true) kinds in
  check_int "each Korean operator disposition kind has its distinct word" 3
    (List.length (List.sort_uniq String.compare words_ko));
  Alcotest.(check string) "operator action required is 사람 몫" "사람 몫"
    (Mark.operator_disposition_word ~ko:true Disp_operator_action_required);
  Alcotest.(check string) "effect review required is 효과 확인" "효과 확인"
    (Mark.operator_disposition_word ~ko:true Disp_effect_review_required);
  Alcotest.(check string) "unknown is 분류 안 됨" "분류 안 됨"
    (Mark.operator_disposition_word ~ko:true Disp_unknown);
  Alcotest.(check string) "EN operator action required is human" "human"
    (Mark.operator_disposition_word ~ko:false Disp_operator_action_required);
  Alcotest.(check string) "EN effect review required is review" "review"
    (Mark.operator_disposition_word ~ko:false Disp_effect_review_required);
  Alcotest.(check string) "EN unknown is unclassed" "unclassed"
    (Mark.operator_disposition_word ~ko:false Disp_unknown)

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

(* RFC tui-one-screen-grammar §7.2: work under way wears the still mark the
   state dictionary gives it, the same on every surface. No frame counter
   chooses the mark any more; the growing length beside it says the work is
   going. *)
let test_work_under_way_wears_the_still_under_way_mark () =
  let under_way = Masc_tui_value.Mark.glyph Masc_tui_value.Mark.Under_way in
  List.iter
    (fun (label, activity) ->
      Alcotest.(check string) label under_way (Mark.activity_glyph activity))
    [ "preparing", Masc_tui_keeper_list_model.Preparing
    ; "running", Masc_tui_keeper_list_model.Running ]
;;

(* RFC tui-one-screen-grammar §7.2: each activity wears one of the seven
   status marks, and outside a pause or offline it is the mark of the group
   the state view sorts the activity into, so a row and its heading agree. *)
let test_each_activity_wears_its_status_mark () =
  let module Model = Masc_tui_keeper_list_model in
  let module Status = Masc_tui_value.Mark in
  let name = function
    | None -> "unread"
    | Some mark -> Status.glyph mark in
  List.iter
    (fun (label, activity, expected) ->
      Alcotest.(check string) label (name expected) (name (Mark.activity_mark activity));
      match activity with
      | Model.Paused | Model.Offline -> ()
      | _ ->
          Alcotest.(check string) (label ^ " wears its group's mark")
            (name (Mark.attention_mark (Model.group_of_activity activity)))
            (name (Mark.activity_mark activity)))
    [ "a held call is the operator's turn", Model.Held_call, Some Status.Yours
    ; "a question is the operator's turn", Model.Question, Some Status.Yours
    ; "a confirmation is the operator's turn", Model.Confirmation, Some Status.Yours
    ; "a failed attempt failed", Model.Attempt_failed, Some Status.Failed
    ; "preparing is under way", Model.Preparing, Some Status.Under_way
    ; "streaming is under way", Model.Streaming, Some Status.Under_way
    ; "running is under way", Model.Running, Some Status.Under_way
    ; "a background run is under way", Model.Async_working 1, Some Status.Under_way
    ; "a deferred turn is under way", Model.Deferred, Some Status.Under_way
    ; "a tool wait waits", Model.Tool_waiting, Some Status.Waiting
    ; "a model wait waits", Model.Model_waiting, Some Status.Waiting
    ; "an external wait waits", Model.External_waiting, Some Status.Waiting
    ; "a delegate result waits", Model.Delegate_result, Some Status.Waiting
    ; "a verification waits", Model.Verifying, Some Status.Waiting
    ; "rest waits", Model.Idle, Some Status.Waiting
    ; "a pause is paused", Model.Paused, Some Status.Paused
    ; "offline is paused", Model.Offline, Some Status.Paused
    ; "an unread activity has no mark", Model.Unknown, None ]
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
        ; Alcotest.test_case "work under way wears the still under-way mark" `Quick
            test_work_under_way_wears_the_still_under_way_mark
        ; Alcotest.test_case "each activity wears its status mark" `Quick
            test_each_activity_wears_its_status_mark
        ] )
    ]
