(* A surface that owns a detail draws one footer for two states. Until the key
   table carried the state, each of those surfaces advertised exactly one key
   the dispatcher refuses in the state on screen: [Right / Enter] once a detail
   is already open, [[ / ]] while it is not. The table knew -- the help said
   "while a detail is open" -- but as prose, which no footer can read.

   Two halves are pinned here because either one alone leaves the bug
   reachable: the table has to scope the keys, and both renderers of every
   scoped surface have to say which state they are drawing. The second is an
   optional argument, so a renderer that omits it still compiles and silently
   goes back to advertising both. *)

open Alcotest
module Keys = Masc_tui_keys

(* Named so a failure says which surface, not just which assertion. *)
let detail_surfaces =
  [ ("Planning", Masc_tui_types.Planning)
  ; ("Schedules", Masc_tui_types.Schedules)
  ; ("Verification", Masc_tui_types.Verification)
  ; ("Harness", Masc_tui_types.Harness)
  ]

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

let test_each_surface_scopes_a_key () =
  List.iter
    (fun (name, surface) ->
      check bool (name ^ " scopes at least one key to a state") true
        (Keys.has_detail_scoped_keys surface))
    detail_surfaces

let list_footer_refusals =
  [ ("Board", Masc_tui_types.Board, [ "[ / ]"; "z:"; "h/l" ])
  ; ("Fusion", Masc_tui_types.Fusion, [ "[ / ]" ])
  ; ("Resources", Masc_tui_types.Resources, [ "[ / ]" ])
  ; ("System_logs", Masc_tui_types.System_logs, [ "[ / ]" ])
  ]

let test_each_list_footer_names_no_key_it_refuses () =
  List.iter
    (fun (name, surface, keys) ->
      check bool (name ^ " scopes at least one key to a state") true
        (Keys.has_detail_scoped_keys surface);
      let list_hints = Keys.footer_hints ~detail_open:false surface in
      (* Scoping moved the keys, it did not delete them: a caller that names
         no state still reads them, which is what the cheat sheet does. *)
      let both = Keys.footer_hints surface in
      List.iter
        (fun key ->
          check bool (name ^ " list does not advertise " ^ key) false
            (contains list_hints key);
          check bool (name ^ " naming no state still reads " ^ key) true
            (contains both key))
        keys)
    list_footer_refusals

(* The footers above are read by substring, which cannot tell a one-letter key
   from the end of another: "c:" is inside "Esc:". An item is "key:label" and
   items are joined by two spaces, so a key names an item only right after a
   separator. *)
let names_item hints key = contains ("  " ^ hints) ("  " ^ key ^ ":")

(* A key and the two footers of its surface: the one drawn where the key
   answers and the one drawn where the dispatcher refuses it.
   [t], [p], [/] and [n / N] act on the Work list; in a Goal detail [p] is
   Pause and the other three have no list to act on. [c] replies to the post
   that is open, so the Board list has nothing to reply to. [/] and [n / N]
   search the list's rows, and an open Verification, Harness or System_logs
   detail has none. *)
let search_keys name surface =
  ( name,
    Keys.footer_hints ~detail_open:false surface,
    Keys.footer_hints ~detail_open:true surface,
    [ "/"; "n / N" ] )

(* Left closes an open detail and does nothing on a list (the [Some "left"]
   arm of masc_tui.ml), so with no detail open the way back is Esc alone. The
   two rows are one fact read in two states: the list footer names Esc and not
   Left / Esc, the detail footer the reverse. *)
let back_keys name ~list ~detail =
  [ (name ^ " Left / Esc", detail, list, [ "Left / Esc" ])
  ; (name ^ " Esc", list, detail, [ "Esc" ])
  ]

let back_keys_of_surface name surface =
  back_keys name
    ~list:(Keys.footer_hints ~detail_open:false surface)
    ~detail:(Keys.footer_hints ~detail_open:true surface)

let scoped_keys =
  [ ( "Planning",
      Keys.footer_hints_planning_goal_list,
      Keys.footer_hints_planning_goal_detail,
      [ "t"; "p"; "/"; "n / N" ] )
  ; ( "Board",
      Keys.footer_hints ~detail_open:true Masc_tui_types.Board,
      Keys.footer_hints ~detail_open:false Masc_tui_types.Board,
      [ "c" ] )
  ; search_keys "Verification" Masc_tui_types.Verification
  ; search_keys "Harness" Masc_tui_types.Harness
  ; search_keys "System_logs" Masc_tui_types.System_logs
  ]
  @ back_keys "Planning"
      ~list:Keys.footer_hints_planning_goal_list
      ~detail:Keys.footer_hints_planning_goal_detail
  @ back_keys_of_surface "Board" Masc_tui_types.Board
  @ back_keys_of_surface "Schedules" Masc_tui_types.Schedules
  @ back_keys_of_surface "Verification" Masc_tui_types.Verification
  @ back_keys_of_surface "Harness" Masc_tui_types.Harness
  @ back_keys_of_surface "System_logs" Masc_tui_types.System_logs

let test_a_scoped_key_is_named_only_where_it_answers () =
  List.iter
    (fun (name, answering, refusing, keys) ->
      List.iter
        (fun key ->
          check bool (name ^ " names " ^ key ^ " where it answers") true
            (names_item answering key);
          check bool (name ^ " does not name " ^ key ^ " where it is refused")
            false (names_item refusing key))
        keys)
    scoped_keys

(* The draft keys act on an open file only: the dispatcher needs the file pane
   focused with no diff, history or notes drawn over it. The tree and diff
   footers used to name them anyway. *)
let draft_keys = [ "e"; "S"; "V"; "X"; "A (draft)" ]

let test_code_draft_keys_are_named_only_on_the_file_pane () =
  let file = Keys.footer_hints_code ~pane:Keys.Code_file in
  List.iter
    (fun key ->
      check bool ("the file pane names " ^ key) true (names_item file key);
      List.iter
        (fun (pane_name, pane) ->
          check bool
            (pane_name ^ " pane does not name " ^ key)
            false
            (names_item (Keys.footer_hints_code ~pane) key))
        [ ("tree", Keys.Code_tree); ("diff", Keys.Code_diff) ])
    draft_keys

let test_every_scoped_surface_is_named () =
  let named =
    List.map (fun (_, surface, _) -> surface) list_footer_refusals
    @ List.map snd detail_surfaces
  in
  List.iter
    (fun (label, surface) ->
      if Keys.has_detail_scoped_keys surface then
        check bool (label ^ " scopes a key and is named here") true
          (List.exists (fun s -> s = surface) named))
    Keys.help_surfaces

let () =
  run "tui footer detail state"
    [ ( "table",
        [ test_case "each surface scopes a key" `Quick
            test_each_surface_scopes_a_key
        ; test_case "each list footer names no key it refuses" `Quick
            test_each_list_footer_names_no_key_it_refuses
        ; test_case "a scoped key is named only where it answers" `Quick
            test_a_scoped_key_is_named_only_where_it_answers
        ; test_case "code draft keys are named only on the file pane" `Quick
            test_code_draft_keys_are_named_only_on_the_file_pane
        ; test_case "every scoped surface is named here" `Quick
            test_every_scoped_surface_is_named
        ] )
    ; ( "renderers",
        [] )
    ]
