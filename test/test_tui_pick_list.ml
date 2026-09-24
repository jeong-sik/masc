(* The choose-one-of-N list the pickers share. An operator choosing one
   runtime out of dozens held an arrow key down to walk the catalogue three
   rows at a time; the list now narrows by typed text and moves by page. What
   is checked here is what a keypress does to the list: which row is under
   the cursor after it, and that no key leaves the cursor past the end. *)

module P = Masc_tui_pick_list

let label s = s
let items = [ "anthropic.claude"; "openai.gpt"; "ollama.qwen"; "zai.glm"; "kimi.k2"; "openai.o4" ]
let page = 2

let step t action =
  match P.apply ~page ~label items t action with
  | P.Stay t -> t
  | P.Chosen chosen -> Alcotest.failf "unexpected pick of %s" chosen
  | P.Dismissed -> Alcotest.fail "unexpected close"

let run keys =
  List.fold_left
    (fun t key ->
      match P.action_of_key ~close_keys:[ "e" ] t key with
      | Some action -> step t action
      | None -> Alcotest.failf "key %S is not the list's" key)
    P.closed keys

let under t =
  let v = P.view ~page ~window:P.Opens_at_cursor ~label items t in
  match v.P.selected_row with
  | None -> None
  | Some row -> List.nth_opt v.P.rows row

let check_under name expected t =
  Alcotest.(check (option string)) name expected (under t)

let test_typing_narrows_and_backspace_widens () =
  let t = run [ "/"; "o"; "p"; "e"; "n" ] in
  let v = P.view ~page ~window:P.Opens_at_cursor ~label items t in
  Alcotest.(check int) "two runtimes say open" 2 v.P.shown;
  Alcotest.(check int) "out of six" 6 v.P.total;
  check_under "the first match is under the cursor" (Some "openai.gpt") t;
  Alcotest.(check string) "the header names the filter and the count"
    "filter: open\xe2\x96\x8f 2 of 6" (P.summary v);
  let wider = run [ "/"; "o"; "p"; "e"; "n"; "\127"; "\127"; "\127" ] in
  Alcotest.(check int) "\"o\" keeps every runtime with an o" 4
    (P.view ~page ~window:P.Opens_at_cursor ~label items wider).P.shown

let test_case_is_folded () =
  let t = run [ "/"; "G"; "L"; "M" ] in
  check_under "GLM finds glm" (Some "zai.glm") t

(* Letters that move or close the list outside a filter are text inside
   one. *)
let test_the_filter_owns_the_picker_letters () =
  let t = run [ "/"; "k"; "i" ] in
  check_under "k and i are typed, not a move" (Some "kimi.k2") t;
  Alcotest.(check (option string)) "e is text too" (Some "ke")
    (run [ "/"; "k"; "e" ]).P.query

(* The cursor sits on the last match; a longer query keeps one match; the
   cursor is on it and not past it. *)
let test_the_cursor_clamps_when_the_list_shrinks () =
  let t = run [ "/"; "o"; "end" ] in
  check_under "end of the o matches" (Some "openai.o4") t;
  let t = run [ "/"; "o"; "end"; "l" ] in
  check_under "one match left, and the cursor is on it" (Some "ollama.qwen") t;
  (* Past the end of a list that shrank without a key: a reload. *)
  let before = run [ "end" ] in
  let fewer = [ "anthropic.claude"; "openai.gpt" ] in
  let v = P.view ~page ~window:P.Opens_at_cursor ~label fewer before in
  Alcotest.(check (option int)) "a shorter list draws its last row selected"
    (Some 1) v.P.selected_row;
  match P.apply ~page ~label fewer before P.Choose with
  | P.Chosen chosen -> Alcotest.(check string) "and Enter picks it" "openai.gpt" chosen
  | P.Stay _ | P.Dismissed -> Alcotest.fail "Enter picked nothing"

let test_page_and_ends_stay_in_bounds () =
  check_under "PgDn moves a page" (Some "ollama.qwen") (run [ "pagedown" ]);
  check_under "PgDn past the end stops at the last" (Some "openai.o4")
    (run [ "pagedown"; "pagedown"; "pagedown"; "pagedown" ]);
  check_under "PgUp past the head stops at the first" (Some "anthropic.claude")
    (run [ "down"; "pageup" ]);
  check_under "End is the last" (Some "openai.o4") (run [ "end" ]);
  check_under "Home is the first" (Some "anthropic.claude") (run [ "end"; "home" ]);
  check_under "arrows keep working" (Some "openai.gpt") (run [ "down" ]);
  check_under "and j/k" (Some "anthropic.claude") (run [ "j"; "k" ]);
  let v = P.view ~page ~window:P.Opens_at_cursor ~label items (run [ "end" ]) in
  Alcotest.(check (list string)) "the last page is full" [ "kimi.k2"; "openai.o4" ] v.P.rows

let test_an_empty_result_picks_nothing () =
  let t = run [ "/"; "x"; "y"; "z" ] in
  let v = P.view ~page ~window:P.Opens_at_cursor ~label items t in
  Alcotest.(check int) "nothing matches" 0 v.P.shown;
  Alcotest.(check (option int)) "no row is selected" None v.P.selected_row;
  (match P.apply ~page ~label items t P.Choose with
   | P.Stay _ -> ()
   | P.Chosen chosen -> Alcotest.failf "Enter picked %s from an empty list" chosen
   | P.Dismissed -> Alcotest.fail "Enter closed the picker");
  check_under "backspacing back to a match selects it" (Some "anthropic.claude")
    (run [ "/"; "x"; "y"; "z"; "\127"; "\127"; "\127" ])

(* Esc drops the filter first, back on the item that was under the cursor,
   and closes only when there is no filter to drop. *)
let test_esc_clears_the_filter_then_closes () =
  let cleared = run [ "/"; "k"; "i"; "esc" ] in
  Alcotest.(check (option string)) "the filter is gone" None cleared.P.query;
  check_under "the cursor stays on kimi" (Some "kimi.k2") cleared;
  (match P.apply ~page ~label items cleared P.Back with
   | P.Dismissed -> ()
   | P.Stay _ | P.Chosen _ -> Alcotest.fail "a second Esc did not close");
  match P.action_of_key ~close_keys:[ "e" ] P.closed "e" with
  | Some P.Back -> ()
  | Some _ | None -> Alcotest.fail "the picker's own close key is not Back"

(* A key the list does not bind is passed on, except that a typed filter
   takes every printable one. *)
let test_unbound_keys_are_not_the_lists () =
  let bound t key = Option.is_some (P.action_of_key ~close_keys:[] t key) in
  Alcotest.(check bool) "x outside a filter is the surface's" false (bound P.closed "x");
  Alcotest.(check bool) "x inside one is text" true (bound (run [ "/" ]) "x");
  Alcotest.(check bool) "a control key is never text" false (bound (run [ "/" ]) "\001")

let test_backspace_on_an_empty_filter_keeps_the_cursor () =
  check_under "the cursor stays on the third row" (Some "ollama.qwen")
    (run [ "/"; "down"; "down"; "\127" ])

let test_a_paste_types_the_whole_text () =
  let t = P.type_text P.closed "GPT" in
  check_under "a pasted id narrows like typing" (Some "openai.gpt") t

(* A screen-high picker keeps its first page while the cursor walks it, and
   then the cursor rides the last drawn row. *)
let test_a_following_window_keeps_the_first_page () =
  let drawn keys =
    let v = P.view ~page ~window:P.Follows_cursor ~label items (run keys) in
    (v.P.rows, v.P.selected_row)
  in
  Alcotest.(check (pair (list string) (option int))) "the second row is the page's"
    ([ "anthropic.claude"; "openai.gpt" ], Some 1) (drawn [ "down" ]);
  Alcotest.(check (pair (list string) (option int))) "past the page, the cursor is its last row"
    ([ "openai.gpt"; "ollama.qwen" ], Some 1) (drawn [ "down"; "down" ]);
  Alcotest.(check (pair (list string) (option int))) "the end is a full page"
    ([ "kimi.k2"; "openai.o4" ], Some 1) (drawn [ "end" ]);
  Alcotest.(check (pair (list string) (option int))) "a shorter list draws its last row"
    ([ "openai.gpt"; "ollama.qwen" ], Some 1)
    (let v =
       P.view ~page ~window:P.Follows_cursor ~label
         [ "anthropic.claude"; "openai.gpt"; "ollama.qwen" ] (run [ "end" ])
     in
     (v.P.rows, v.P.selected_row))

let () =
  Alcotest.run "tui_pick_list"
    [ ( "pick list",
        [ Alcotest.test_case "typing narrows, backspace widens" `Quick
            test_typing_narrows_and_backspace_widens;
          Alcotest.test_case "case is folded" `Quick test_case_is_folded;
          Alcotest.test_case "the filter owns the picker letters" `Quick
            test_the_filter_owns_the_picker_letters;
          Alcotest.test_case "the cursor clamps when the list shrinks" `Quick
            test_the_cursor_clamps_when_the_list_shrinks;
          Alcotest.test_case "page and ends stay in bounds" `Quick
            test_page_and_ends_stay_in_bounds;
          Alcotest.test_case "an empty result picks nothing" `Quick
            test_an_empty_result_picks_nothing;
          Alcotest.test_case "esc clears the filter, then closes" `Quick
            test_esc_clears_the_filter_then_closes;
          Alcotest.test_case "unbound keys are not the list's" `Quick
            test_unbound_keys_are_not_the_lists;
          Alcotest.test_case "backspace on an empty filter keeps the cursor" `Quick
            test_backspace_on_an_empty_filter_keeps_the_cursor;
          Alcotest.test_case "a paste types the whole text" `Quick
            test_a_paste_types_the_whole_text;
          Alcotest.test_case "a following window keeps the first page" `Quick
            test_a_following_window_keeps_the_first_page ] ) ]
