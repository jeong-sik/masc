(* The matchers behind the [:] palette, the [/] surface search, the memory
   browser filter, and the keeper message find.

   All are pure and fold case on both sides themselves. A caller hands over
   the operator's text as typed; the one that used to lowercase first and
   forgot would have found nothing, and that failure was silent. These cases
   pin the fold so it cannot move back to the callers one at a time. *)

open Masc_tui_types

let check_bool = Alcotest.(check bool)

let test_contains_is_a_substring_over_a_lowercased_haystack () =
  check_bool "plain substring" true (palette_contains ~needle:"adm" "keeper adm-race");
  check_bool "haystack case is ignored" true
    (palette_contains ~needle:"adm" "Keeper ADM-race");
  check_bool "absent substring" false (palette_contains ~needle:"zzz" "keeper adm-race");
  check_bool "empty needle matches anything" true (palette_contains ~needle:"" "anything");
  check_bool "needle longer than haystack" false (palette_contains ~needle:"keeper" "kee")
;;

(* [palette_contains] stopped taking a lowercase copy of the haystack and a
   [String.sub] of it per position, and folds case a byte at a time instead.
   The row search calls it once per row per keystroke, so on a large file the
   copies were the cost. These pin the answers the copies used to give --
   including the bytes a byte-wise fold must leave alone, which is every byte
   a UTF-8 sequence is made of. *)
let test_the_fold_is_ascii_only_and_leaves_other_bytes_alone () =
  check_bool "a Hangul needle finds itself" true
    (palette_contains ~needle:"\xed\x95\x9c" "\xed\x95\x9c\xea\xb5\xad");
  check_bool "a Hangul needle the row lacks" false
    (palette_contains ~needle:"\xea\xb0\x9c" "\xed\x95\x9c\xea\xb5\xad");
  check_bool "mixed script, ASCII folded" true
    (palette_contains ~needle:"KEEPER-\xed\x95\x9c" "keeper-\xed\x95\x9c 3");
  (* The boundary characters either side of A-Z in ASCII. A fold written as
     an arithmetic shift catches these if its range is off by one. *)
  check_bool "the byte below A is not folded into a letter" false
    (palette_contains ~needle:"@" "`");
  check_bool "the byte above Z is not folded into a letter" false
    (palette_contains ~needle:"[" "{");
  check_bool "A folds to a" true (palette_contains ~needle:"A" "a");
  check_bool "Z folds to z" true (palette_contains ~needle:"Z" "z")
;;

(* A scan that walks forward one position at a time has to keep trying after a
   partial match, and a scan that stops at the first byte that differs has to
   resume from the next position rather than past the whole attempt. *)
let test_a_partial_match_does_not_consume_the_row () =
  check_bool "the match begins inside a failed attempt" true
    (palette_contains ~needle:"aab" "aaab");
  check_bool "repeated prefixes do not hide the match" true
    (palette_contains ~needle:"abab" "ababab");
  check_bool "a prefix that never completes" false
    (palette_contains ~needle:"aab" "aaa");
  check_bool "the match sits at the very end" true
    (palette_contains ~needle:"race" "keeper adm-race")
;;

let test_subsequence_takes_the_characters_in_order () =
  (* The comment on the function names this exact case. *)
  check_bool "kadm finds keeper adm-race" true
    (palette_subsequence ~needle:"kadm" "keeper adm-race");
  check_bool "order matters" false
    (palette_subsequence ~needle:"mdak" "keeper adm-race");
  check_bool "a substring is also a subsequence" true
    (palette_subsequence ~needle:"adm" "keeper adm-race");
  check_bool "empty needle matches anything" true
    (palette_subsequence ~needle:"" "anything");
  check_bool "a character the haystack lacks" false
    (palette_subsequence ~needle:"kz" "keeper adm-race")
;;

let test_the_matcher_owns_the_needle_case () =
  (* An uppercase needle finds a lowercase row in every matcher, so no
     caller has to lowercase first and none can forget to. *)
  check_bool "uppercase needle finds in starts_with" true
    (palette_starts_with ~needle:"KEE" "keeper adm-race");
  check_bool "uppercase needle finds in contains" true
    (palette_contains ~needle:"ADM" "keeper adm-race");
  check_bool "uppercase needle finds in subsequence" true
    (palette_subsequence ~needle:"KADM" "keeper adm-race")
;;


let test_the_palette_lists_tasks_and_posts () =
  let state =
    create_state ~workspace:"test" ~port:8935 ~refresh_interval:2.0 ()
  in
  state.tasks <-
    [ { id = "task-532"
      ; title = "다섯 도구 축 사용 증명"
      ; status = Masc_domain.Todo
      ; priority = 2
      ; goal_ids = []
      } ];
  state.board_posts <-
    [ { bp_id = "p-1"
      ; bp_author = "alpha"
      ; bp_title = "release evidence sweep"
      ; bp_body = ""
      ; bp_votes = 0
      ; bp_comment_count = 0
      ; bp_created_at = "2026-08-25T00:00:00Z"
      ; bp_updated_at = 0.
      ; bp_hearth = None
      ; bp_kind = None
      } ];
  let labels = List.map fst (palette_entries state) in
  Alcotest.(check (list string)) "one Browser destination"
    ["go Browser Lane"]
    (List.filter_map (function label, Palette_browser_lane -> Some label | _ -> None)
       (palette_entries state));
  Alcotest.(check (list string)) "one MSX destination"
    ["go MSX"]
    (List.filter_map (function label, Palette_msx -> Some label | _ -> None)
       (palette_entries state));
  check_bool "Slack is not a separate destination" false (List.mem "go Slack Lane" labels);
  check_bool "settings is a direct entry" true
    (List.exists
       (function
         | "settings", Palette_config Config_params -> true
         | _ -> false)
       (palette_entries state));
  check_bool "a task is an entry" true
    (List.exists
       (fun l -> palette_contains ~needle:"task-532" l)
       labels);
  check_bool "a post is an entry" true
    (List.exists
       (fun l -> palette_contains ~needle:"release evidence" l)
       labels);
  (* The actions carry the ids the executor needs, not list positions that a
     refresh can move. *)
  check_bool "the task action carries its id" true
    (List.exists
       (function _, Palette_task id -> String.equal id "task-532" | _ -> false)
       (palette_entries state));
  check_bool "the post action carries its id" true
    (List.exists
       (function
         | _, Palette_board_post id -> String.equal id "p-1"
         | _ -> false)
       (palette_entries state))
;;

let runtime_row ~value_type ~current =
  { Tui_decode.rpr_key = "test.setting"
  ; rpr_current_json = current
  ; rpr_default_json = current
  ; rpr_has_override = false
  ; rpr_description = "test setting"
  ; rpr_value_type = value_type
  ; rpr_min_json = None
  ; rpr_max_json = None
  ; rpr_choices = []
  ; rpr_surface = None
  }

let test_friendly_runtime_param_editing () =
  let number =
    runtime_param_edit_of_row ~advanced:false
      (runtime_row ~value_type:"float" ~current:"300.0")
  in
  Alcotest.(check string) "friendly number has no JSON ceremony" "300.0"
    number.rpe_draft;
  let number = runtime_param_edit_append number "4" in
  Alcotest.(check string) "first key replaces the selected current value" "4"
    number.rpe_draft;
  (match runtime_param_edit_value number with
   | Ok (`Float value) ->
     Alcotest.(check (float 0.0001)) "number keeps its declared type" 4.0 value
   | Ok _ -> Alcotest.fail "number edit produced the wrong JSON type"
   | Error detail -> Alcotest.fail detail);
  let boolean =
    runtime_param_edit_of_row ~advanced:false
      (runtime_row ~value_type:"bool" ~current:"true")
  in
  Alcotest.(check string) "bool speaks operator language" "on"
    boolean.rpe_draft;
  Alcotest.(check string) "bool list value uses the same language" "off"
    (runtime_param_value_text ~value_type:"bool" "false");
  let boolean = runtime_param_edit_toggle_bool boolean in
  Alcotest.(check string) "one key toggles" "off" boolean.rpe_draft;
  (match runtime_param_edit_value boolean with
   | Ok (`Bool value) -> Alcotest.(check bool) "toggle submits a bool" false value
   | Ok _ -> Alcotest.fail "bool edit produced the wrong JSON type"
   | Error detail -> Alcotest.fail detail);
  let advanced =
    runtime_param_edit_of_row ~advanced:true
      (runtime_row ~value_type:"float" ~current:"300.0")
  in
  Alcotest.(check bool) "advanced stays explicit" true
    (advanced.rpe_mode = Advanced_json)
;;

(* A file that has landed, which is the state these names are read from.
   Written as a list of rows and stored as an array, the way the load does. *)
let landed ~path rows =
  match
    Masc_tui_fetched.start ~equal:String.equal Masc_tui_fetched.initial ~key:path
  with
  | Masc_tui_fetched.Already_loading -> Alcotest.fail "the fixture did not start"
  | Masc_tui_fetched.Started (t, request) ->
    Masc_tui_fetched.complete ~equal:String.equal t request
      (Ok (Array.of_list rows))
;;

let check_names = Alcotest.(check (list string))

(* K/D/R with several names on the line open the palette as a choice: the
   list is those names for that question, the typed text filters them, and
   no task or post rides along however its title spells. *)
let test_a_choice_lists_the_names_and_nothing_else () =
  let state =
    create_state ~workspace:"test" ~port:8935 ~refresh_interval:2.0 ()
  in
  state.code_file <-
    landed ~path:"lib/a.ml" [ [ ("Foo.bar x'", Masc_tui_code_lexer.kind_code) ] ];
  state.code_file_cursor <- 0;
  state.view <- Code;
  state.code_focus_file <- Right_pane;
  state.palette_open <- true;
  state.palette_mode <- Palette_choice { choice_question = "hover"; choice_line = 1 };
  state.palette_query <- "";
  let labels () = List.map fst (palette_matches state) in
  check_names "the three names, in reading order" [ "Foo"; "bar"; "x'" ] (labels ());
  check_bool "every entry asks the question about its name" true
    (List.for_all
       (function
         | name, Palette_lsp ("hover", symbol) -> String.equal name symbol
         | _ -> false)
       (palette_matches state));
  state.palette_query <- "ba";
  check_names "the typed text filters the names" [ "bar" ] (labels ());
  state.palette_query <- "zzz";
  check_names "a filter no name matches lists nothing" [] (labels ());
  state.palette_mode <- Palette_jump;
  state.palette_query <- "";
  check_bool "a jump lists destinations again" true
    (List.exists (fun label -> String.length label > 3 && String.sub label 0 3 = "go ") (labels ()))
;;

let test_the_cursor_lines_names_are_the_candidates () =
  let state =
    create_state ~workspace:"test" ~port:8935 ~refresh_interval:2.0 ()
  in
  state.code_file <-
    landed ~path:"lib/a.ml"
      [ [ ("let ", Masc_tui_code_lexer.kind_keyword);
          ("x = x + ", Masc_tui_code_lexer.kind_code);
          ("1", Masc_tui_code_lexer.kind_number) ];
        [ ("(* x *)", Masc_tui_code_lexer.kind_comment) ];
        [ ("Foo.bar x'", Masc_tui_code_lexer.kind_code) ] ];
  state.code_file_cursor <- 0;
  check_names "a keyword and a number offer no name, x appears once"
    [ "x" ]
    (code_cursor_line_symbols state);
  state.code_file_cursor <- 1;
  check_names "a comment offers no name" []
    (code_cursor_line_symbols state);
  state.code_file_cursor <- 2;
  check_names "module path splits, primes stay, reading order holds"
    [ "Foo"; "bar"; "x'" ]
    (code_cursor_line_symbols state);
  state.code_file_cursor <- 99;
  check_names "a cursor past the file names nothing" []
    (code_cursor_line_symbols state);
  (* The candidates ride the palette only with the file focused on Code. *)
  state.view <- Code;
  state.code_focus_file <- Right_pane;
  state.code_file_cursor <- 0;
  check_bool "the palette carries the def candidate" true
    (List.exists
       (function
         | _, Palette_lsp ("definition", "x") -> true
         | _ -> false)
       (palette_entries state));
  state.code_focus_file <- Left_pane;
  check_bool "an unfocused file offers no candidate" false
    (List.exists
       (function _, Palette_lsp _ -> true | _ -> false)
       (palette_entries state))
;;

let test_a_label_starting_with_the_query_leads () =
  let state =
    create_state ~workspace:"test" ~port:8935 ~refresh_interval:2.0 ()
  in
  (* Two posts mention "def" inside a word; the cursor line names one thing. *)
  let post id title =
    { bp_id = id
    ; bp_author = "alpha"
    ; bp_title = title
    ; bp_body = ""
    ; bp_votes = 0
    ; bp_comment_count = 0
    ; bp_created_at = "2026-08-26T00:00:00Z"
    ; bp_updated_at = 0.
    ; bp_hearth = None
    ; bp_kind = None
    }
  in
  state.board_posts <-
    [ post "p-1" "deferred wakeup evidence"; post "p-2" "head 7def9c review" ];
  state.code_file <-
    landed ~path:"lib/a.ml"
      [ [ ("open ", Masc_tui_code_lexer.kind_keyword);
          ("Hook_common", Masc_tui_code_lexer.kind_code) ] ];
  state.code_file_cursor <- 0;
  state.view <- Code;
  state.code_focus_file <- Right_pane;
  state.palette_query <- "def ";
  let matches = palette_matches state in
  (* This is the full operator palette, so independent commands may also
     match "def" as a subsequence. They must not displace the exact prefix
     candidate or reorder the two authored post matches. *)
  (match matches with
   | ("def Hook_common", Palette_lsp ("definition", "Hook_common")) :: _ -> ()
   | _ -> Alcotest.fail "the definition prefix must lead the entire palette");
  let posts = List.filter_map (function
    | label, Palette_board_post id -> Some (label, id)
    | _ -> None) matches in
  Alcotest.(check (list (pair string string)))
    "substring post matches preserve entry order and action identity"
    [ "post deferred wakeup evidence", "p-1";
      "post head 7def9c review", "p-2" ] posts;
  state.palette_query <- "hover ";
  check_names "hover pre-fill lists only the cursor line's hover entry"
    [ "hover Hook_common" ]
    (List.map fst (palette_matches state));
  state.palette_query <- "";
  check_bool "an empty query keeps every entry" true
    (List.length (palette_matches state) = List.length (palette_entries state))
;;

(* The [&] key opens the MSX screen, but a key is found only by someone who
   already knows it. The palette is where an operator looks for a screen by
   name, so "msx" typed there must reach the action the key reaches. *)
(* Task Review and Task Verdicts are one reading split in two and sit one [v]
   apart. The palette offered the first and not the second, so typing the name
   of the half that holds the rulings found nothing that goes there. *)
let test_the_palette_goes_to_both_halves_of_task_review () =
  let state =
    create_state ~workspace:"test" ~port:8935 ~refresh_interval:2.0 ()
  in
  let goes_to label surface =
    state.palette_query <- label;
    List.exists
      (fun (offered, action) ->
        String.equal offered label && action = Palette_goto surface)
      (palette_matches state)
  in
  check_bool "the queue of tasks waiting for a ruling" true
    (goes_to "go Task Review" Verification);
  check_bool "and the rulings themselves" true
    (goes_to "go Task Verdicts" Harness)
;;

let test_msx_is_reached_by_its_name () =
  let state =
    create_state ~workspace:"test" ~port:8935 ~refresh_interval:2.0 ()
  in
  state.palette_query <- "msx";
  check_bool "typing msx offers the MSX screen" true
    (List.exists
       (function _, Palette_msx -> true | _ -> false)
       (palette_matches state));
  state.palette_query <- "go msx";
  (match palette_matches state with
   | ("go MSX", Palette_msx) :: _ -> ()
   | _ -> Alcotest.fail "the label spelled out must lead its own matches")
;;

(* One row per destination. Metrics was five rows that all jumped to it; its
   other names still find it, from the one row. *)
let test_metrics_is_one_row_that_answers_its_other_names () =
  let state =
    create_state ~workspace:"test" ~port:8935 ~refresh_interval:2.0 ()
  in
  Alcotest.(check (list string)) "one row goes to Metrics" [ "go Metrics" ]
    (List.filter_map
       (function label, Palette_goto Metrics -> Some label | _ -> None)
       (palette_entries state));
  List.iter
    (fun word ->
      state.palette_query <- word;
      match palette_matches state with
      | ("go Metrics", Palette_goto Metrics) :: _ -> ()
      | _ -> Alcotest.fail (Printf.sprintf "%S does not lead with go Metrics" word))
    [ "metrics"; "telemetry"; "charts"; "stats"; "tele" ]
;;

let test_addons_do_not_require_a_keeper () =
  let state =
    create_state ~workspace:"empty" ~port:8935 ~refresh_interval:2.0 ()
  in
  Alcotest.(check int) "no Keeper needs to be created" 0
    (List.length state.keepers);
  state.palette_query <- "lane add-ons";
  (match palette_matches state with
   | ("go Lane Add-ons", Palette_lane_addons) :: _ -> ()
   | _ -> Alcotest.fail "an empty workspace must offer the Add-ons inspector")
;;

let () =
  Alcotest.run
    "masc-tui-palette-matching"
    [ ( "matchers"
      , [ Alcotest.test_case "contains is a substring over a lowercased haystack" `Quick
            test_contains_is_a_substring_over_a_lowercased_haystack
        ; Alcotest.test_case "subsequence takes the characters in order" `Quick
            test_subsequence_takes_the_characters_in_order
        ; Alcotest.test_case "the matcher owns the needle case" `Quick
            test_the_matcher_owns_the_needle_case
        ; Alcotest.test_case "a label starting with the query leads" `Quick
            test_a_label_starting_with_the_query_leads
        ; Alcotest.test_case "the fold is ASCII only" `Quick
            test_the_fold_is_ascii_only_and_leaves_other_bytes_alone
        ; Alcotest.test_case "a partial match does not consume the row" `Quick
            test_a_partial_match_does_not_consume_the_row
        ] )
    ; ( "sources"
      , [ Alcotest.test_case "the palette lists tasks and posts" `Quick
            test_the_palette_lists_tasks_and_posts
        ; Alcotest.test_case "the cursor line's names are the candidates"
            `Quick test_the_cursor_lines_names_are_the_candidates
        ; Alcotest.test_case "a choice lists the names and nothing else" `Quick
            test_a_choice_lists_the_names_and_nothing_else
        ; Alcotest.test_case "friendly runtime parameter editing" `Quick
            test_friendly_runtime_param_editing
        ; Alcotest.test_case "both halves of Task Review are reachable" `Quick
            test_the_palette_goes_to_both_halves_of_task_review
        ; Alcotest.test_case "msx is reached by its name" `Quick
            test_msx_is_reached_by_its_name
        ; Alcotest.test_case "Metrics is one row that answers its other names"
            `Quick test_metrics_is_one_row_that_answers_its_other_names
        ; Alcotest.test_case "Add-ons do not require a Keeper" `Quick
            test_addons_do_not_require_a_keeper
        ] )
    ]
;;
