(* The runtime.toml pane's memory recall form, driven the way the key loop
   drives it: one decoded key at a time. What it writes is read back with the
   reader the server loads the file with, and a few texts are compared whole
   because the bytes of runtime.toml are what the feature produces. *)

module F = Masc_tui_memory_recall_form

let probe = "[models.probe]\napi-name = \"probe\"\n"
let entries names =
  List.map (fun name -> { F.name; presence = F.Unknown }) names
;;

let roster = entries [ "a"; "b"; "c" ]

let recall =
  Alcotest.testable Runtime_schema.pp_memory_recall Runtime_schema.equal_memory_recall
;;

let listed = function
  | first :: rest ->
    Runtime_schema.Memory_recall_on (Runtime_schema.Listed_keepers (first, rest))
  | [] -> invalid_arg "listed: a listed scope names at least one keeper"
;;

let opened ?(keepers = roster) text =
  match F.open_on ~source_revision:"rev-1" ~keepers text with
  | Ok form -> form
  | Error reason -> Alcotest.failf "the form did not open: %s" reason
;;

let press form keys =
  List.fold_left
    (fun outcome key ->
       match outcome with
       | F.Editing form -> F.key form key
       | F.Cancelled | F.Submitted _ -> outcome)
    (F.Editing form)
    keys
;;

let edited form keys =
  match press form keys with
  | F.Editing form -> form
  | F.Cancelled -> Alcotest.fail "the form closed before the keys ended"
  | F.Submitted _ -> Alcotest.fail "the form submitted before the keys ended"
;;

let text_of form =
  match F.text_on form with
  | Ok text -> text
  | Error _ -> Alcotest.fail "the form refused a choice it should write"
;;

let recall_of text =
  match Runtime_toml.parse_string text with
  | Ok config -> config.Runtime_schema.typesafeai.Runtime_schema.memory_recall
  | Error errors ->
    Alcotest.failf
      "the written text does not parse: %s"
      (String.concat
         "; "
         (List.map
            (fun (error : Runtime_toml.parse_error) -> error.path ^ ": " ^ error.message)
            errors))
;;

let with_table body = probe ^ "[typesafeai]\n" ^ body

let test_a_choice_the_file_already_has_writes_nothing () =
  List.iter
    (fun (label, text) -> Alcotest.(check string) label text (text_of (opened text)))
    [ "no table", probe
    ; "off", with_table "memory_recall = false\n"
    ; ( "off with a list kept"
      , with_table
          "memory_recall = false\nmemory_recall_scope = \"listed\"\nmemory_recall_keepers = [\"a\"]\n" )
    ; ( "listed"
      , with_table
          "memory_recall = true\nmemory_recall_scope = \"listed\"\nmemory_recall_keepers = [\"b\", \"a\"]\n" )
    ; "all", with_table "memory_recall = true\nmemory_recall_scope = \"all\"\n"
    ]
;;

let test_picks_are_written_in_the_order_they_were_made () =
  let form = edited (opened probe) [ "right"; "down"; "down"; "down"; " "; "up"; "up"; "space" ] in
  Alcotest.(check recall)
    "c then a"
    (listed [ "c"; "a" ])
    (recall_of (text_of form))
;;

let test_a_pick_made_later_goes_after_the_file_s_own () =
  let text =
    with_table
      "memory_recall = true\nmemory_recall_scope = \"listed\"\nmemory_recall_keepers = [\"b\"]\n"
  in
  let form = edited (opened text) [ "down"; " " ] in
  Alcotest.(check recall) "b stays first" (listed [ "b"; "a" ]) (recall_of (text_of form))
;;

let test_listed_on_a_file_without_the_table_adds_the_three_keys () =
  let form = edited (opened probe) [ "right"; "down"; " " ] in
  Alcotest.(check string)
    "the table, the switch, the scope and the list"
    (probe
     ^ "\n[typesafeai]\nmemory_recall = true\nmemory_recall_scope = \"listed\"\n\
        memory_recall_keepers = [\n\
       \  \"a\",\n\
        ]\n")
    (text_of form)
;;

let test_all_drops_the_list_and_leaves_every_other_line () =
  let text =
    with_table
      "# kept\nmemory_recall = true\nmemory_recall_scope = \"listed\"\n\
       memory_recall_keepers = [\"a\", \"b\"]\nabsorb_gate = true\n"
  in
  let form = edited (opened text) [ "right" ] in
  Alcotest.(check string)
    "scope all, no list, the rest as it was"
    (with_table
       "# kept\nmemory_recall = true\nmemory_recall_scope = \"all\"\nabsorb_gate = true\n")
    (text_of form);
  Alcotest.(check recall)
    "read back as every keeper"
    (Runtime_schema.Memory_recall_on Runtime_schema.All_keepers)
    (recall_of (text_of form))
;;

let test_off_writes_the_switch_alone_and_keeps_the_list () =
  let text =
    with_table
      "memory_recall = true # canary\nmemory_recall_scope = \"listed\"\n\
       memory_recall_keepers = [\"a\"]\nabsorb_gate = true\n"
  in
  let form = edited (opened text) [ "left" ] in
  Alcotest.(check string)
    "only the switch changed"
    (with_table
       "memory_recall = false # canary\nmemory_recall_scope = \"listed\"\n\
        memory_recall_keepers = [\"a\"]\nabsorb_gate = true\n")
    (text_of form);
  Alcotest.(check recall)
    "read back as off"
    Runtime_schema.Memory_recall_off
    (recall_of (text_of form))
;;

let test_other_tables_and_comments_are_not_touched () =
  let before = "# top\n[models.probe]\napi-name = \"probe\" # why\n\n" in
  let after = "\n[board]\n# note\n" in
  let text =
    before ^ "[typesafeai]\nmemory_recall = false\n" ^ after
  in
  let form = edited (opened text) [ "right"; "right" ] in
  let written = text_of form in
  Alcotest.(check string)
    "the lines before the table"
    before
    (String.sub written 0 (String.length before));
  Alcotest.(check string)
    "the lines after the table"
    after
    (String.sub written (String.length written - String.length after) (String.length after));
  Alcotest.(check recall)
    "every keeper"
    (Runtime_schema.Memory_recall_on Runtime_schema.All_keepers)
    (recall_of written)
;;

(* A rewrite drops the comment on the line, so a key that already holds what
   the choice needs keeps its line. Only the list changes here, and the
   comment on its line goes with the old value. *)
let test_a_key_that_already_holds_the_value_keeps_its_comment () =
  let text =
    with_table
      "memory_recall   =   true   # on\nmemory_recall_scope = \"listed\" # why\n\
       memory_recall_keepers = [\"a\"] # who\n"
  in
  let form = edited (opened text) [ "down"; "down"; " " ] in
  Alcotest.(check string)
    "the switch and the scope lines are as they were"
    (with_table
       "memory_recall   =   true   # on\nmemory_recall_scope = \"listed\" # why\n\
        memory_recall_keepers = [\n\
       \  \"a\",\n\
       \  \"b\",\n\
        ]\n")
    (text_of form)
;;

(* The gate asks whether a name is in the list, not where, so the same names
   in another order leave the file alone. *)
let test_the_same_keepers_in_another_order_write_nothing () =
  let text =
    with_table
      "memory_recall = true\nmemory_recall_scope = \"listed\"\n\
       memory_recall_keepers = [\"a\", \"b\"]\n"
  in
  let form = edited (opened text) [ "down"; " "; " " ] in
  Alcotest.(check string) "a dropped and picked again" text (text_of form)
;;

(* A file that switched recall off by hand keeps its list. The form starts
   with that list picked, and switching recall back on over it writes the
   switch alone -- the scope line and the list keep their text. *)
let test_a_list_kept_while_off_is_restored_by_switching_on () =
  let text =
    with_table
      "memory_recall = false # paused\nmemory_recall_scope = \"listed\" # why\n\
       memory_recall_keepers = [\"a\", \"b\"] # who\n"
  in
  let form = edited (opened text) [ "right" ] in
  Alcotest.(check string)
    "only the switch is rewritten"
    (with_table
       "memory_recall = true # paused\nmemory_recall_scope = \"listed\" # why\n\
        memory_recall_keepers = [\"a\", \"b\"] # who\n")
    (text_of form);
  Alcotest.(check recall)
    "read back as the kept list"
    (listed [ "a"; "b" ])
    (recall_of (text_of form));
  let widened = edited form [ "down"; "down"; "down"; " " ] in
  Alcotest.(check recall)
    "a pick after the restore joins the list"
    (listed [ "a"; "b"; "c" ])
    (recall_of (text_of widened))
;;

(* The gate asks whether a name is in the list, not where or how often, so a
   kept list the form shows in another order -- or with a name written twice --
   is still the list the form chose. Switching on writes the switch alone, and
   the read-back accepts the file's own list. *)
let test_a_kept_list_in_another_order_is_still_the_chosen_list () =
  let off_with names =
    with_table
      ("memory_recall = false\nmemory_recall_scope = \"listed\"\nmemory_recall_keepers = "
       ^ names ^ "\n")
  in
  let on_with names =
    with_table
      ("memory_recall = true\nmemory_recall_scope = \"listed\"\nmemory_recall_keepers = "
       ^ names ^ "\n")
  in
  let kept = "[\"a\", \"b\"]" in
  Alcotest.(check string)
    "a dropped and picked again goes after b"
    (on_with kept)
    (text_of (edited (opened (off_with kept)) [ "right"; "down"; " "; " " ]));
  let twice = "[\"a\", \"a\", \"b\"]" in
  Alcotest.(check string)
    "a name written twice stays as written"
    (on_with twice)
    (text_of (edited (opened (off_with twice)) [ "right" ]))
;;

(* A file that switched recall off and kept scope "all" has nothing to rewrite
   but the switch when recall goes back on for every keeper. *)
let test_all_over_a_switched_off_all_writes_the_switch_alone () =
  let text =
    with_table "memory_recall = false # paused\nmemory_recall_scope = \"all\" # why\n"
  in
  let form = edited (opened text) [ "right"; "right" ] in
  Alcotest.(check string)
    "only the switch is rewritten"
    (with_table "memory_recall = true # paused\nmemory_recall_scope = \"all\" # why\n")
    (text_of form)
;;

let detail =
  let show (d : F.detail) =
    let mode = function F.Off -> "off" | F.Listed -> "listed" | F.All -> "all" in
    Printf.sprintf
      "%s -> %s +[%s] -[%s] kept=%d removed=%d"
      (mode d.before)
      (mode d.after)
      (String.concat "," d.added)
      (String.concat "," d.dropped)
      d.list_kept
      d.list_removed
  in
  Alcotest.testable (fun formatter d -> Format.pp_print_string formatter (show d)) ( = )
;;

let expect_changed form =
  match F.change form with
  | F.Changed d -> d
  | F.Unchanged -> Alcotest.fail "expected a change, got none"
  | F.Nobody_picked -> Alcotest.fail "expected a change, got nobody picked"
;;

let listed_ab =
  with_table
    "memory_recall = true\nmemory_recall_scope = \"listed\"\n\
     memory_recall_keepers = [\"a\", \"b\"]\n"
;;

(* The same list in a file that switched recall off by hand. *)
let off_kept_ab =
  with_table
    "memory_recall = false\nmemory_recall_scope = \"listed\"\n\
     memory_recall_keepers = [\"a\", \"b\"]\n"
;;

(* What saving would do, named before it is done: the summary row reads this. *)
let test_change_names_what_saving_would_do () =
  let check label expected form = Alcotest.(check detail) label expected (expect_changed form) in
  check
    "a first pick"
    { F.before = F.Off; after = F.Listed; added = [ "a" ]; dropped = []; list_kept = 0; list_removed = 0 }
    (edited (opened probe) [ "right"; "down"; " " ]);
  check
    "one dropped, one picked"
    { F.before = F.Listed; after = F.Listed; added = [ "c" ]; dropped = [ "a" ]; list_kept = 0; list_removed = 0 }
    (edited (opened listed_ab) [ "down"; " "; "down"; "down"; " " ]);
  check
    "switched off keeps the list"
    { F.before = F.Listed; after = F.Off; added = []; dropped = []; list_kept = 2; list_removed = 0 }
    (edited (opened listed_ab) [ "left" ]);
  check
    "every keeper removes the list"
    { F.before = F.Listed; after = F.All; added = []; dropped = []; list_kept = 0; list_removed = 2 }
    (edited (opened listed_ab) [ "right" ]);
  check
    "back on over a kept list adds nothing"
    { F.before = F.Off; after = F.Listed; added = []; dropped = []; list_kept = 0; list_removed = 0 }
    (edited
       (opened
          (with_table
             "memory_recall = false\nmemory_recall_scope = \"listed\"\n\
              memory_recall_keepers = [\"a\", \"b\"]\n"))
       [ "right" ]);
  (match F.change (opened probe) with
   | F.Unchanged -> ()
   | F.Changed _ | F.Nobody_picked -> Alcotest.fail "a file that says off, left off, is no change");
  (match F.change (edited (opened probe) [ "right" ]) with
   | F.Nobody_picked -> ()
   | F.Changed _ | F.Unchanged -> Alcotest.fail "listed with nobody picked has no change to name")
;;

(* The summary and the write are one decision: the choice is unchanged exactly
   when saving gives the opening text back. *)
let test_change_and_text_on_agree_about_nothing_to_write () =
  let cases =
    [ "off left off", probe, []
    ; "listed left alone", listed_ab, []
    ; "dropped and picked again", listed_ab, [ "down"; " "; " " ]
    ; "a pick", listed_ab, [ "down"; "down"; "down"; " " ]
    ; "to every keeper", listed_ab, [ "right" ]
    ; "off", listed_ab, [ "left" ]
    ; "off over a kept list, left off", off_kept_ab, []
    ; "back on over a kept list", off_kept_ab, [ "right" ]
    ; "back on, a kept keeper dropped and picked again", off_kept_ab, [ "right"; "down"; " "; " " ]
    ; "back on, another keeper picked", off_kept_ab, [ "right"; "down"; "down"; "down"; " " ]
    ; "over a kept list, to every keeper", off_kept_ab, [ "right"; "right" ]
    ]
  in
  List.iter
    (fun (label, text, keys) ->
       let form = edited (opened text) keys in
       let unchanged_by_change =
         match F.change form with
         | F.Unchanged -> true
         | F.Changed _ | F.Nobody_picked -> false
       in
       Alcotest.(check bool)
         label
         unchanged_by_change
         (String.equal text (text_of form)))
    cases
;;

(* The picks are the form's, not the range's: a visit to the other ranges and
   back shows the same list. *)
let test_picks_survive_a_visit_to_the_other_ranges () =
  let form = edited (opened probe) [ "right"; "down"; " "; "up" ] in
  let visited = edited form [ "right"; "right"; "right" ] in
  Alcotest.(check recall)
    "a is still picked"
    (listed [ "a" ])
    (recall_of (text_of visited))
;;

(* The destinations may be written as [[typesafeai.destinations]] headers
   below the table; the three keys belong in [typesafeai], above them. *)
let test_destination_tables_below_the_table_are_kept () =
  let text =
    with_table
      "absorb_gate = true\n\n[[typesafeai.destinations]]\n\
       endpoint = \"http://127.0.0.1:9/judge\"\nmodel = \"jev-1.13\"\n\
       api_key_env = \"TYPESAFEAI_API_KEY\"\n"
  in
  let form = edited (opened text) [ "right"; "down"; " " ] in
  match Runtime_toml.parse_string (text_of form) with
  | Error _ -> Alcotest.fail "the written text does not parse"
  | Ok config ->
    let typesafeai = config.Runtime_schema.typesafeai in
    Alcotest.(check recall) "listed" (listed [ "a" ]) typesafeai.Runtime_schema.memory_recall;
    Alcotest.(check string)
      "the destination is still there"
      "http://127.0.0.1:9/judge"
      (fst typesafeai.Runtime_schema.destinations).Runtime_schema.endpoint;
    Alcotest.(check bool) "another key is untouched" true typesafeai.Runtime_schema.absorb_gate
;;

let test_listed_with_nobody_picked_is_refused_until_someone_is () =
  let form = edited (opened probe) [ "right" ] in
  let refused =
    match F.text_on form with
    | Ok _ -> Alcotest.fail "nobody was picked and the form wrote"
    | Error refused -> refused
  in
  let refused = edited refused [ "down"; " " ] in
  Alcotest.(check recall) "one pick lets it through" (listed [ "a" ]) (recall_of (text_of refused))
;;

let test_a_name_the_roster_lacks_stays_until_it_is_dropped () =
  let text =
    with_table
      "memory_recall = true\nmemory_recall_scope = \"listed\"\n\
       memory_recall_keepers = [\"gone\", \"a\"]\n"
  in
  let form = opened ~keepers:(entries [ "a"; "b" ]) text in
  Alcotest.(check string) "opening and saving changes nothing" text (text_of form);
  let dropped = edited form [ "down"; "down"; "down"; " " ] in
  Alcotest.(check recall) "gone is dropped" (listed [ "a" ]) (recall_of (text_of dropped))
;;

let test_the_keeper_rows_exist_only_for_the_listed_range () =
  (* In Off there is no row below the range row, so moving down stays on it
     and Space picks the next range, not a keeper. *)
  let form = edited (opened probe) [ "down"; "down"; " " ] in
  match F.text_on form with
  | Ok _ -> Alcotest.fail "Space on the range row chose a keeper"
  | Error _ -> ()
;;

let test_esc_abandons_and_enter_submits () =
  (match press (opened probe) [ "esc" ] with
   | F.Cancelled -> ()
   | F.Editing _ | F.Submitted _ -> Alcotest.fail "esc did not abandon");
  match press (opened probe) [ "enter" ] with
  | F.Submitted _ -> ()
  | F.Editing _ | F.Cancelled -> Alcotest.fail "enter did not submit"
;;

let test_a_file_that_does_not_parse_has_no_form () =
  match F.open_on ~keepers:roster "[[[broken" with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "a form opened on a file the server cannot read"
;;

let test_the_revision_it_was_opened_on_is_kept () =
  Alcotest.(check (option string))
    "revision"
    (Some "rev-1")
    (F.source_revision (edited (opened probe) [ "right"; "down"; " " ]))
;;

(* [typesafeai] written inline at the root: the line editor would add a second
   table of the same name, which the reader rejects. The form reads its own
   output back, so it refuses and writes nothing. *)
let test_a_table_the_line_editor_cannot_change_is_refused_not_written () =
  let text = "typesafeai = { absorb_gate = true }\n" ^ probe in
  let form = edited (opened text) [ "right"; "right" ] in
  match F.text_on form with
  | Error _ -> ()
  | Ok written -> Alcotest.failf "the form wrote a text the server cannot read: %S" written
;;

(* A keeper name comes from the file and from the server; an escape sequence in
   it must not reach the terminal. *)
let test_a_keeper_name_cannot_colour_the_pane () =
  (* Picked, so the name is in the list and in the line that says what saving
     would do. *)
  let form =
    edited (opened ~keepers:(entries [ "x\027[31my" ]) probe) [ "right"; "down"; " " ]
  in
  List.iter
    (fun row ->
       Alcotest.(check bool) "no escape byte in a row" false (String.contains row '\027'))
    (F.rows ~width:80 ~height:20 form)
;;

(* Which words mark a stopped Keeper is the pane's to choose. That it is drawn
   apart from a running one, and that a Keeper whose state is not known is
   drawn like a running one, is the form's. *)
let test_a_stopped_keeper_is_drawn_apart_from_a_running_one () =
  let rows_with presence =
    let form = edited (opened ~keepers:[ { F.name = "a"; presence } ] probe) [ "right" ] in
    F.rows ~width:80 ~height:30 form
  in
  Alcotest.(check bool)
    "stopped is not drawn as running"
    true
    (rows_with F.Stopped <> rows_with F.Running);
  Alcotest.(check (list string))
    "unknown is drawn as running"
    (rows_with F.Running)
    (rows_with F.Unknown)
;;

(* The Keeper list takes the rows the other rows leave, the line that says
   what saving would do among them. *)
let test_the_rows_fit_the_height_they_are_given () =
  let long = List.init 40 (fun index -> Printf.sprintf "keeper-%02d" index) in
  List.iter
    (fun keys ->
       let form = edited (opened ~keepers:(entries long) probe) keys in
       List.iter
         (fun height ->
            List.iter
              (fun width ->
                 let rows = F.rows ~width ~height form in
                 Alcotest.(check bool)
                   (Printf.sprintf "%d rows in a pane of %d x %d" (List.length rows) width height)
                   true
                   (List.length rows <= height))
              [ 60; 80; 200 ])
         [ 14; 20; 50 ])
    [ [ "right"; "down"; " " ]
    ; [ "right"; "down"; " "; "down"; "down"; " "; "down"; "down"; "down"; " " ]
    ]
;;

let test_rows_are_drawn_at_any_size () =
  let long = List.init 40 (fun index -> Printf.sprintf "keeper-%02d" index) in
  List.iter
    (fun keys ->
       let form = edited (opened ~keepers:(entries long) probe) keys in
       List.iter
         (fun height ->
            List.iter
              (fun width ->
                 Alcotest.(check bool)
                   "something is drawn"
                   true
                   (F.rows ~width ~height form <> []))
              [ 1; 20; 80; 200 ])
         [ 0; 1; 2; 5; 50 ])
    [ []; [ "right" ]; [ "right"; "right" ]; [ "right"; "down"; "down"; "down"; " " ] ]
;;

let () =
  Alcotest.run
    "tui memory recall form"
    [ ( "what it writes"
      , [ Alcotest.test_case "a choice the file already has writes nothing" `Quick
            test_a_choice_the_file_already_has_writes_nothing
        ; Alcotest.test_case "picks are written in the order they were made" `Quick
            test_picks_are_written_in_the_order_they_were_made
        ; Alcotest.test_case "a key that already holds the value keeps its comment" `Quick
            test_a_key_that_already_holds_the_value_keeps_its_comment
        ; Alcotest.test_case "the same keepers in another order write nothing" `Quick
            test_the_same_keepers_in_another_order_write_nothing
        ; Alcotest.test_case "a list kept while off is restored by switching on" `Quick
            test_a_list_kept_while_off_is_restored_by_switching_on
        ; Alcotest.test_case "a kept list in another order is still the chosen list" `Quick
            test_a_kept_list_in_another_order_is_still_the_chosen_list
        ; Alcotest.test_case "all over a switched-off all writes the switch alone" `Quick
            test_all_over_a_switched_off_all_writes_the_switch_alone
        ; Alcotest.test_case "change names what saving would do" `Quick
            test_change_names_what_saving_would_do
        ; Alcotest.test_case "change and text_on agree about nothing to write" `Quick
            test_change_and_text_on_agree_about_nothing_to_write
        ; Alcotest.test_case "picks survive a visit to the other ranges" `Quick
            test_picks_survive_a_visit_to_the_other_ranges
        ; Alcotest.test_case "a pick made later goes after the file's own" `Quick
            test_a_pick_made_later_goes_after_the_file_s_own
        ; Alcotest.test_case "listed on a file without the table adds the three keys" `Quick
            test_listed_on_a_file_without_the_table_adds_the_three_keys
        ; Alcotest.test_case "all drops the list and leaves every other line" `Quick
            test_all_drops_the_list_and_leaves_every_other_line
        ; Alcotest.test_case "off writes the switch alone and keeps the list" `Quick
            test_off_writes_the_switch_alone_and_keeps_the_list
        ; Alcotest.test_case "other tables and comments are not touched" `Quick
            test_other_tables_and_comments_are_not_touched
        ; Alcotest.test_case "destination tables below the table are kept" `Quick
            test_destination_tables_below_the_table_are_kept
        ; Alcotest.test_case "a table the line editor cannot change is refused, not written"
            `Quick test_a_table_the_line_editor_cannot_change_is_refused_not_written
        ] )
    ; ( "what it refuses"
      , [ Alcotest.test_case "listed with nobody picked is refused until someone is" `Quick
            test_listed_with_nobody_picked_is_refused_until_someone_is
        ; Alcotest.test_case "a file that does not parse has no form" `Quick
            test_a_file_that_does_not_parse_has_no_form
        ] )
    ; ( "keys"
      , [ Alcotest.test_case "a name the roster lacks stays until it is dropped" `Quick
            test_a_name_the_roster_lacks_stays_until_it_is_dropped
        ; Alcotest.test_case "the keeper rows exist only for the listed range" `Quick
            test_the_keeper_rows_exist_only_for_the_listed_range
        ; Alcotest.test_case "esc abandons and enter submits" `Quick
            test_esc_abandons_and_enter_submits
        ; Alcotest.test_case "the revision it was opened on is kept" `Quick
            test_the_revision_it_was_opened_on_is_kept
        ] )
    ; ( "rows"
      , [ Alcotest.test_case "a keeper name cannot colour the pane" `Quick
            test_a_keeper_name_cannot_colour_the_pane
        ; Alcotest.test_case "rows are drawn at any size" `Quick test_rows_are_drawn_at_any_size
        ; Alcotest.test_case "a stopped keeper is drawn apart from a running one" `Quick
            test_a_stopped_keeper_is_drawn_apart_from_a_running_one
        ; Alcotest.test_case "the rows fit the height they are given" `Quick
            test_the_rows_fit_the_height_they_are_given
        ] )
    ]
;;
