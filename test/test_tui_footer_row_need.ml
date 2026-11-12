(* A list with no rows has nothing for the row keys to act on. The dispatcher
   ends [j/k], [Right / Enter] and the keys that answer, edit or copy a row in
   [()] there, and the footer drew them anyway, first in line -- so a terminal
   too narrow for the whole row gave up the keys that do act before them: on an
   empty Schedules list the footer showed [j/k], [PgUp/PgDn] and
   [Right / Enter] and left [n:new] behind [...?].

   The table says which keys need a row ([Masc_tui_keys.row_need]) and
   [footer_hints ~has_rows] leaves them out. This file pins that half, one
   surface at a time as each list renderer starts passing [~has_rows]. The
   argument is optional, so a renderer that omits it still compiles and goes
   back to advertising every key; the table half cannot catch that. *)

open Alcotest
module Keys = Masc_tui_keys
module T = Masc_tui_types

let contains haystack needle =
  let needle_length = String.length needle
  and haystack_length = String.length haystack in
  let rec scan index =
    if index + needle_length > haystack_length then false
    else if String.equal (String.sub haystack index needle_length) needle then
      true
    else scan (index + 1)
  in
  scan 0

(* An item is "key:label" and items are joined by two spaces, so a key names
   an item only right after a separator: "e:" is inside "Left / Esc:". *)
let names_item hints key = contains ("  " ^ hints) ("  " ^ key ^ ":")

(* A surface, the keys it spells that need a row, and the keys that answer on
   an empty list. Each is the key as the table spells it. *)
let surfaces =
  [ ( "Schedules",
      T.Schedules,
      [ "j/k"; "PgUp/PgDn"; "Right / Enter"; "e"; "x"; "Y"; "Home/End" ],
      [ "n"; "< / >"; "Esc"; "r"; "q" ] )
  ; ( "Harness",
      T.Harness,
      [ "j/k"; "PgUp/PgDn"; "Right / Enter"; "y / x"; "Y"; "n / N"; "Home/End" ],
      [ "v"; "/"; "Esc"; "r"; "q" ] )
  ; ( "Task Review",
      T.Verification,
      [ "j/k"; "Right / Enter"; "a / x"; "n / N"; "PgUp/PgDn"; "Home/End" ],
      [ "v"; "h"; "/"; "< / >"; "Esc"; "r"; "q" ] )
  ; ( "Fusion",
      T.Fusion,
      [ "j/k"; "PgUp/PgDn"; "Enter"; "K"; "B"; "Y"; "/"; "n / N"; "Home/End" ],
      [ "a"; "Esc"; "r"; "q" ] )
  ; ( "Clients",
      T.Clients,
      [ "j/k"; "Enter"; "/"; "n / N"; "PgUp/PgDn"; "Home/End" ],
      [ "p / Esc"; "r"; "q" ] )
  ; ( "Workspace",
      T.Repositories,
      [ "j/k"; "Enter"; "H"; "d"; "n / N"; "PgUp/PgDn"; "Home/End" ],
      [ "a"; "/"; "Esc"; "r"; "q" ] )
  ; ( "Changes",
      T.Changes,
      [ "j/k"; "Right / Enter"; "d"; "v"; "/"; "n / N"; "o"; "PgUp/PgDn"; "Home/End" ],
      [ "[ / ]"; "Esc"; "r"; "q" ] )
  (* A level floor or category can leave the Logs list with no entry. The keys
     that change the filters are how it comes back, so they stay. *)
  ; ( "Logs",
      T.System_logs,
      [ "j/k"; "PgUp/PgDn"; "Right / Enter"; "n / N"; "Home/End" ],
      [ "o"; "e"; "l"; "v"; "c"; "/"; "Esc"; "r"; "q" ] )
  ]

let test_each_surface_scopes_a_key_to_a_row () =
  List.iter
    (fun (name, surface, _, _) ->
      check bool (name ^ " has a key that needs a row") true
        (Keys.has_row_scoped_keys surface))
    surfaces

let test_an_empty_list_names_no_key_that_needs_a_row () =
  List.iter
    (fun (name, surface, needing, _) ->
      let empty = Keys.footer_hints ~detail_open:false ~has_rows:false surface in
      List.iter
        (fun key ->
          check bool
            (name ^ " empty list does not name " ^ key)
            false (names_item empty key))
        needing)
    surfaces

let test_a_list_with_a_row_names_every_key () =
  List.iter
    (fun (name, surface, needing, answering) ->
      let full = Keys.footer_hints ~detail_open:false ~has_rows:true surface in
      List.iter
        (fun key ->
          check bool (name ^ " list with a row names " ^ key) true
            (names_item full key))
        (needing @ answering))
    surfaces

(* Scoping moved the keys, it did not delete them: a caller that says nothing
   about rows reads every one, which is what every caller did before the
   argument existed and what the cheat sheet still draws. *)
let test_a_caller_that_names_no_rows_keeps_every_key () =
  List.iter
    (fun (name, surface, needing, answering) ->
      let unsaid = Keys.footer_hints ~detail_open:false surface in
      List.iter
        (fun key ->
          check bool (name ^ " naming no rows still names " ^ key) true
            (names_item unsaid key))
        (needing @ answering))
    surfaces

(* What an empty list can still do stays on the footer: the keys that create,
   page the server, go back, find, refresh or quit. *)
let test_an_empty_list_keeps_the_keys_that_answer () =
  List.iter
    (fun (name, surface, _, answering) ->
      let empty = Keys.footer_hints ~detail_open:false ~has_rows:false surface in
      List.iter
        (fun key ->
          check bool (name ^ " empty list still names " ^ key) true
            (names_item empty key))
        answering)
    surfaces

(* Workspace [v] opens a reading, not a row. After a failed read there is no
   repository to select and still a failure to open, so the footer follows
   [~has_reading] and a failed read keeps [v] while [Enter] and the other row
   keys stay out. *)
let test_workspace_v_follows_the_reading_and_not_the_row () =
  let hints ~has_rows ~has_reading =
    Keys.footer_hints ~detail_open:false ~has_rows ~has_reading T.Repositories
  in
  check bool "v with a row" true
    (names_item (hints ~has_rows:true ~has_reading:true) "v");
  check bool "v after a failed read with no row" true
    (names_item (hints ~has_rows:false ~has_reading:true) "v");
  check bool "Enter after a failed read with no row" false
    (names_item (hints ~has_rows:false ~has_reading:true) "Enter");
  check bool "v with nothing to open" false
    (names_item (hints ~has_rows:false ~has_reading:false) "v")

(* The Goal list draws from a builder of its own: it puts the Candle read first
   and leaves the generic table reading above behind. Its [~has_rows] is a
   required argument, so the renderer cannot leave it out; this pins what it
   takes with it. [b], [t], [p], [v], [f] and [s] act on an empty list, and [f]
   is how a filter that left no Goal is undone. *)
let goal_list_needing =
  [ "z"; "j/k"; "Right / Enter"; "Y"; "/"; "n / N"; "PgUp/PgDn"; "Home/End" ]

let goal_list_answering = [ "b"; "t"; "p"; "v"; "f"; "s"; "Esc"; "r"; "q" ]

let test_an_empty_goal_list_names_no_key_that_needs_a_row () =
  check bool "Goals has a key that needs a row" true
    (Keys.has_row_scoped_keys T.Planning);
  let empty = Keys.footer_hints_planning_goal_list ~lang:Masc_tui_types.Lang_en ~has_rows:false in
  List.iter
    (fun key ->
      check bool ("Goals empty list does not name " ^ key) false
        (names_item empty key))
    goal_list_needing;
  List.iter
    (fun key ->
      check bool ("Goals empty list still names " ^ key) true
        (names_item empty key))
    goal_list_answering

let test_a_goal_list_with_a_row_names_every_key () =
  let full = Keys.footer_hints_planning_goal_list ~lang:Masc_tui_types.Lang_en ~has_rows:true in
  List.iter
    (fun key ->
      check bool ("Goals list with a row names " ^ key) true
        (names_item full key))
    (goal_list_needing @ goal_list_answering)

(* The approval queue draws from a builder of its own, and its keys need three
   different things. [j/k] and [y / n] act on an approval row and answer with a
   notice without one. [ / ] selects a waiting question and [a] opens the
   selected one. [o / O] read a question's source, the last answer's included.
   [w] and [e] open a palette, so they act on an empty queue too. *)
let approvals_footer ?(approvals = false) ?(asks = Keys.No_asks)
    ?(source = false) () =
  Keys.footer_hints_approvals ~lang:Masc_tui_types.Lang_en
    (Keys.Approval_browsing { approvals; asks; source; last_answer = false })

let approvals_always = [ "w"; "e"; "r"; "Tab"; "Esc"; "q" ]

let check_keys label hints ~named ~absent =
  List.iter
    (fun key ->
      check bool (label ^ " names " ^ key) true (names_item hints key))
    named;
  List.iter
    (fun key ->
      check bool (label ^ " does not name " ^ key) false (names_item hints key))
    absent

let test_an_empty_approvals_queue_names_only_the_keys_that_act () =
  check_keys "Approvals with nothing waiting" (approvals_footer ())
    ~named:approvals_always
    ~absent:[ "j/k"; "y / n"; "[ / ]"; "a"; "o / O" ]

let test_an_approval_row_brings_the_keys_that_decide () =
  check_keys "Approvals with a row" (approvals_footer ~approvals:true ())
    ~named:("j/k" :: "y / n" :: approvals_always)
    ~absent:[ "[ / ]"; "a"; "o / O" ]

(* Waiting questions bring [ / ] and nothing else: [a] says "Choose a question
   with [ or ] first" until the cursor is on one. *)
let test_a_question_brings_the_walk_and_a_selected_one_brings_answer () =
  check_keys "Approvals with unselected questions"
    (approvals_footer ~asks:Keys.Asks_unselected ())
    ~named:("[ / ]" :: approvals_always)
    ~absent:[ "j/k"; "y / n"; "a"; "o / O" ];
  check_keys "Approvals with a selected question"
    (approvals_footer ~asks:Keys.Ask_selected ())
    ~named:("[ / ]" :: "a" :: approvals_always)
    ~absent:[ "j/k"; "y / n"; "o / O" ]

(* The Questions heading prints [approval_answer_hint]. The footer names the
   key in the same words, or the two lines say different things about [a]. *)
let test_the_selected_question_footer_uses_the_headings_words_for_answer () =
  check bool "the selected-question footer holds the heading's hint" true
    (contains
       ("  " ^ approvals_footer ~asks:Keys.Ask_selected ())
       ("  " ^ Keys.approval_answer_hint))

let test_a_source_brings_the_source_keys_without_a_question () =
  check_keys "Approvals with only a source" (approvals_footer ~source:true ())
    ~named:("o / O" :: approvals_always)
    ~absent:[ "j/k"; "y / n"; "[ / ]"; "a" ]

let test_an_approvals_footer_with_everything_names_every_key () =
  check_keys "Approvals with everything"
    (approvals_footer ~approvals:true ~asks:Keys.Ask_selected ~source:true ())
    ~named:("j/k" :: "y / n" :: "[ / ]" :: "a" :: "o / O" :: approvals_always)
    ~absent:[]

let () =
  run "tui footer row need"
    [ ( "table",
        [ test_case "each surface scopes a key to a row" `Quick
            test_each_surface_scopes_a_key_to_a_row
        ; test_case "an empty list names no key that needs a row" `Quick
            test_an_empty_list_names_no_key_that_needs_a_row
        ; test_case "a list with a row names every key" `Quick
            test_a_list_with_a_row_names_every_key
        ; test_case "a caller that names no rows keeps every key" `Quick
            test_a_caller_that_names_no_rows_keeps_every_key
        ; test_case "an empty list keeps the keys that answer" `Quick
            test_an_empty_list_keeps_the_keys_that_answer
        ; test_case "workspace v follows the reading and not the row" `Quick
            test_workspace_v_follows_the_reading_and_not_the_row
        ; test_case "an empty goal list names no key that needs a row" `Quick
            test_an_empty_goal_list_names_no_key_that_needs_a_row
        ; test_case "a goal list with a row names every key" `Quick
            test_a_goal_list_with_a_row_names_every_key
        ; test_case "an empty approvals queue names only the keys that act"
            `Quick test_an_empty_approvals_queue_names_only_the_keys_that_act
        ; test_case "an approval row brings the keys that decide" `Quick
            test_an_approval_row_brings_the_keys_that_decide
        ; test_case "a question brings the walk, a selected one the answer"
            `Quick
            test_a_question_brings_the_walk_and_a_selected_one_brings_answer
        ; test_case "the selected question footer uses the heading's words"
            `Quick
            test_the_selected_question_footer_uses_the_headings_words_for_answer
        ; test_case "a source brings the source keys without a question"
            `Quick test_a_source_brings_the_source_keys_without_a_question
        ; test_case "an approvals footer with everything names every key"
            `Quick test_an_approvals_footer_with_everything_names_every_key
        ] )
    ]
