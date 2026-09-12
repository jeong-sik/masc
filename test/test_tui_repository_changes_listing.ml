(* The Git-changes overlay over the Keepers surface. [d] on the roster, the
   detail and the chat pane opens it without moving [view], and the frame
   draws the overlay there; the key handler asks [scrolled_surface_rows] for
   the rows it moves through. With no arm for that pairing the answer was
   [None], the mover took the unbounded path, and one up-key from the top
   stored a negative scroll the frame then indexed the list with -- the
   process exited four times between 2026-09-05 and 2026-09-11. *)

open Masc_tui_types
module Tui_decode = Masc.Tui_decode

let state () = create_state ~workspace:"test" ~port:8935 ~refresh_interval:2.0 ()

let change path : Tui_decode.repository_change =
  { rc_path = path; rc_staged = false; rc_unstaged = true;
    rc_untracked = false; rc_conflicted = false }

let with_overlay state ~changes =
  state.repository_changes_open <- true;
  state.repository_changes_scope <- Some Tui_decode.Repository_change_project;
  state.repository_changes <-
    Some { Tui_decode.rcs_scope = Tui_decode.Repository_change_project
         ; rcs_changes = changes
         ; rcs_total = List.length changes }

(* The three keeper modes the frame draws the overlay over. *)
let overlay_hosts =
  [ "the roster", Keepers Keeper_list
  ; "keeper detail", Keepers Keeper_detail
  ; "the chat pane", Keepers Keeper_message ]

let test_the_overlay_over_a_keeper_view_is_a_listing () =
  List.iter
    (fun (label, view) ->
      let state = state () in
      with_overlay state ~changes:[change "a.ml"; change "b.ml"; change "c.ml"];
      state.view <- view;
      match scrolled_surface_rows state view with
      | None ->
          Alcotest.fail (label ^ " with the overlay open has no scroll geometry")
      | Some listing ->
          Alcotest.(check int) (label ^ " counts the overlay's rows") 3
            listing.sc_count;
          Alcotest.(check int) (label ^ " shares the overlay's chrome")
            (listing_chrome ~error:None) listing.sc_chrome)
    overlay_hosts

(* The same list drawn over Code answers the same geometry: which surface
   the overlay is over does not change how far it scrolls, with or without a
   load error taking its rows. *)
let test_the_geometry_is_the_overlays_not_the_hosts () =
  let over ~error view =
    let state = state () in
    with_overlay state ~changes:[change "a.ml"; change "b.ml"];
    state.repository_changes_error <- error;
    state.view <- view;
    scrolled_surface_rows state view
  in
  List.iter
    (fun error ->
      List.iter
        (fun (label, view) ->
          Alcotest.(check bool) (label ^ " answers what Code answers") true
            (over ~error view = over ~error Code))
        overlay_hosts)
    [ None; Some "git status failed" ]

let test_a_keeper_view_without_the_overlay_stays_unlisted () =
  List.iter
    (fun (label, view) ->
      let state = state () in
      state.view <- view;
      Alcotest.(check bool) (label ^ " moves a cursor, not a list") true
        (scrolled_surface_rows state view = None))
    overlay_hosts

let () =
  Alcotest.run "tui_repository_changes_listing"
    [ ( "over the Keepers surface"
      , [ Alcotest.test_case "the overlay is a listing" `Quick
            test_the_overlay_over_a_keeper_view_is_a_listing
        ; Alcotest.test_case "the geometry is the overlay's" `Quick
            test_the_geometry_is_the_overlays_not_the_hosts
        ; Alcotest.test_case "closed, the keeper view stays unlisted" `Quick
            test_a_keeper_view_without_the_overlay_stays_unlisted
        ] )
    ]
