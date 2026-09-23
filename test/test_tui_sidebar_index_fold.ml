(* A list pane's index of names. The frame cut each row's tail, so names that
   share an opening -- the Board's "#verification Approved task ..." posts --
   all drew the same row and a reader could not pick one out of the column.
   Measured on the live Board, 50 posts folded to 28 cells: a tail cut left
   nine rows in three groups that read alike; a middle fold left fifty
   distinct. *)

let strip_sgr row =
  let buf = Buffer.create (String.length row) in
  let in_escape = ref false in
  String.iter
    (fun ch ->
      if !in_escape then (if ch = 'm' then in_escape := false)
      else if ch = '\027' then in_escape := true
      else Buffer.add_char buf ch)
    row;
  Buffer.contents buf

(* The frame's vertical rule, three bytes, and the space it keeps on each
   side. *)
let border_bytes = String.length Masc_tui_theme.Box.v + 1

let content_rows ~cols ~focused ~labels ~selected =
  let buf = Buffer.create 1024 in
  Masc_tui_render_prim.write_list_sidebar buf ~rows:12 ~cols ~title:"Board"
    ~focused ~labels ~selected;
  match String.split_on_char '\n' (strip_sgr (Buffer.contents buf)) with
  | _top :: _title :: _divider :: rest ->
    List.filter_map
      (fun line ->
        if String.length line <= 2 * border_bytes then None
        else
          Some
            (String.sub line border_bytes
               (String.length line - (2 * border_bytes))))
      rest
    |> fun rows -> List.filteri (fun i _ -> i < List.length labels) rows
  | _ -> []

let trimmed row = String.trim row

(* Two Board posts whose opening is the same and whose ends are what part
   them, the shape the live capture found nine of. *)
let approved_by_anyang =
  "#verification Approved task 7741 for keeper anyang-keepers"

let approved_by_pangyo =
  "#verification Approved task 7741 for keeper pangyo-preachers"

let test_names_that_share_an_opening_stay_apart () =
  match
    content_rows ~cols:40 ~focused:true
      ~labels:[ approved_by_anyang; approved_by_pangyo ]
      ~selected:0
  with
  | [ first; second ] ->
    Alcotest.(check bool)
      "the two rows read differently" true
      (trimmed first <> trimmed second);
    Alcotest.(check bool)
      "each row still carries its own ending" true
      (String.ends_with ~suffix:"anyang-keepers" (trimmed first)
      && String.ends_with ~suffix:"pangyo-preachers" (trimmed second))
  | rows ->
    Alcotest.failf "expected two label rows, drew %d" (List.length rows)

let first_row ~cols ~focused ~selected =
  match
    content_rows ~cols ~focused
      ~labels:[ approved_by_anyang; approved_by_pangyo ]
      ~selected
  with
  | first :: _ -> trimmed first
  | [] -> Alcotest.fail "the pane drew no label row"

let test_the_fold_holds_still_under_the_cursor () =
  (* The caret row leads with two cells more than a plain row. Both fold the
     name to the room the caret leaves, so the name does not re-fold as the
     cursor passes over it. *)
  let plain = first_row ~cols:44 ~focused:false ~selected:1 in
  let under_the_caret = first_row ~cols:44 ~focused:false ~selected:0 in
  Alcotest.(check string)
    "the caret row folds the name the way the plain row does"
    (Masc_tui_theme.Glyph.current_entry ^ " " ^ plain)
    under_the_caret

let test_a_row_never_runs_past_the_frame () =
  let cols = 36 in
  let rows =
    content_rows ~cols ~focused:false
      ~labels:[ approved_by_anyang; approved_by_pangyo ]
      ~selected:0
  in
  Alcotest.(check int) "both labels drew" 2 (List.length rows);
  List.iter
    (fun row ->
      Alcotest.(check int)
        "the row fills the frame's inner width exactly"
        (Masc_tui_frame.inner_width ~cols)
        (Masc_tui_message_layout.display_width row))
    rows

let () =
  Alcotest.run "tui_sidebar_index_fold"
    [ ( "sidebar index"
      , [ Alcotest.test_case "names that share an opening stay apart" `Quick
            test_names_that_share_an_opening_stay_apart
        ; Alcotest.test_case "the fold holds still under the cursor" `Quick
            test_the_fold_holds_still_under_the_cursor
        ; Alcotest.test_case "a row never runs past the frame" `Quick
            test_a_row_never_runs_past_the_frame
        ] )
    ]
