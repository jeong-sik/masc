module Story = Masc_tui_keeper_story

let action =
  let pp ppf = function
    | Story.Show page -> Format.fprintf ppf "Show %s" (Story.tab_label page)
    | Story.Close -> Format.pp_print_string ppf "Close"
    | Story.Open_detail -> Format.pp_print_string ppf "Open_detail"
  in
  Alcotest.testable pp ( = )

let on_row = Story.action_of_key ~on_keeper:true
let no_keeper = Story.action_of_key ~on_keeper:false

(* The same key on every page of an open window. *)
let check_every_page ?(of_key = on_row) ~key ~expected () =
  List.iter
    (fun page ->
       Alcotest.check (Alcotest.option action)
         (Printf.sprintf "%S on the %s page" key (Story.tab_label page))
         expected
         (of_key (Some page) key))
    Story.pages

let shown_by_tab page =
  match on_row (Some page) "\t" with
  | Some (Story.Show next) -> next
  | Some (Story.Close | Story.Open_detail) | None ->
      Alcotest.fail "Tab must show a page"

(* The window is a ring of pages: one lap of Tab returns to the first page
   and leaves no page out. *)
let test_tab_makes_one_lap () =
  let first = List.hd Story.pages in
  let rec lap page remaining visited =
    if remaining = 0 then page, visited
    else lap (shown_by_tab page) (remaining - 1) (page :: visited)
  in
  let back, visited = lap first (List.length Story.pages) [] in
  Alcotest.(check bool) "back at the first page" true (back = first);
  Alcotest.(check int) "every page once"
    (List.length Story.pages)
    (List.length (List.sort_uniq compare visited))

(* The list reads [S] and [M] as [s] and [m], so the window does too: a capital
   [S] must not arm a shutdown whose confirming [s] the window would take. *)
let test_s_and_m_name_their_pages () =
  List.iter
    (fun key -> check_every_page ~key ~expected:(Some (Story.Show Story.Schedule)) ())
    [ "s"; "S" ];
  List.iter
    (fun key -> check_every_page ~key ~expected:(Some (Story.Show Story.Memory)) ())
    [ "m"; "M" ]

let test_enter_closes_the_story_page_and_returns_to_it_elsewhere () =
  Alcotest.check (Alcotest.option action) "story closes" (Some Story.Close)
    (on_row (Some Story.Story) "\r");
  List.iter
    (fun page ->
       List.iter
         (fun key ->
            Alcotest.check (Alcotest.option action)
              (Printf.sprintf "%S on the %s page" key (Story.tab_label page))
              (Some (Story.Show Story.Story))
              (on_row (Some page) key))
         [ "\r"; "\n"; "enter" ])
    [ Story.Schedule; Story.Memory ]

let test_escape_closes_and_right_opens_the_detail () =
  check_every_page ~key:"esc" ~expected:(Some Story.Close) ();
  check_every_page ~key:"right" ~expected:(Some Story.Open_detail) ()

(* Every other key reaches the list as it does with the window closed: the
   cursor keys move the Keeper the window follows, v and V change the view, and
   Shift-Tab leaves the surface. *)
let test_list_keys_pass_through () =
  List.iter
    (fun key -> check_every_page ~key ~expected:None ())
    [ "j"; "k"; "up"; "down"; "left"; "v"; "V"; "o"; "J"; "K"; "w"; "x"; "n"; "t"; "shift-tab" ]

(* A closed window takes Enter and nothing else: s still shuts a Keeper down,
   Right still opens the detail, Tab and Esc still leave the surface. *)
let test_closed_window_takes_only_enter () =
  List.iter
    (fun key ->
       Alcotest.check (Alcotest.option action)
         (Printf.sprintf "%S opens the window" key)
         (Some (Story.Show Story.Story))
         (on_row None key))
    [ "\r"; "\n"; "enter" ];
  List.iter
    (fun key ->
       Alcotest.check (Alcotest.option action)
         (Printf.sprintf "%S is left to the list" key)
         None
         (on_row None key))
    [ "\t"; "tab"; "s"; "S"; "m"; "M"; "esc"; "right"; "j"; "k"; "v"; "V" ]

(* A group heading and an empty list name no Keeper. A closed window opens
   nothing there, and an open one leaves Enter to the list and Right to the
   fold; the keys that only change the window still work. *)
let test_no_keeper_under_the_cursor () =
  List.iter
    (fun key ->
       Alcotest.check (Alcotest.option action)
         (Printf.sprintf "%S opens nothing without a Keeper" key)
         None
         (no_keeper None key))
    [ "\r"; "\n"; "enter" ];
  List.iter
    (fun key -> check_every_page ~of_key:no_keeper ~key ~expected:None ())
    [ "\r"; "\n"; "enter"; "right"; "left" ];
  check_every_page ~of_key:no_keeper ~key:"esc" ~expected:(Some Story.Close) ();
  check_every_page ~of_key:no_keeper ~key:"s" ~expected:(Some (Story.Show Story.Schedule)) ();
  check_every_page ~of_key:no_keeper ~key:"m" ~expected:(Some (Story.Show Story.Memory)) ();
  Alcotest.check (Alcotest.option action) "Tab without a Keeper"
    (Some (Story.Show Story.Schedule))
    (no_keeper (Some Story.Story) "\t")

let () =
  Alcotest.run "tui_keeper_story"
    [ ( "story window keys"
      , [ Alcotest.test_case "Tab makes one lap of the pages" `Quick test_tab_makes_one_lap
        ; Alcotest.test_case "s and m name their pages, capitals too" `Quick test_s_and_m_name_their_pages
        ; Alcotest.test_case "Enter closes the story page and returns to it" `Quick
            test_enter_closes_the_story_page_and_returns_to_it_elsewhere
        ; Alcotest.test_case "Esc closes and Right opens the detail" `Quick
            test_escape_closes_and_right_opens_the_detail
        ; Alcotest.test_case "the list's own keys pass through" `Quick
            test_list_keys_pass_through
        ; Alcotest.test_case "a closed window takes only Enter" `Quick
            test_closed_window_takes_only_enter
        ; Alcotest.test_case "no Keeper under the cursor" `Quick
            test_no_keeper_under_the_cursor
        ] )
    ]
