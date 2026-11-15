(** What the Task document does with styles and what a note costs, not where
    it puts them.

    A row the document prepares carries a style only when the document put it
    there, and a style never outlives its row. A note costs what its rows
    show, however deep it nests. None of the checks reads a width, a heading
    or a label: the constitution keeps those out of tests, and the screen
    captures in the pull request are the evidence for them. *)

open Alcotest

module Document = Masc_tui_task_document

let reset = Masc_tui_ansi.Ansi.reset

(* A sequence the document itself never draws: the red a task's own text
   might ask for. *)
let hostile_style = "\027[31m"

let todo = Masc_domain.Todo

let claimed =
  Masc_domain.Claimed { assignee = "agent"; claimed_at = "2026-11-05T01:00:00Z" }

let in_progress =
  Masc_domain.InProgress { assignee = "agent"; started_at = "2026-11-05T01:00:00Z" }

let awaiting_verification =
  Masc_domain.AwaitingVerification
    { assignee = "agent"
    ; started_at = "2026-11-05T01:00:00Z"
    ; submitted_at = "2026-11-05T02:00:00Z"
    ; verification_id = "verification-1"
    }

let done_ =
  Masc_domain.Done
    { assignee = "agent"; completed_at = "2026-11-05T03:00:00Z"; notes = Some "shipped" }

let cancelled =
  Masc_domain.Cancelled
    { cancelled_by = "operator"
    ; cancelled_at = "2026-11-05T03:00:00Z"
    ; reason = Some "superseded"
    }

let task ~title ~created_by ~status : Masc_domain.task =
  { Masc_domain.
    id = "task-1"
  ; title
  ; description = "first line\nsecond line"
  ; task_status = status
  ; priority = 3
  ; files = []
  ; created_at = "2026-11-05T00:00:00Z"
  ; created_by
  ; predecessor_task_id = None
  ; contract = None
  ; execution_links = Masc_domain.no_execution_links
  ; handoff_context = None
  ; cycle_count = 0
  ; skills = []
  }

let body_rows ~cols task =
  Document.prepare (Document.body ~ko:false ~cols ~goals:(Document.Membership [ "goal-1" ]) task)

let contains ~affix text =
  let affix_length = String.length affix in
  let rec from index =
    index + affix_length <= String.length text
    && (String.equal (String.sub text index affix_length) affix || from (index + 1))
  in
  from 0

let every_status =
  [ todo; claimed; in_progress; awaiting_verification; done_; cancelled ]

let test_task_text_cannot_put_a_style_on_a_row () =
  List.iter
    (fun status ->
      let rows =
        body_rows ~cols:100
          (task ~title:("before " ^ hostile_style ^ "after") ~created_by:(Some hostile_style)
             ~status)
      in
      check bool "the sequence a task's text carries reaches no row" false
        (List.exists (contains ~affix:hostile_style) rows))
    every_status

(* The History part: a note is a JSON object or array, or prose, and only a JSON
   object or array is coloured. *)
let event ~note : Masc.Tui_decode.task_history_event =
  { Masc.Tui_decode.
    th_origin = None
  ; th_ts = "2026-11-05T01:02:03Z"
  ; th_label = "handoff"
  ; th_from_status = None
  ; th_to_status = None
  ; th_actor = Some "agent"
  ; th_note = note
  }

let history_rows ~cols notes =
  Document.prepare
    (Document.history ~ko:false ~cols (List.map (fun note -> event ~note) notes))

let test_document_identity_includes_language () =
  let source = task ~title:"Original request" ~created_by:None ~status:todo in
  let body ko = Document.body ~ko ~cols:72 ~goals:Document.Unread source in
  check bool "same immutable source and language can reuse preparation" true
    (Document.equal_input (body false) (body false));
  check bool "a language change withdraws body reuse" false
    (Document.equal_input (body false) (body true));
  let events = [event ~note:None] in
  let history ko = Document.history ~ko ~cols:72 events in
  check bool "a language change withdraws history reuse" false
    (Document.equal_input (history false) (history true))

(* Within one row every style that opens is reset before the row ends. *)
let check_every_style_closes_in_its_row rows =
  List.iter
    (fun row ->
      let is_open = ref false in
      let length = String.length row in
      let rec scan index =
        if index < length then
          if row.[index] = '\027' then begin
            let stop =
              match String.index_from_opt row index 'm' with
              | Some stop -> stop + 1
              | None -> length
            in
            let escape = String.sub row index (stop - index) in
            if String.equal escape reset then begin
              check bool "a reset closes a style that opened in the row" true !is_open;
              is_open := false
            end
            else is_open := true;
            scan stop
          end
          else scan (index + 1)
      in
      scan 0;
      check bool "no style is left open at the end of a row" false !is_open)
    rows

(* Yojson reads these numbers and cannot write them back. *)
let test_a_note_with_a_number_json_cannot_write_is_drawn () =
  List.iter
    (fun (note, word) ->
      let rows = history_rows ~cols:100 [ Some note ] in
      check bool (note ^ " is drawn") true (List.exists (contains ~affix:word) rows);
      check_every_style_closes_in_its_row rows)
    [ "[NaN]", "NaN"; {|{"n": Infinity}|}, "Infinity"; "[1, -Infinity]", "-Infinity"; "[1E400]", "Infinity" ]

(* A note costs what its rows show, not how deep it nests. A note nested
   ten thousand deep is twenty thousand lines, and a row keeps a line's
   indent only up to half its width. Spelling every indent out first made
   the note's preparation build text that grew with the square of its depth
   (200 MB at this depth, #48554), all of it thrown away row by row.

   The bytes allocated per row are set against a flat note's, whose rows
   are as many and as plain. Depth may only move a row's text further in,
   and never past half the width, so a deep row may cost up to twice what a
   flat one does; text that grew with depth costs the deep note hundreds of
   times more. *)
let allocated_per_row note =
  let before = Gc.allocated_bytes () in
  let rows = history_rows ~cols:100 [ Some note ] in
  (Gc.allocated_bytes () -. before) /. float_of_int (List.length rows)

let test_a_deep_note_costs_what_its_rows_show () =
  let depth = 10_000 in
  let deep = String.make depth '[' ^ String.make depth ']' in
  (* As many lines as the deep note draws, [2 * depth - 1] with its innermost
     [[]] on one: the elements and the two brackets around them. *)
  let flat = "[" ^ String.concat "," (List.init ((2 * depth) - 3) (fun _ -> "0")) ^ "]" in
  let deep_cost = allocated_per_row deep and flat_cost = allocated_per_row flat in
  check bool
    (Printf.sprintf "a deep note's row costs at most twice a flat one's (%.0f vs %.0f bytes)"
       deep_cost flat_cost)
    true
    (deep_cost <= 2. *. flat_cost)

let test_note_text_cannot_put_a_style_on_a_history_row () =
  let hostile_json = Some ("{\n  \"k\": \"" ^ hostile_style ^ "after\"\n}") in
  let hostile_prose = Some ("before " ^ hostile_style ^ "after") in
  List.iter
    (fun note ->
      let rows = history_rows ~cols:100 [ note ] in
      check bool "the sequence a note carries reaches no row" false
        (List.exists (contains ~affix:hostile_style) rows))
    [ hostile_json; hostile_prose ]

let () =
  run "tui task document style"
    [ ("identity", [test_case "language binds prepared documents" `Quick test_document_identity_includes_language])
    ; ( "style"
      , [ test_case "task text cannot put a style on a row" `Quick
            test_task_text_cannot_put_a_style_on_a_row
        ; test_case "note text cannot put a style on a history row" `Quick
            test_note_text_cannot_put_a_style_on_a_history_row
        ; test_case "a note with a number JSON cannot write is drawn" `Quick
            test_a_note_with_a_number_json_cannot_write_is_drawn
        ] )
    ; ( "cost"
      , [ test_case "a deep note costs what its rows show" `Quick
            test_a_deep_note_costs_what_its_rows_show
        ] )
    ]
