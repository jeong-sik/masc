(* A list with no rows has nothing for the row keys to act on, and the
   dispatcher ends [j/k], [Right / Enter] and the keys that answer, edit or copy
   a row in [()] there. The footer used to leave those keys out, so a key
   appeared and vanished as the list filled and emptied, and every key after it
   moved under the reader's eye.

   Zone 5 now keeps each key in its place and marks the one that does not
   answer (RFC tui-one-screen-grammar section 2). This file pins the three
   decisions behind that: the key set and its order do not depend on the rows,
   a key that needs a row is [Unavailable] by variant on an empty list, and a
   narrow row gives up the same keys whatever the rows. *)

open Alcotest
module Keys = Masc_tui_keys
module T = Masc_tui_types

let lang = T.Lang_en

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
     that change the filters are how it comes back, so they answer. *)
  ; ( "Logs",
      T.System_logs,
      [ "j/k"; "PgUp/PgDn"; "Right / Enter"; "n / N"; "Home/End" ],
      [ "o"; "e"; "l"; "v"; "c"; "/"; "Esc"; "r"; "q" ] )
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
    (fun (name, surface, _, _) ->
      check bool (name ^ " has a key that needs a row") true
        (Keys.has_row_scoped_keys surface))
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

(* Workspace [v] opens a reading, not a row. After a failed read there is no
   repository to select and still a failure to open, so [v] follows
   [~has_reading] and [Enter] follows [~has_rows]. *)
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
  check availability "Enter after a failed read with no row" (Keys.Unavailable Keys.No_row)
    (availability_of failed_read "Enter");
  check availability "v with nothing to open" (Keys.Unavailable Keys.No_reading)
    (availability_of nothing "v")

(* The Goal list draws from a builder of its own: it puts the Candle read first.
   [b], [t], [p], [v], [f] and [s] act on an empty list, and [f] is how a filter
   that left no Goal is undone. *)
let goal_list_needing =
  [ "z"; "j/k"; "Right / Enter"; "Y"; "/"; "n / N"; "PgUp/PgDn"; "Home/End" ]

let goal_list_answering = [ "b"; "t"; "p"; "v"; "f"; "s"; "Esc"; "r"; "q" ]

let test_the_goal_list_keeps_its_keys_and_marks_the_row_keys () =
  let empty = Keys.planning_goal_list_actions ~has_rows:false
  and full = Keys.planning_goal_list_actions ~has_rows:true in
  check (list string) "Goals empty and full lists name the same keys in order"
    (keys_of full) (keys_of empty);
  check_marks "Goals empty list:" empty
    ~unavailable:(Keys.No_row, goal_list_needing) ~available:goal_list_answering;
  check_marks "Goals list with a row:" full
    ~unavailable:(Keys.No_row, []) ~available:(goal_list_needing @ goal_list_answering)

let row_items row =
  List.map
    (fun (key : Masc_tui_footer.key_item) ->
      ( key.item,
        match key.answer with Masc_tui_footer.Answers -> true | Masc_tui_footer.Refused -> false ))
    (Masc_tui_footer.row_items row)

(* The fact browser's row is built from the same marks: [j/k] stays in its place
   on a keeper with no fact, and only its answer changes. *)
let test_the_fact_browser_keeps_its_keys () =
  let empty = row_items (Keys.footer_row_memory_facts ~lang ~cols:200 ~has_rows:false)
  and full = row_items (Keys.footer_row_memory_facts ~lang ~cols:200 ~has_rows:true) in
  check (list string) "facts empty and full rows name the same items"
    (List.map fst full) (List.map fst empty);
  check bool "j/k is refused with no fact" true
    (List.exists (fun (item, answers) -> String.starts_with ~prefix:"j/k:" item && not answers)
       empty);
  check bool "every key answers with a fact" true (List.for_all snd full)

(* The width the fitter keeps is a decision over the whole set, so it does not
   depend on which keys answer: an empty and a full list give up the same items
   at every width. Compared with the colour marks taken off, because only the
   key emphasis differs between the two. *)
let fitted ~max_cells row =
  Masc_tui_footer.line ~ko:false ~key_style:"\027[1m" ~dim:"" ~reset:"\027[0m" ~max_cells
    ~hints:row ()
  |> Masc_tui_theme.strip_sgr

let widths = List.init 33 (fun step -> 24 + (step * 6))

let test_a_narrow_row_gives_up_the_same_keys_whatever_the_rows () =
  let check_rows name ~empty ~full =
    List.iter
      (fun max_cells ->
        check string
          (Printf.sprintf "%s at %d cells" name max_cells)
          (fitted ~max_cells full) (fitted ~max_cells empty))
      widths
  in
  List.iter
    (fun (name, surface, _, _) ->
      check_rows name
        ~empty:(Keys.footer_row_of_surface ~lang ~detail_open:false ~has_rows:false surface)
        ~full:(Keys.footer_row_of_surface ~lang ~detail_open:false ~has_rows:true surface))
    surfaces;
  check_rows "Goals"
    ~empty:(Keys.footer_row_planning_goal_list ~lang ~has_rows:false)
    ~full:(Keys.footer_row_planning_goal_list ~lang ~has_rows:true)

(* A refused key is drawn, but it is not a key the screen promises: the
   navigation trace hears only the keys that answer, so pressing [j] on an empty
   Schedules list is not read as an advertised key that did nothing. *)
let test_the_trace_hears_only_the_keys_that_answer () =
  let empty = Keys.footer_row_of_surface ~lang ~detail_open:false ~has_rows:false T.Schedules
  and full = Keys.footer_row_of_surface ~lang ~detail_open:false ~has_rows:true T.Schedules in
  let advertised row = Masc_tui_footer.advertised_key_atoms (Masc_tui_footer.answering_text row) in
  check bool "an empty list does not advertise j" false (List.mem "j" (advertised empty));
  check bool "an empty list advertises n" true (List.mem "n" (advertised empty));
  check bool "a list with a row advertises j" true (List.mem "j" (advertised full))

(* The one mark zone 5 gives a refused key is the key emphasis it does not get.
   Styling a row leaves a refused item as it was, emphasises at least one item
   that answers, and keeps every item's answer and place: the drop order reads
   the styled row. *)
let test_a_refused_key_takes_no_key_emphasis () =
  let styled row =
    Masc_tui_footer.styled_row ~key_style:"\027[1m" ~dim:"\027[2m" ~reset:"\027[0m" row
  in
  let check_row name row =
    let before = Masc_tui_footer.row_items row
    and after = Masc_tui_footer.row_items (styled row) in
    check int (name ^ " keeps every item") (List.length before) (List.length after);
    let pairs = List.combine before after in
    List.iter
      (fun ((plain : Masc_tui_footer.key_item), (drawn : Masc_tui_footer.key_item)) ->
        check bool (name ^ " keeps the answer of " ^ plain.item) true (plain.answer = drawn.answer);
        match plain.answer with
        | Masc_tui_footer.Refused ->
          check string (name ^ " leaves refused " ^ plain.item) plain.item drawn.item
        | Masc_tui_footer.Answers -> ())
      pairs;
    check bool (name ^ " emphasises a key that answers") true
      (List.exists
         (fun ((plain : Masc_tui_footer.key_item), (drawn : Masc_tui_footer.key_item)) ->
           (match plain.answer with
            | Masc_tui_footer.Answers -> true
            | Masc_tui_footer.Refused -> false)
           && not (String.equal plain.item drawn.item))
         pairs)
  in
  List.iter
    (fun (name, surface, _, _) ->
      check_row name (Keys.footer_row_of_surface ~lang ~detail_open:false ~has_rows:false surface))
    surfaces;
  check_row "Goals" (Keys.footer_row_planning_goal_list ~lang ~has_rows:false);
  check_row "facts" (Keys.footer_row_memory_facts ~lang ~cols:200 ~has_rows:false)

(* Workspace [v] is the key whose answer follows the selection rather than the
   list: a row with no reading refuses it. The narrow row gives up the same keys
   with and without the reading. *)
let test_a_narrow_workspace_row_does_not_follow_the_reading () =
  let row ~has_reading =
    Keys.footer_row_of_surface ~lang ~detail_open:false ~has_rows:true ~has_reading T.Repositories
  in
  List.iter
    (fun max_cells ->
      check string
        (Printf.sprintf "Workspace at %d cells" max_cells)
        (fitted ~max_cells (row ~has_reading:true))
        (fitted ~max_cells (row ~has_reading:false)))
    widths

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
        ; test_case "the keys and their order do not follow the rows" `Quick
            test_the_keys_and_their_order_do_not_follow_the_rows
        ; test_case "an empty list marks the keys that need a row" `Quick
            test_an_empty_list_marks_the_keys_that_need_a_row
        ; test_case "a list with a row marks every key available" `Quick
            test_a_list_with_a_row_marks_every_key_available
        ; test_case "workspace v follows the reading and not the row" `Quick
            test_workspace_v_follows_the_reading_and_not_the_row
        ; test_case "the goal list keeps its keys and marks the row keys" `Quick
            test_the_goal_list_keeps_its_keys_and_marks_the_row_keys
        ; test_case "the fact browser keeps its keys" `Quick
            test_the_fact_browser_keeps_its_keys
        ; test_case "a narrow row gives up the same keys whatever the rows" `Quick
            test_a_narrow_row_gives_up_the_same_keys_whatever_the_rows
        ; test_case "the trace hears only the keys that answer" `Quick
            test_the_trace_hears_only_the_keys_that_answer
        ; test_case "a refused key takes no key emphasis" `Quick
            test_a_refused_key_takes_no_key_emphasis
        ; test_case "a narrow workspace row does not follow the reading" `Quick
            test_a_narrow_workspace_row_does_not_follow_the_reading
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
