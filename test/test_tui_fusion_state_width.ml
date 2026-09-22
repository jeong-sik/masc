(* The STATE column of the Fusion run list has no slack, and nothing held it.

   [Table.cell ~width] fits what it is given without a word, so a string that
   outgrows the column loses its tail on screen and nowhere else. The column is
   twenty cells and the widest thing drawn in it is twenty cells: one more
   character anywhere in four separate vocabularies and the operator reads a
   failure code with its ending cut off. None of the four lives near the
   width, and nobody adding an arm to them goes looking for a column.

   So the width is read from the module that owns it and the vocabularies are
   read from the functions that produce them, all of it out of the source. A
   list written here instead would be one more copy of the same fact, and the
   copy is what goes stale. *)

let check = Alcotest.check

let width_module = "bin/masc_tui_render_schedule.ml"
let width_binding = "fusion_state_width"

(* What a [%d] is allowed to cost. Panels are counted in tens today, so four
   digits is far past anything the server sends -- and it is the number that
   makes the longest running stage exactly fill the column:

     recording(%d/%d)  =  12 fixed + 4 + 4  =  20

   At five digits that row is 22 and would be cut. The bound is written here
   rather than left implicit so that the day a fusion run fans out to 99,999
   panels, this test says where the screen gives up. *)
let digit_budget = 4

(* The drawn width of a literal, with directives priced. Anything other than
   [%d] or [%%] fails loudly: [%s] has no width, and a column cannot be held
   against a vocabulary that admits one. *)
let drawn_width ~owner text =
  let length = String.length text in
  let rec measure index width =
    if index >= length then width
    else if Char.equal text.[index] '%' && index + 1 < length then
      match text.[index + 1] with
      | 'd' -> measure (index + 2) (width + digit_budget)
      | '%' -> measure (index + 2) (width + 1)
      | other ->
        Alcotest.failf
          "%s draws %S, whose %%%c has no bounded width -- the STATE column \
           cannot be held against it"
          owner text other
    else measure (index + 1) (width + 1)
  in
  measure 0 0

(* The vocabularies the column draws, each read from the function that
   produces it -- one per arm of [fusion_run_state_text]
   (masc_tui_render_prim.ml:2363).

   The failed arm draws [frs_failure_code], which is a string off the wire,
   and the two failure sets below stand in for it: they are what this
   repository's server writes there (masc_tui_render_prim.ml:2357-2362 says
   the code is a tag from one of the two closed sets). Both ends of that wire
   live here, so the stand-in holds today -- but it is a stand-in. A server
   that starts sending a code from outside those sets would truncate in the
   cell with this check silent. *)
let vocabularies =
  [ ( "the delivery failure codes"
    , "lib/fusion/fusion_sink.ml"
    , "delivery_failure_code" )
  ; ( "the judge failure tags"
    , "lib/fusion_core/fusion_types.ml"
    , "judge_failure_tag" )
  ; ( "the running stages"
    , "bin/masc_tui_render_prim.ml"
    , "fusion_run_stage_compact" )
    (* The fourth arm of [fusion_run_state_text]. Only [Fusion_completed]
       reaches it, so the cell only ever shows "completed" -- but the whole
       function is measured, because what this check promises is that every
       vocabulary the column draws is read from its source, and a promise with
       an arm left out is not that. *)
  ; ( "the settled statuses"
    , "lib/tui_decode.ml"
    , "fusion_run_status_to_string" )
  ]

let state_width () =
  match
    Ast_grep.int_literals_in_value_binding ~module_path:width_module
      ~binding_name:width_binding
  with
  | [ width ] -> width
  | found ->
    Alcotest.failf
      "%s in %s should be one plain integer; found %d (%s)" width_binding
      width_module (List.length found)
      (String.concat ", " (List.map string_of_int found))

let drawn_strings (owner, module_path, binding_name) =
  match
    Ast_grep.string_literals_in_value_binding ~module_path ~binding_name
  with
  | [] ->
    Alcotest.failf
      "%s: no string literals under %s in %s -- the function moved, and this \
       check has been measuring nothing"
      owner binding_name module_path
  | literals -> List.map (fun text -> (drawn_width ~owner text, text)) literals

let test_every_vocabulary_fits_the_column () =
  let width = state_width () in
  List.iter
    (fun ((owner, _, _) as source) ->
      List.iter
        (fun (drawn, text) ->
          check Alcotest.bool
            (Printf.sprintf "%s: %S draws %d of %d cells" owner text drawn width)
            true (drawn <= width))
        (drawn_strings source))
    vocabularies

(* The column is full, and that is the fact worth pinning. A check that only
   said "fits" would keep passing if somebody narrowed the column to nineteen
   -- the arms would still fit, one of them by losing a character. Naming the
   exact fill means a change to either side has to be deliberate. *)
let test_the_column_has_no_slack () =
  let width = state_width () in
  let widest =
    List.fold_left
      (fun widest source ->
        List.fold_left
          (fun widest (drawn, text) ->
            if drawn > fst widest then (drawn, text) else widest)
          widest
          (drawn_strings source))
      (0, "")
      vocabularies
  in
  check Alcotest.int
    (Printf.sprintf "the widest thing drawn (%S) fills the column exactly"
       (snd widest))
    width (fst widest)

(* Two of them reach it, from different vocabularies. The issue that asked for
   this check named the fixed one; the formatted one fills the column only
   once a run answers in four digits, which is why it was not seen by reading
   the strings. Both are recorded so that raising the width for one does not
   look like it bought slack for the other -- and so the two that do not reach
   it are on record as not reaching it, which is what the exact list says. *)
let test_two_vocabularies_reach_the_edge () =
  let width = state_width () in
  let at_edge =
    List.concat_map
      (fun ((owner, _, _) as source) ->
        List.filter_map
          (fun (drawn, text) ->
            if drawn = width then Some (owner ^ ": " ^ text) else None)
          (drawn_strings source))
      vocabularies
  in
  check
    Alcotest.(list string)
    "the column is filled by these, and only these"
    [ "the delivery failure codes: evidence_unavailable"
    ; "the running stages: recording(%d/%d)"
    ]
    (List.sort compare at_edge)

let () =
  Alcotest.run "tui fusion state width"
    [ ( "the column"
      , [ Alcotest.test_case "every vocabulary fits" `Quick
            test_every_vocabulary_fits_the_column
        ; Alcotest.test_case "the column has no slack" `Quick
            test_the_column_has_no_slack
        ; Alcotest.test_case "two vocabularies reach the edge" `Quick
            test_two_vocabularies_reach_the_edge
        ] )
    ]
