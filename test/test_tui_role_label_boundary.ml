(** Where the speaker mark ends, so the renderer does not measure it again.

    The chat gutter used to take the status colour and bold as one span, which
    painted an errored turn's kind label red beside its glyph — the same fact
    twice on one row. Splitting it needs a boundary, and the boundary has to
    come from the code that laid the mark out. A renderer measuring the glyph a
    second time is how the two drift: the arithmetic ends up in the drawing
    side and the next change to either forgets the other.

    So [role_label_mark_cells] answers it and [align_role_label] obeys the same
    decision. These check that they agree — including at the narrow columns
    where the mark is dropped entirely and the answer has to be zero. *)

open Alcotest
module Layout = Masc_tui_message_layout

let styles =
  [ ("user", Layout.User)
  ; ("keeper", Layout.Keeper)
  ; ("status", Layout.Status)
  ; ("journal", Layout.Journal)
  ; ("error", Layout.Error)
  ; ("tool", Layout.Tool)
  ; ("thinking", Layout.Thinking)
  ]
;;

(* The boundary is only useful if the cells before it really are the mark and
   its separator, so cut the label there and see what comes back. *)
let test_boundary_lands_after_the_mark () =
  List.iter
    (fun (name, style) ->
       let column = 16 in
       let label = Layout.align_role_label ~column ~style "TOOLS" in
       let at = Layout.role_label_mark_cells ~column ~style () in
       check bool (name ^ ": the mark is kept at this width") true (at > 0);
       let head = Layout.take_cells label at in
       let tail = Layout.drop_cells label at in
       check
         int
         (name ^ ": the head is exactly the boundary")
         at
         (Layout.display_width head);
       check
         bool
         (name ^ ": the kind label is what follows")
         true
         (String.length (String.trim tail) > 0))
    styles
;;

(* [align_role_label] drops the mark when the column cannot hold both. The
   boundary has to drop with it, or the renderer colours the first cells of the
   name as though they were a glyph. *)
let test_narrow_column_reports_no_mark () =
  List.iter
    (fun (name, style) ->
       List.iter
         (fun column ->
            let at = Layout.role_label_mark_cells ~column ~style () in
            let label = Layout.align_role_label ~column ~style "TOOLS" in
            check int (Printf.sprintf "%s at %d: no mark" name column) 0 at;
            check
              int
              (Printf.sprintf "%s at %d: label still fills the column" name column)
              column
              (Layout.display_width label))
         [ 1; 2 ])
    styles
;;

(* The renderer slices the gutter at this offset, so it must never point past
   the label it came from. *)
let test_boundary_is_within_the_label () =
  List.iter
    (fun (name, style) ->
       List.iter
         (fun column ->
            let at = Layout.role_label_mark_cells ~column ~style () in
            let label = Layout.align_role_label ~column ~style "MEMORY" in
            check
              bool
              (Printf.sprintf "%s at %d: inside the label" name column)
              true
              (at <= Layout.display_width label))
         [ 1; 2; 3; 4; 8; 16; 24 ])
    styles
;;

(* The renderer cuts the gutter at the boundary and writes both halves back
   out, one styled as a glyph and one as a name. So the halves have to add up
   to what they were cut from -- at every column, including the narrow ones
   where the boundary is zero because there is no mark left to colour.

   Cutting with [split_cells] did not add up. That one wraps, and a wrapper
   has to move forward or it never ends, so at zero cells it still handed back
   a piece: the head came out holding a character the tail also held. On the
   Keepers pane every row that continued the speaker above it reported no
   mark, and every one of them drew its clock's first digit twice -- a row
   sent at 22:32 read "222:32". *)
let test_cut_conserves_the_label () =
  List.iter
    (fun (name, style) ->
       List.iter
         (fun column ->
            let label = Layout.align_role_label ~column ~style "TOOLS" in
            let at = Layout.role_label_mark_cells ~column ~style () in
            let head = Layout.take_cells label at in
            let tail = Layout.drop_cells label at in
            check
              int
              (Printf.sprintf "%s at %d: the halves add up" name column)
              (Layout.display_width label)
              (Layout.display_width head + Layout.display_width tail);
            check
              int
              (Printf.sprintf "%s at %d: the head is the boundary" name column)
              at
              (Layout.display_width head))
         [ 1; 2; 3; 4; 8; 16; 24 ])
    styles
;;

(* The case above is only carried by columns that actually report no mark. If
   the narrow widths ever start keeping one, the zero-cut goes untested and
   the conservation check passes on rows that were never the problem. *)
let test_the_zero_cut_is_covered () =
  let zero_cuts =
    List.concat_map
      (fun (_, style) ->
         List.filter
           (fun column -> Layout.role_label_mark_cells ~column ~style () = 0)
           [ 1; 2; 3; 4; 8; 16; 24 ])
      styles
  in
  check bool "some column cuts at zero" true (zero_cuts <> [])
;;

let () =
  run
    "tui role label boundary"
    [ ( "mark"
      , [ test_case "boundary lands after the mark" `Quick test_boundary_lands_after_the_mark
        ; test_case "narrow column reports no mark" `Quick test_narrow_column_reports_no_mark
        ; test_case "boundary is within the label" `Quick test_boundary_is_within_the_label
        ; test_case "cut conserves the label" `Quick test_cut_conserves_the_label
        ; test_case "the zero cut is covered" `Quick test_the_zero_cut_is_covered
        ] )
    ]
;;
