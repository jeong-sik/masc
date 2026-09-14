(* The Approvals footer is a literal rather than a projection of the key
   table. It has a reason to be: the answering mode rewrites the row entirely,
   and the browsing row puts [y / n] second on purpose, which the sheet's
   group order cannot say.

   A literal drifts. It named [a] while the sheet did not, so an operator who
   pressed [?] to learn how to answer a Keeper's question found every other
   key on the surface and not that one.

   Keys are compared as atoms, so how each side spells the bracket keys
   ("[/]" on the row, "[ / ]" in the sheet) is not what this guard is about. *)

let documented_atoms =
  Masc_tui_keys.for_surface Masc_tui_types.Approvals
  |> List.concat_map (fun (b : Masc_tui_keys.binding) ->
       Masc_tui_footer.key_atoms b.Masc_tui_keys.key)

(* The footer joins its items with two spaces, the same separator the fitter
   splits them on. *)
let footer_items row =
  let len = String.length row in
  let rec split acc start i =
    if i + 1 >= len then List.rev (String.sub row start (len - start) :: acc)
    else if row.[i] = ' ' && row.[i + 1] = ' ' then
      split (String.sub row start (i - start) :: acc) (i + 2) (i + 2)
    else split acc start (i + 1)
  in
  split [] 0 0 |> List.map String.trim
  |> List.filter (fun item -> not (String.equal item ""))

let key_of_item item =
  match String.index_opt item ':' with
  | None -> None
  | Some i -> Some (String.sub item 0 i)

let test_every_key_the_footer_names_is_in_the_sheet () =
  let state =
    Masc_tui_types.create_state ~workspace:"" ~port:0 ~refresh_interval:0. ()
  in
  state.Masc_tui_types.view <- Masc_tui_types.Approvals;
  let row = Masc_tui_render_prim.question_hints state in
  let named = List.filter_map key_of_item (footer_items row) in
  Alcotest.(check bool) "the footer names keys at all" true (named <> []);
  List.iter
    (fun key ->
      List.iter
        (fun atom ->
          Alcotest.(check bool)
            (Printf.sprintf "%s (from %s) is in the sheet" atom key)
            true
            (List.mem atom documented_atoms))
        (Masc_tui_footer.key_atoms key))
    named

let () =
  Alcotest.run "tui_approvals_footer_matches_the_sheet"
    [ ( "approvals footer"
      , [ Alcotest.test_case "every key the footer names is in the sheet" `Quick
            test_every_key_the_footer_names_is_in_the_sheet
        ] )
    ]
