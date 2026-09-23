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

(* The Tasks pane's own titles are the other shape: they share an opening and
   an ending and differ in between, which is exactly what a middle fold takes
   out. Measured on the live backlog 2026-09-24, 694 open tasks at this pane's
   room: the titles alone drew 30 rows in four groups that read alike, 18 of
   them "[triage]...(jeong-sik/masc)". The task id goes after the title, where
   the fold keeps it, and all 694 read differently; in front of the title 31
   rows still read alike, because a group's ids share their opening too. *)
let triage_title number =
  Printf.sprintf "[triage] #%d TUI \xed\x99\x94\xeb\xa9\xb4 (jeong-sik/masc)" number

let test_titles_that_share_both_ends_are_parted_by_the_id () =
  let room = Masc_tui_frame.inner_width ~cols:Masc_tui_roster_pane.pane_cols in
  let fold label = Masc_tui_message_layout.fit_middle room label in
  let bare_first = fold (triage_title 30858)
  and bare_second = fold (triage_title 30904) in
  Alcotest.(check string)
    "the titles alone fold to the same row" bare_first bare_second;
  let first =
    fold
      (Masc_tui_render_schedule.task_list_sidebar_label
         ~title:(triage_title 30858) ~task_id:"task-1174")
  and second =
    fold
      (Masc_tui_render_schedule.task_list_sidebar_label
         ~title:(triage_title 30904) ~task_id:"task-1175")
  in
  Alcotest.(check bool) "with the id they part" true (first <> second);
  Alcotest.(check bool) "and each row ends in its own id" true
    (String.ends_with ~suffix:"task-1174" first
    && String.ends_with ~suffix:"task-1175" second)

let () =
  Alcotest.run "tui_sidebar_index_fold"
    [ ( "sidebar index"
      , [ Alcotest.test_case "names that share an opening stay apart" `Quick
            test_names_that_share_an_opening_stay_apart
        ; Alcotest.test_case "the fold holds still under the cursor" `Quick
            test_the_fold_holds_still_under_the_cursor
        ; Alcotest.test_case "a row never runs past the frame" `Quick
            test_a_row_never_runs_past_the_frame
        ; Alcotest.test_case
            "titles that share both ends are parted by the id" `Quick
            test_titles_that_share_both_ends_are_parted_by_the_id
        ] )
    ]
