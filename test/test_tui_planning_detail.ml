(** A goal's detail says what the judge decided.

    The list draws the verdict and its reason under the cursor; the detail
    drew neither, so opening a goal showed less than the row it was opened
    from. Its footer still advertised [j/k:scroll] and the key handler still
    kept a scroll for it -- over a screen with nothing on it to move.

    These tests pin the block that fills it: every verdict produces rows, a
    reason wraps rather than being cut, and an idle ledger says so instead of
    drawing the same blank a decode failure would. *)

module Detail = Masc_tui_planning_detail
module Proof = Masc.Tui_decode

let texts rows = List.map (fun (r : Detail.line) -> r.Detail.text) rows
let tones rows = List.map (fun (r : Detail.line) -> r.Detail.tone) rows

let check_bool = Alcotest.(check bool)
let check_int = Alcotest.(check int)
let check_string = Alcotest.(check string)

let test_every_verdict_draws_something () =
  let cases =
    [ ("proven", Proof.Proof_proven None)
    ; ("proven with evidence", Proof.Proof_proven (Some "42 runs, 0 red"))
    ; ("refused", Proof.Proof_refuted None)
    ; ("refused with reason", Proof.Proof_refuted (Some "no evidence file"))
    ; ("pending", Proof.Proof_pending)
    ; ("unreadable", Proof.Proof_unreadable None)
    ; ("unreadable with detail", Proof.Proof_unreadable (Some "bad json"))
    ; ("idle", Proof.Proof_idle)
    ]
  in
  List.iter
    (fun (name, proof) ->
      let rows = Detail.body ~width:60 proof None in
      check_bool (name ^ " draws at least one row") true (rows <> []))
    cases

let test_idle_is_not_silence () =
  let rows = Detail.body ~width:60 Proof.Proof_idle None in
  check_int "an idle ledger draws one row" 1 (List.length rows);
  check_string "and says the ledger is empty rather than nothing"
    "no verdict on the ledger" (List.hd (texts rows))

let test_a_long_reason_wraps_instead_of_being_cut () =
  let reason = String.concat " " (List.init 40 (fun i -> Printf.sprintf "word%d" i)) in
  let rows = Detail.body ~width:30 (Proof.Proof_refuted (Some reason)) None in
  check_bool "the reason takes more than one row" true (List.length rows > 2);
  List.iter
    (fun text ->
      check_bool ("row fits the width: " ^ text) true (String.length text <= 30 * 4))
    (texts rows);
  let rejoined = String.concat " " (List.tl (texts rows)) in
  check_bool "the last word survives the wrap" true
    (let needle = "word39" in
     let rec found i =
       i + String.length needle <= String.length rejoined
       && (String.sub rejoined i (String.length needle) = needle || found (i + 1))
     in
     found 0)

let test_the_note_reads_after_the_verdict () =
  let rows =
    Detail.body ~width:60 (Proof.Proof_proven (Some "measured")) (Some "watch the flake")
  in
  let texts = texts rows in
  check_string "the verdict heads the block" "proven" (List.hd texts);
  check_bool "the note is labelled" true (List.mem "note" texts);
  check_bool "and its text follows" true (List.mem "watch the flake" texts)

let test_tone_separates_a_refusal_from_a_proof () =
  let proven = tones (Detail.body ~width:60 (Proof.Proof_proven None) None) in
  let refused = tones (Detail.body ~width:60 (Proof.Proof_refuted None) None) in
  check_bool "a proof reads as proven" true (List.hd proven = Detail.Proven);
  check_bool "a refusal reads as refused" true (List.hd refused = Detail.Refused)

let test_a_narrow_pane_still_produces_rows () =
  let rows = Detail.body ~width:0 (Proof.Proof_refuted (Some "why")) None in
  check_bool "width 0 does not loop or vanish" true (rows <> [])

let () =
  Alcotest.run "tui_planning_detail"
    [ ( "body"
      , [ Alcotest.test_case "every verdict draws something" `Quick
            test_every_verdict_draws_something
        ; Alcotest.test_case "idle is not silence" `Quick test_idle_is_not_silence
        ; Alcotest.test_case "a long reason wraps instead of being cut" `Quick
            test_a_long_reason_wraps_instead_of_being_cut
        ; Alcotest.test_case "the note reads after the verdict" `Quick
            test_the_note_reads_after_the_verdict
        ; Alcotest.test_case "tone separates a refusal from a proof" `Quick
            test_tone_separates_a_refusal_from_a_proof
        ; Alcotest.test_case "a narrow pane still produces rows" `Quick
            test_a_narrow_pane_still_produces_rows
        ] )
    ]
