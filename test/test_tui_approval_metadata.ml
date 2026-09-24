(** The approval queue's metadata row is measured against the frame.

    Two rows are drawn under the queue's box: what the selected ask is made
    of, and its payload. The payload row always sized itself to the terminal.
    The metadata row never did — it was one [Printf.sprintf] per kind, each
    joining its values with two spaces and handing the finished row to the
    screen. With [expires] spelled as a full timestamp the operator row wanted
    eighty-four columns, so on an eighty-column terminal the deadline ran off
    the right edge: the one value the person about to press [y] is there to
    read (#36333).

    The row is a list of clauses packed to {!Masc_tui_frame.inner_width} now,
    so it breaks where a clause ends and keeps every value whole. That is the
    rule this surface already states for the ask body, where a value too wide
    for the pane wraps rather than being cut.

    These tests read the clause vocabulary out of the renderer instead of
    keeping a copy: a copy goes stale while the row quietly overflows again.
    The renderer is an executable module that no test can link, so the reading
    is done through {!Ast_grep}. *)

module Layout = Masc_tui_message_layout
module Frame = Masc_tui_frame

let module_path = "bin/masc_tui_render.ml"
let binding_name = "approval_metadata_lines"

let check_bool = Alcotest.(check bool)
let check_int = Alcotest.(check int)

let literals () =
  Ast_grep.string_literals_in_value_binding ~module_path ~binding_name

let contains haystack needle =
  let n = String.length needle in
  let rec go i =
    i + n <= String.length haystack
    && (String.equal (String.sub haystack i n) needle || go (i + 1))
  in
  n = 0 || go 0

(* A clause format is a label, [=], and one substitution: "trace=%s". *)
let is_clause_format text =
  let n = String.length text in
  n > 3
  && String.equal (String.sub text (n - 3) 3) "=%s"
  &&
  let label = String.sub text 0 (n - 3) in
  String.length label > 0
  && String.for_all (fun c -> (c >= 'a' && c <= 'z') || c = '_') label

let clause_labels () =
  literals ()
  |> List.filter is_clause_format
  |> List.map (fun text -> String.sub text 0 (String.length text - 3))
  |> List.sort_uniq String.compare

let test_every_value_is_its_own_clause () =
  (* Three kinds of ask share this row: an operator decision, a held tool
     call, and a Gate request. Naming them here means a kind that grows a
     tenth value has to come through this test, which is the only place that
     sizes them. *)
  Alcotest.(check (list string))
    "the row carries these values and no others"
    [ "approval"
    ; "at"
    ; "call"
    ; "created"
    ; "expires"
    ; "keeper"
    ; "operation"
    ; "sandbox"
    ; "trace"
    ]
    (clause_labels ())

let test_no_row_is_joined_by_hand () =
  (* Every overflow this file closes had one shape in the source: a value
     followed by two spaces, inside a format string the screen then drew
     whole. Nothing measured the result, and nothing could — the row was
     finished before anybody knew the width. A clause list cannot say it. *)
  List.iter
    (fun text ->
      check_bool
        (Printf.sprintf "no clause is joined by hand inside %S" text)
        false
        (contains text "%s  "))
    (literals ())

let test_the_row_is_packed_to_the_frame () =
  (* Without this the clauses could be joined again a line later and every
     other assertion here would still pass. *)
  check_int "the metadata row is packed to a width exactly once" 1
    (Ast_grep.count_applications_with_labelled_argument_in_value_binding
       ~module_path ~binding_name ~callee:"Message_layout.pack_clauses"
       ~label:"max_cells")

(* The widest thing each clause actually carries on this screen. An unknown
   label fails rather than defaulting to something short: a new clause that
   quietly gets a four-character value would be measured as fitting
   everywhere, which is the reading that let this row reach eighty-four
   columns in the first place. *)
let value_for = function
  | "approval" -> "rw-e0-r9-20260820-review"
  | "at" -> "/Users/dancer/me/.masc/playground/tui-developer/masc"
  | "call" -> "call-0198f3ab-7c21-7000-9d3e-2f1a4b6c8d90"
  | "created" | "expires" -> "2026-08-22 09:03:00"
  | "keeper" -> "kidsnote-slack-context-collector"
  | "operation" -> "namespace_pause"
  | "sandbox" -> "container"
  | "trace" -> "trace-1789042595401-00001"
  | other ->
      Alcotest.failf "the renderer grew a clause this test does not size: %s"
        other

let clauses () =
  List.map
    (fun label -> Printf.sprintf "%s=%s" label (value_for label))
    (clause_labels ())

let widths = [ 60; 80; 100; 120; 140; 180 ]

let test_every_row_fits_the_frame () =
  let clauses = clauses () in
  List.iter
    (fun cols ->
      let room = Frame.inner_width ~cols in
      let rows = Layout.pack_clauses ~max_cells:room clauses in
      List.iter
        (fun row ->
          check_bool
            (Printf.sprintf "a row stays inside %d columns" cols)
            true
            (Layout.display_width row <= room))
        rows)
    widths

let test_no_value_is_cut_on_the_way () =
  (* Fitting is not enough on its own: a row that cut every value to four
     cells would fit every width here. What the operator needs is the value,
     so each one has to come back whole. *)
  let clauses = clauses () in
  List.iter
    (fun cols ->
      let drawn =
        String.concat " "
          (Layout.pack_clauses ~max_cells:(Frame.inner_width ~cols) clauses)
      in
      List.iter
        (fun clause ->
          check_bool
            (Printf.sprintf "%S survives whole at %d columns" clause cols)
            true
            (contains drawn clause))
        clauses)
    widths

let test_a_narrow_frame_spends_the_rows_it_needs () =
  let clauses = clauses () in
  let rows_at cols =
    List.length (Layout.pack_clauses ~max_cells:(Frame.inner_width ~cols) clauses)
  in
  (* The budget above this row subtracts the rows it actually draws. If a
     narrow frame never needed a second row that subtraction would be dead
     code, and the row would be free to overflow again unnoticed. *)
  check_bool "eighty columns needs more than one row" true (rows_at 80 > 1);
  check_bool "a frame wide enough spends exactly one" true (rows_at 400 = 1);
  check_bool "widening never makes the row taller" true
    (rows_at 80 >= rows_at 140)

let () =
  Alcotest.run "tui_approval_metadata"
    [ ( "approval metadata row"
      , [ Alcotest.test_case "every value is its own clause" `Quick
            test_every_value_is_its_own_clause
        ; Alcotest.test_case "no row is joined by hand" `Quick
            test_no_row_is_joined_by_hand
        ; Alcotest.test_case "the row is packed to the frame" `Quick
            test_the_row_is_packed_to_the_frame
        ; Alcotest.test_case "every row fits the frame" `Quick
            test_every_row_fits_the_frame
        ; Alcotest.test_case "no value is cut on the way" `Quick
            test_no_value_is_cut_on_the_way
        ; Alcotest.test_case "a narrow frame spends the rows it needs" `Quick
            test_a_narrow_frame_spends_the_rows_it_needs
        ] )
    ]
