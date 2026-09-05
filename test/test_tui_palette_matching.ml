(* The two matchers behind the [:] palette and the [/] roster search.

   Both are pure, and both were shipped without a test. They also share an
   unstated contract: each lowercases the haystack itself and expects the
   caller to have lowercased the needle. All three call sites do
   (masc_tui_types.palette_matches, masc_tui.roster_search_jump, and the n/N
   repeat beside it), so the contract holds today -- these cases pin it so a
   fourth caller that forgets is a failure here rather than a search box that
   quietly finds nothing. *)

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

let test_the_caller_owns_the_needle_case () =
  (* Not a nicety: an uppercase needle reaches the comparison unchanged and
     matches nothing, because the haystack is already lowercase by then. The
     three call sites lowercase before calling. *)
  check_bool "uppercase needle finds nothing in contains" false
    (palette_contains ~needle:"ADM" "keeper adm-race");
  check_bool "uppercase needle finds nothing in subsequence" false
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

(* A file that has landed, which is the state these names are read from. *)
let landed ~path rows =
  match
    Masc_tui_fetched.start ~equal:String.equal Masc_tui_fetched.initial ~key:path
  with
  | Masc_tui_fetched.Already_loading -> Alcotest.fail "the fixture did not start"
  | Masc_tui_fetched.Started (t, request) ->
    Masc_tui_fetched.complete ~equal:String.equal t request (Ok rows)
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
  let labels = List.map fst (palette_matches state) in
  check_names "the prefix hit leads, the substring hits follow in entry order"
    [ "def Hook_common"; "post deferred wakeup evidence"; "post head 7def9c review" ]
    labels;
  state.palette_query <- "hover ";
  check_names "hover pre-fill lists only the cursor line's hover entry"
    [ "hover Hook_common" ]
    (List.map fst (palette_matches state));
  state.palette_query <- "";
  check_bool "an empty query keeps every entry" true
    (List.length (palette_matches state) = List.length (palette_entries state))
;;

let () =
  Alcotest.run
    "masc-tui-palette-matching"
    [ ( "matchers"
      , [ Alcotest.test_case "contains is a substring over a lowercased haystack" `Quick
            test_contains_is_a_substring_over_a_lowercased_haystack
        ; Alcotest.test_case "subsequence takes the characters in order" `Quick
            test_subsequence_takes_the_characters_in_order
        ; Alcotest.test_case "the caller owns the needle case" `Quick
            test_the_caller_owns_the_needle_case
        ; Alcotest.test_case "a label starting with the query leads" `Quick
            test_a_label_starting_with_the_query_leads
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
        ] )
    ]
;;
