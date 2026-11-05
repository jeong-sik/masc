(* A notice that leads the footer row takes a step down before it is given up:
   the operator-action notice is drawn whole while its first reason fits, as
   its count alone when only the count fits, and not at all only when not even
   the count fits beside the keys that cannot be dropped. A notice with no
   shorter text goes whole, as it did. These cases read the row the pure
   function returns, width by width, and check what must hold at every width
   rather than how one width looks. *)

let contains ~needle text =
  try
    ignore (Str.search_forward (Str.regexp_string needle) text 0);
    true
  with Not_found -> false

let cells = Masc_tui_message_layout.display_width
let check_bool label expected actual = Alcotest.(check bool) label expected actual
let hints = "j/k:move  Enter:open  r:refresh  q:quit"
let max_width = 200

let row_at ~status width =
  let line =
    Masc_tui_footer.line ~status ~dim:"" ~reset:"" ~max_cells:width ~port:8935
      ~hints ()
    |> Masc_tui_theme.strip_sgr
  in
  match String.split_on_char '\n' line with
  | [ row; "" ] -> row
  | _ -> Alcotest.failf "%d cells: the footer is not one line: %S" width line

let first_reason = "keeper_fleet_safety:no_executable_keeper_fibers"
let operator_notice = Masc_tui_footer.Operator_action { first = first_reason; count = 3 }
let count_only = "ACTION NEEDED 3"
let whole_notice = count_only ^ " \xc2\xb7 " ^ first_reason

(* The narrowest row that can carry the count: the notice, the keys that
   cannot be dropped, and the mark that says the row was cut. *)
let narrowest_row_with_the_count =
  cells ("  " ^ count_only ^ "  Enter:open  q:quit  \xe2\x80\xa6?")

let widths = List.init (max_width + 1) Fun.id

let test_the_count_is_kept_when_the_reason_does_not_fit () =
  let rows = List.map (fun width -> width, row_at ~status:[ operator_notice ] width) widths in
  List.iter
    (fun (width, row) ->
      let label what = Printf.sprintf "%d cells: %s" width what in
      check_bool (label "the row fits") true (cells row <= width);
      let drawn = contains ~needle:"ACTION NEEDED" row in
      check_bool (label "drawn from the narrowest row that can carry the count")
        true
        (drawn || width < narrowest_row_with_the_count);
      if drawn then begin
        check_bool (label "the notice leads the row") true
          (String.starts_with ~prefix:("  " ^ count_only) row);
        check_bool (label "the reason is whole or left out") true
          (contains ~needle:whole_notice row
           || not (contains ~needle:" \xc2\xb7 " row));
        check_bool (label "the keys that cannot be dropped stay") true
          (contains ~needle:"Enter:open" row && contains ~needle:"q:quit" row)
      end)
    rows;
  let drawn_at width =
    contains ~needle:"ACTION NEEDED" (List.assoc width rows)
  in
  List.iter
    (fun width ->
      if width < max_width && drawn_at width then
        check_bool
          (Printf.sprintf "%d cells: drawn, so drawn one cell wider" width)
          true (drawn_at (width + 1)))
    widths;
  let count_only_rows =
    List.filter
      (fun (_, row) ->
        contains ~needle:count_only row
        && not (contains ~needle:whole_notice row))
      rows
  in
  check_bool "some width draws the count alone" true (count_only_rows <> []);
  check_bool "some width draws the whole notice" true
    (List.exists (fun (_, row) -> contains ~needle:whole_notice row) rows)

(* A notice with no shorter text is whole or absent, and it outranks the
   operator notice: wherever it can be drawn at all it is, and the lower-ranked
   notice steps down first. *)
let test_a_notice_without_a_shorter_text_outranks_the_operator_notice () =
  let local = "/srv/example/workspace" in
  let whole_mismatch = "MISMATCH local " ^ local ^ " (r:retry)" in
  let narrowest_row_with_the_mismatch =
    cells ("  " ^ whole_mismatch ^ "  Enter:open  q:quit  \xe2\x80\xa6?")
  in
  let rows =
    List.map
      (fun width ->
        ( width
        , row_at
            ~status:[ operator_notice; Masc_tui_footer.Workspace_mismatch local ]
            width ))
      widths
  in
  List.iter
    (fun (width, row) ->
      let label what = Printf.sprintf "%d cells: %s" width what in
      check_bool (label "the row fits") true (cells row <= width);
      check_bool (label "the mismatch is whole or left out") true
        (contains ~needle:whole_mismatch row
         || not (contains ~needle:"MISMATCH" row));
      check_bool (label "drawn from the narrowest row that can carry the mismatch")
        true
        (contains ~needle:whole_mismatch row
         || width < narrowest_row_with_the_mismatch))
    rows;
  check_bool "some width draws the mismatch beside the count alone" true
    (List.exists
       (fun (_, row) ->
         contains ~needle:whole_mismatch row
         && contains ~needle:count_only row
         && not (contains ~needle:whole_notice row))
       rows)

let () =
  Alcotest.run "tui_footer_notice_forms"
    [ ( "leading notice"
      , [ Alcotest.test_case "the count is kept when the reason does not fit" `Quick
            test_the_count_is_kept_when_the_reason_does_not_fit
        ; Alcotest.test_case
            "a notice without a shorter text outranks the operator notice" `Quick
            test_a_notice_without_a_shorter_text_outranks_the_operator_notice
        ] )
    ]
