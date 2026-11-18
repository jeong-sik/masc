(* A list with no rows has nothing for the row keys to act on, and the
   dispatcher ends [j/k], [Right / Enter] and the keys that answer, edit or copy
   a row in [()] there. The footer used to leave those keys out, so a key
   appeared and vanished as the list filled and emptied, and every key after it
   moved under the reader's eye.

   Zone 5 now keeps each key in its place and marks the one that does not
   answer (RFC tui-one-screen-grammar section 2). This file pins the decisions
   behind that: the key set and its order do not depend on the rows, a key
   that needs a row is [Unavailable] by variant on an empty list, a row draws
   every key in place exactly when the whole set fits and is otherwise the row
   of the answering keys alone, and a refused key stays in the dim while an
   answering one leaves it.

   Zone 5 names the keys that act and none that move ([j/k], [Enter], [Esc],
   the page keys, [/ n], [r], [Tab], [q]): the keys below are the ones left. *)

open Alcotest
module Keys = Masc_tui_keys
module T = Masc_tui_types

let lang = T.Lang_en

(* A surface, the keys it spells that need a row, and the keys that answer on
   an empty list. Each is the key as the table spells it. Clients' one key
   that acts is [p], back to Features, and every key Logs and Activity name
   answers on an empty list. *)
let surfaces =
  [ ("Schedules", T.Schedules, [ "e"; "x"; "Y" ], [ "n" ])
  ; ("Harness", T.Harness, [ "y / x"; "Y" ], [])
  ; ("Task Review", T.Verification, [ "a / x" ], [ "h" ])
  ; ("Fusion", T.Fusion, [ "K"; "B"; "Y" ], [ "a" ])
  ; ("Clients", T.Clients, [], [ "p" ])
  ; ("Workspace", T.Repositories, [ "H"; "d" ], [ "v"; "a" ])
  ; ("Changes", T.Changes, [ "d"; "v"; "o" ], [])
  (* A level floor or category can leave the Logs list with no entry. The keys
     that change the filters are how it comes back, so they answer. *)
  ; ("Logs", T.System_logs, [], [ "o"; "e"; "l"; "v"; "c" ])
  ; ("Activity", T.Acting, [], [ "e / l" ])
  ]

let actions ~has_rows surface = Keys.footer_actions ~detail_open:false ~has_rows surface

let keys_of actions = List.map (fun (action : Keys.action) -> action.binding.key) actions

let availability_of actions key =
  match
    List.find_opt (fun (action : Keys.action) -> String.equal action.binding.key key) actions
  with
  | Some action -> action.availability
  | None -> failf "the footer does not name %s" key

let pp_availability ppf = function
  | Keys.Available -> Format.pp_print_string ppf "Available"
  | Keys.Unavailable Keys.No_row -> Format.pp_print_string ppf "Unavailable No_row"
  | Keys.Unavailable Keys.No_reading -> Format.pp_print_string ppf "Unavailable No_reading"

let availability = testable pp_availability ( = )

let check_marks label actions ~unavailable:(reason, keys) ~available =
  List.iter
    (fun key ->
      check availability (label ^ " " ^ key) (Keys.Unavailable reason)
        (availability_of actions key))
    keys;
  List.iter
    (fun key ->
      check availability (label ^ " " ^ key) Keys.Available (availability_of actions key))
    available

let test_each_surface_scopes_a_key_to_a_row () =
  List.iter
    (fun (name, surface, needing, _) ->
      check bool (name ^ " has a key zone 5 names that needs a row")
        (needing <> []) (Keys.has_row_scoped_keys surface))
    surfaces

let test_the_keys_and_their_order_do_not_follow_the_rows () =
  List.iter
    (fun (name, surface, _, _) ->
      check (list string) (name ^ " empty and full lists name the same keys in order")
        (keys_of (actions ~has_rows:true surface))
        (keys_of (actions ~has_rows:false surface)))
    surfaces

let test_an_empty_list_marks_the_keys_that_need_a_row () =
  List.iter
    (fun (name, surface, needing, answering) ->
      check_marks (name ^ " empty list:") (actions ~has_rows:false surface)
        ~unavailable:(Keys.No_row, needing) ~available:answering)
    surfaces

let test_a_list_with_a_row_marks_every_key_available () =
  List.iter
    (fun (name, surface, needing, answering) ->
      check_marks (name ^ " list with a row:") (actions ~has_rows:true surface)
        ~unavailable:(Keys.No_row, []) ~available:(needing @ answering))
    surfaces

(* The table above names every key each row holds, so a key that moves cannot
   come back to a row without this failing. *)
let test_each_row_names_exactly_these_keys () =
  List.iter
    (fun (name, surface, needing, answering) ->
      check (list string) (name ^ " names these keys")
        (List.sort String.compare (needing @ answering))
        (List.sort String.compare (keys_of (actions ~has_rows:true surface))))
    surfaces

(* Workspace [v] opens a reading, not a row. After a failed read there is no
   repository to select and still a failure to open, so [v] follows
   [~has_reading] and [d] follows [~has_rows]. *)
let test_workspace_v_follows_the_reading_and_not_the_row () =
  let actions ~has_rows ~has_reading =
    Keys.footer_actions ~detail_open:false ~has_rows ~has_reading T.Repositories
  in
  let with_reading = actions ~has_rows:true ~has_reading:true
  and without_reading = actions ~has_rows:true ~has_reading:false
  and failed_read = actions ~has_rows:false ~has_reading:true
  and nothing = actions ~has_rows:false ~has_reading:false in
  List.iter
    (fun (label, other) ->
      check (list string) ("Workspace keys " ^ label) (keys_of with_reading) (keys_of other))
    [ ("without a reading", without_reading); ("after a failed read", failed_read);
      ("with nothing", nothing) ];
  check availability "v with a reading" Keys.Available (availability_of with_reading "v");
  check availability "v on a row with no reading" (Keys.Unavailable Keys.No_reading)
    (availability_of without_reading "v");
  check availability "v after a failed read with no row" Keys.Available
    (availability_of failed_read "v");
  check availability "d after a failed read with no row" (Keys.Unavailable Keys.No_row)
    (availability_of failed_read "d");
  check availability "v with nothing to open" (Keys.Unavailable Keys.No_reading)
    (availability_of nothing "v")

(* The Goal list draws from a builder of its own: it puts the Candle read first.
   [b], [t], [p] and [s] act on an empty list. *)
let goal_list_needing = [ "z"; "Y" ]

let goal_list_answering = [ "b"; "t"; "p"; "s" ]

let test_the_goal_list_keeps_its_keys_and_marks_the_row_keys () =
  let empty = Keys.planning_goal_list_actions ~has_rows:false
  and full = Keys.planning_goal_list_actions ~has_rows:true in
  check (list string) "Goals empty and full lists name the same keys in order"
    (keys_of full) (keys_of empty);
  check_marks "Goals empty list:" empty
    ~unavailable:(Keys.No_row, goal_list_needing) ~available:goal_list_answering;
  check_marks "Goals list with a row:" full
    ~unavailable:(Keys.No_row, []) ~available:(goal_list_needing @ goal_list_answering);
  check (list string) "Goals names these keys"
    (List.sort String.compare (goal_list_needing @ goal_list_answering))
    (List.sort String.compare (keys_of full))

let row_items row =
  List.map
    (fun (key : Masc_tui_footer.key_item) ->
      ( key.item,
        match key.answer with Masc_tui_footer.Answers -> true | Masc_tui_footer.Refused -> false ))
    (Masc_tui_footer.row_items row)

(* The fact browser's keys that need a fact -- [j/k], [Enter], [n / N] -- move,
   so the row names none of them, and every key it names answers on a browser
   with no fact. *)
let test_the_fact_browser_names_only_keys_that_answer () =
  let row = row_items (Keys.footer_row_memory_facts ~lang ~cols:200) in
  check bool "the row names a key" true (row <> []);
  check bool "every key answers with no fact" true (List.for_all snd row)

(* What a row keeps at one width: its items with the colour marks taken off,
   the cut marker included. *)
let kept ?status ?(refused_keys = Masc_tui_footer.Shown_dim) ~max_cells row =
  Masc_tui_footer.line ?status ~ko:false ~key_style:"\027[1m" ~dim:"" ~reset:"\027[0m"
    ~refused_keys ~max_cells ~hints:row ()
  |> Masc_tui_theme.strip_sgr
  |> String.trim
  |> Masc_tui_footer.split_on_double_space
  |> List.map String.trim

let widths = List.init 33 (fun step -> 24 + (step * 6))

let answering (action : Keys.action) =
  match action.availability with Keys.Available -> true | Keys.Unavailable _ -> false

(* The same keys with every one answering: the row a full list draws. *)
let every_key_answering actions =
  Keys.footer_row ~lang
    (List.map (fun (action : Keys.action) -> { action with availability = Keys.Available })
       actions)

(* The keys that answer, the refused ones left out: the row zone 5 drew before
   refused keys stayed, and what a cut row still is. *)
let answering_keys_alone actions =
  Keys.footer_row ~lang (List.filter answering actions)

let wide = 10_000

(* Whether a row of every key fits at all is read off the keys, refused or not,
   so it is the same whatever answers. When it fits, the row is every key in
   its place, the same as the row where every key answers. When it does not,
   every refused key goes first and the row is the answering keys' own, so a
   refused key never costs a key that answers or a notice: measured before this
   rule, the empty Fusion list lost [a:new run] at 80 to 120 cells and Harness
   lost [q:quit] at 40 to 60. *)
let check_whole_or_answering ?status name actions =
  let row = Keys.footer_row ~lang actions
  and all = every_key_answering actions in
  List.iter
    (fun max_cells ->
      let whole_fits = kept ?status ~max_cells all = kept ?status ~max_cells:wide all in
      let expected =
        if whole_fits then kept ?status ~max_cells all
        else kept ?status ~max_cells (answering_keys_alone actions)
      in
      check (list string)
        (Printf.sprintf "%s at %d cells (%s)" name max_cells
           (if whole_fits then "whole" else "cut"))
        expected (kept ?status ~max_cells row))
    widths

let test_a_row_is_whole_or_the_answering_keys_alone () =
  List.iter
    (fun (name, surface, _, _) ->
      List.iter
        (fun has_rows ->
          check_whole_or_answering
            (Printf.sprintf "%s %s" name (if has_rows then "full" else "empty"))
            (actions ~has_rows surface))
        [ false; true ])
    surfaces;
  check_whole_or_answering "Goals empty" (Keys.planning_goal_list_actions ~has_rows:false);
  check_whole_or_answering "Workspace without a reading"
    (Keys.footer_actions ~detail_open:false ~has_rows:true ~has_reading:false T.Repositories)

(* With colours off the row's dim is nothing, so a refused key drawn in its
   place would look like a key that acts. Such a row is the answering keys'
   own at every width, however much room is left. *)
let test_a_row_whose_dim_marks_nothing_names_only_keys_that_answer () =
  let check_actions name actions =
    let row = Keys.footer_row ~lang actions in
    List.iter
      (fun max_cells ->
        check (list string)
          (Printf.sprintf "%s at %d cells" name max_cells)
          (kept ~max_cells (answering_keys_alone actions))
          (kept ~refused_keys:Masc_tui_footer.Left_out ~max_cells row))
      (wide :: widths)
  in
  List.iter
    (fun (name, surface, _, _) -> check_actions (name ^ " empty") (actions ~has_rows:false surface))
    surfaces;
  check_actions "Goals empty" (Keys.planning_goal_list_actions ~has_rows:false)

(* The notices are what a refused key put aside: measured before this rule, on
   the empty Goal list at 90 and 100 cells, a refused [Right / Enter] counted as
   a key the row cannot drop and the build mismatch notice went. *)
let test_a_refused_key_does_not_put_a_notice_aside () =
  let mismatch =
    match
      Masc_tui_footer.build_mismatch_item ~tui_commit:(Some "aaaaaaa1111111")
        ~tui_age_s:(Some 100.) ~server_commit:"bbbbbbb2222222" ~server_age_s:(Some 5000.)
    with
    | Some item -> item
    | None -> fail "two different commits with known ages are a mismatch"
  in
  let operator =
    Masc_tui_footer.Operator_action { notice = "ACTION NEEDED 5"; detail = "Open Operations" }
  in
  check_whole_or_answering ~status:[ mismatch; operator ] "Goals empty with notices"
    (Keys.planning_goal_list_actions ~has_rows:false)

(* Two selections that answer different keys draw the same row wherever the
   whole set fits. *)
let test_a_whole_row_is_the_same_whatever_answers () =
  let same name ~one ~other =
    let all = every_key_answering one in
    List.iter
      (fun max_cells ->
        if kept ~max_cells all = kept ~max_cells:wide all then
          check (list string)
            (Printf.sprintf "%s at %d cells" name max_cells)
            (kept ~max_cells (Keys.footer_row ~lang one))
            (kept ~max_cells (Keys.footer_row ~lang other)))
      (widths @ [ wide ])
  in
  List.iter
    (fun (name, surface, _, _) ->
      same name ~one:(actions ~has_rows:true surface) ~other:(actions ~has_rows:false surface))
    surfaces;
  same "Goals" ~one:(Keys.planning_goal_list_actions ~has_rows:true)
    ~other:(Keys.planning_goal_list_actions ~has_rows:false);
  let workspace has_reading =
    Keys.footer_actions ~detail_open:false ~has_rows:true ~has_reading T.Repositories
  in
  same "Workspace" ~one:(workspace true) ~other:(workspace false)

(* A refused key is drawn, but it is not a key the screen promises: the
   navigation trace hears only the keys that answer, so pressing [j] on an empty
   Schedules list is not read as an advertised key that did nothing. *)
let test_the_trace_hears_only_the_keys_that_answer () =
  let empty = Keys.footer_row_of_surface ~lang ~detail_open:false ~has_rows:false T.Schedules
  and full = Keys.footer_row_of_surface ~lang ~detail_open:false ~has_rows:true T.Schedules in
  let advertised row = Masc_tui_footer.advertised_key_atoms (Masc_tui_footer.answering_text row) in
  check bool "an empty list does not advertise e" false (List.mem "e" (advertised empty));
  check bool "an empty list advertises n" true (List.mem "n" (advertised empty));
  check bool "a list with a row advertises e" true (List.mem "e" (advertised full))

(* A refused key stays in the row's dim with its label; the key letter of an
   answering one leaves the dim. That holds with an empty key style too, which is
   what the key letters keep once they lose their colour and weight (RFC
   tui-one-screen-grammar section 7.3). Styling keeps every item's answer and
   place: the fit reads the styled row. *)
let test_a_refused_key_stays_in_the_dim () =
  let check_row ~key_style name row =
    let styled = Masc_tui_footer.styled_row ~key_style ~dim:"<dim>" ~reset:"<reset>" row in
    let before = Masc_tui_footer.row_items row
    and after = Masc_tui_footer.row_items styled in
    check int (name ^ " keeps every item") (List.length before) (List.length after);
    List.iter
      (fun ((plain : Masc_tui_footer.key_item), (drawn : Masc_tui_footer.key_item)) ->
        check bool (name ^ " keeps the answer of " ^ plain.item) true (plain.answer = drawn.answer);
        match plain.answer with
        | Masc_tui_footer.Refused ->
          check string (name ^ " leaves refused " ^ plain.item) plain.item drawn.item
        | Masc_tui_footer.Answers ->
          check bool (name ^ " lifts " ^ plain.item ^ " out of the dim") true
            (String.starts_with ~prefix:"<reset>" drawn.item))
      (List.combine before after)
  in
  List.iter
    (fun key_style ->
      let check_row = check_row ~key_style in
      let style = if String.equal key_style "" then "no key style" else "a key style" in
      List.iter
        (fun (name, surface, _, _) ->
          check_row (name ^ " with " ^ style)
            (Keys.footer_row_of_surface ~lang ~detail_open:false ~has_rows:false surface))
        surfaces;
      check_row ("Goals with " ^ style) (Keys.footer_row_planning_goal_list ~lang ~has_rows:false);
      check_row ("facts with " ^ style) (Keys.footer_row_memory_facts ~lang ~cols:200))
    [ ""; "\027[1m" ]

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

(* The approval queue draws from a builder of its own that still spells its row
   by hand, so it names only the keys that act: zone 5 keeps a refused key in
   place on the screens built from typed actions (RFC tui-one-screen-grammar
   section 2), and this one keeps the old form until it moves. Its keys need
   different things. [y / n] acts on an approval row and answers with a notice
   without one. [a] opens the question under the cursor. [o / O] read a
   question's source, the last answer's included. [w] and [e] open a palette,
   so they act on an empty queue too. The keys that move -- [j/k], [[ / ]],
   [Esc], [r], [Tab], [q] -- are never named. *)
let approvals_footer ?(approvals = false) ?(ask_selected = false)
    ?(source = false) () =
  Keys.footer_hints_approvals ~lang:Masc_tui_types.Lang_en
    (Keys.Approval_browsing { approvals; ask_selected; source; last_answer = false })

let approvals_always = [ "w"; "e" ]

let approvals_moves = [ "j/k"; "[ / ]"; "Esc"; "r"; "Tab"; "q" ]

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
    ~absent:([ "y / n"; "a"; "o / O" ] @ approvals_moves)

let test_an_approval_row_brings_the_keys_that_decide () =
  check_keys "Approvals with a row" (approvals_footer ~approvals:true ())
    ~named:("y / n" :: approvals_always)
    ~absent:([ "a"; "o / O" ] @ approvals_moves)

(* [a] says "Choose a question with [ or ] first" until the cursor is on one,
   so only a selected question brings it. *)
let test_a_selected_question_brings_answer () =
  check_keys "Approvals with no question selected" (approvals_footer ())
    ~named:approvals_always ~absent:("a" :: approvals_moves);
  check_keys "Approvals with a selected question"
    (approvals_footer ~ask_selected:true ())
    ~named:("a" :: approvals_always)
    ~absent:([ "y / n"; "o / O" ] @ approvals_moves)

(* The Questions heading prints [approval_answer_hint]. The footer names the
   key in the same words, or the two lines say different things about [a]. *)
let test_the_selected_question_footer_uses_the_headings_words_for_answer () =
  check bool "the selected-question footer holds the heading's hint" true
    (contains
       ("  " ^ approvals_footer ~ask_selected:true ())
       ("  " ^ Keys.approval_answer_hint))

let test_a_source_brings_the_source_keys_without_a_question () =
  check_keys "Approvals with only a source" (approvals_footer ~source:true ())
    ~named:("o / O" :: approvals_always)
    ~absent:([ "y / n"; "a" ] @ approvals_moves)

let test_an_approvals_footer_with_everything_names_every_key () =
  check_keys "Approvals with everything"
    (approvals_footer ~approvals:true ~ask_selected:true ~source:true ())
    ~named:("y / n" :: "a" :: "o / O" :: approvals_always)
    ~absent:approvals_moves

let () =
  run "tui footer row need"
    [ ( "table",
        [ test_case "each surface scopes a key to a row" `Quick
            test_each_surface_scopes_a_key_to_a_row
        ; test_case "the keys and their order do not follow the rows" `Quick
            test_the_keys_and_their_order_do_not_follow_the_rows
        ; test_case "an empty list marks the keys that need a row" `Quick
            test_an_empty_list_marks_the_keys_that_need_a_row
        ; test_case "a list with a row marks every key available" `Quick
            test_a_list_with_a_row_marks_every_key_available
        ; test_case "each row names exactly these keys" `Quick
            test_each_row_names_exactly_these_keys
        ; test_case "workspace v follows the reading and not the row" `Quick
            test_workspace_v_follows_the_reading_and_not_the_row
        ; test_case "the goal list keeps its keys and marks the row keys" `Quick
            test_the_goal_list_keeps_its_keys_and_marks_the_row_keys
        ; test_case "the fact browser names only keys that answer" `Quick
            test_the_fact_browser_names_only_keys_that_answer
        ; test_case "a row is whole or the answering keys alone" `Quick
            test_a_row_is_whole_or_the_answering_keys_alone
        ; test_case "a refused key does not put a notice aside" `Quick
            test_a_refused_key_does_not_put_a_notice_aside
        ; test_case "a whole row is the same whatever answers" `Quick
            test_a_whole_row_is_the_same_whatever_answers
        ; test_case "the trace hears only the keys that answer" `Quick
            test_the_trace_hears_only_the_keys_that_answer
        ; test_case "a refused key stays in the dim" `Quick
            test_a_refused_key_stays_in_the_dim
        ; test_case "a row whose dim marks nothing names only keys that answer" `Quick
            test_a_row_whose_dim_marks_nothing_names_only_keys_that_answer
        ; test_case "an empty approvals queue names only the keys that act"
            `Quick test_an_empty_approvals_queue_names_only_the_keys_that_act
        ; test_case "an approval row brings the keys that decide" `Quick
            test_an_approval_row_brings_the_keys_that_decide
        ; test_case "a selected question brings the answer" `Quick
            test_a_selected_question_brings_answer
        ; test_case "the selected question footer uses the heading's words"
            `Quick
            test_the_selected_question_footer_uses_the_headings_words_for_answer
        ; test_case "a source brings the source keys without a question"
            `Quick test_a_source_brings_the_source_keys_without_a_question
        ; test_case "an approvals footer with everything names every key"
            `Quick test_an_approvals_footer_with_everything_names_every_key
        ] )
    ]
