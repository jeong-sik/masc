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

(* While no detail is open, [ / ] is refused: every one of these surfaces
   guards it on its own detail being present. *)
let test_the_list_footer_drops_the_detail_only_key () =
  List.iter
    (fun (name, surface) ->
      let hints = Keys.footer_hints ~detail_open:false surface in
      check bool (name ^ " list does not advertise [ / ]") false
        (contains hints "[ / ]");
      check bool (name ^ " list still advertises the key that opens a detail")
        true
        (contains hints "Right / Enter"))
    detail_surfaces

(* And once one is open, the key that opens one has nothing left to do: it
   re-opens the row already on screen, so the frame does not change. *)
let test_the_detail_footer_drops_the_list_only_key () =
  List.iter
    (fun (name, surface) ->
      let hints = Keys.footer_hints ~detail_open:true surface in
      check bool (name ^ " detail advertises [ / ]") true
        (contains hints "[ / ]");
      check bool (name ^ " detail does not advertise the key that opens one")
        false
        (contains hints "Right / Enter"))
    detail_surfaces

let test_the_two_states_read_differently () =
  List.iter
    (fun (name, surface) ->
      check bool (name ^ " draws a different footer in each state") false
        (String.equal
           (Keys.footer_hints ~detail_open:false surface)
           (Keys.footer_hints ~detail_open:true surface)))
    detail_surfaces

(* Not only tidier: the Schedules footer already cut at 120 columns, so the
   cell a refused key was holding is a cell a usable key can have. Each state
   is shorter than the footer that named both. *)
let test_each_state_is_shorter_than_naming_both () =
  List.iter
    (fun (name, surface) ->
      let both = String.length (Keys.footer_hints surface) in
      check bool (name ^ " list footer is shorter than naming both") true
        (String.length (Keys.footer_hints ~detail_open:false surface) < both);
      check bool (name ^ " detail footer is shorter than naming both") true
        (String.length (Keys.footer_hints ~detail_open:true surface) < both))
    detail_surfaces

(* The omission this guards against, stated as a fact rather than left to be
   discovered: a caller that does not say which state it is in gets the old
   footer, both keys and all. That is why the renderer check below exists. *)
let test_omitting_the_state_keeps_the_old_reading () =
  List.iter
    (fun (name, surface) ->
      let hints = Keys.footer_hints surface in
      check bool (name ^ " without a state still advertises both") true
        (contains hints "[ / ]" && contains hints "Right / Enter"))
    detail_surfaces

let render_path = "bin/masc_tui_render.ml"

(* Both renderers of each scoped surface. A new detail-owning surface joins
   this list with its two renderers, and until it does its footer is the bug
   again. *)
let renderers =
  [ "render_planning_list"
  ; "render_planning_detail"
  ; "render_schedule_list"
  ; "render_schedule_detail"
  ; "render_verification_list"
  ; "render_verification_detail"
  ]

let test_every_renderer_says_which_state_it_draws () =
  List.iter
    (fun binding_name ->
      check int (binding_name ^ " passes ~detail_open to footer_hints") 1
        (Ast_grep.count_applications_with_labelled_argument_in_value_binding
           ~module_path:render_path ~binding_name
           ~callee:"Masc_tui_keys.footer_hints" ~label:"detail_open"))
    renderers

let () =
  run "tui footer detail state"
    [ ( "table",
        [ test_case "each surface scopes a key" `Quick
            test_each_surface_scopes_a_key
        ; test_case "the list footer drops the detail-only key" `Quick
            test_the_list_footer_drops_the_detail_only_key
        ; test_case "the detail footer drops the list-only key" `Quick
            test_the_detail_footer_drops_the_list_only_key
        ; test_case "the two states read differently" `Quick
            test_the_two_states_read_differently
        ; test_case "each state is shorter than naming both" `Quick
            test_each_state_is_shorter_than_naming_both
        ; test_case "omitting the state keeps the old reading" `Quick
            test_omitting_the_state_keeps_the_old_reading
        ] )
    ; ( "renderers",
        [ test_case "every renderer says which state it draws" `Quick
            test_every_renderer_says_which_state_it_draws
        ] )
    ]
