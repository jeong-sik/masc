(** Decoding what the working tree holds.

    The rows arrive already parsed, with the line numbers git computed. That
    is the half the tool-call reading cannot have: an [Edit] records two
    pieces of text and no idea where in the file they sit. *)

open Alcotest

module D = Masc.Tui_decode

let decode_ok body =
  match D.decode_git_diff (Yojson.Safe.from_string body) with
  | Ok diff -> diff
  | Error detail -> failf "expected a decode, got: %s" detail
;;

let decode_error body =
  match D.decode_git_diff (Yojson.Safe.from_string body) with
  | Ok _ -> failf "expected a rejection"
  | Error detail -> detail
;;

let kind_name = function
  | D.Gd_context -> "context"
  | D.Gd_added -> "added"
  | D.Gd_removed -> "removed"
;;

let test_reads_the_three_kinds () =
  let diff =
    decode_ok
      {|{"has_changes":true,"unified":[
        {"kind":"context","oldLine":10,"newLine":10,"text":"unchanged"},
        {"kind":"delete","oldLine":11,"newLine":null,"text":"gone"},
        {"kind":"add","oldLine":null,"newLine":11,"text":"new"}]}|}
  in
  check bool "changes reported" true diff.D.gd_has_changes;
  check (list string) "in the order git gave them"
    [ "context"; "removed"; "added" ]
    (List.map (fun row -> kind_name row.D.gdr_kind) diff.D.gd_rows)
;;

(* The numbers are the point of this reading, and each side is absent on the
   half where the line does not exist. Absent is not zero: a zero would draw
   as a line number and claim a position the line does not have. *)
let test_a_missing_number_stays_missing () =
  let diff =
    decode_ok
      {|{"has_changes":true,"unified":[
        {"kind":"add","oldLine":null,"newLine":42,"text":"x"},
        {"kind":"delete","oldLine":41,"newLine":null,"text":"y"}]}|}
  in
  match diff.D.gd_rows with
  | [ added; removed ] ->
      check (option int) "an added line has no old number" None added.D.gdr_old_line;
      check (option int) "it has a new one" (Some 42) added.D.gdr_new_line;
      check (option int) "a removed line has an old number" (Some 41)
        removed.D.gdr_old_line;
      check (option int) "and no new one" None removed.D.gdr_new_line
  | rows -> failf "expected two rows, got %d" (List.length rows)
;;

(* git's vocabulary is closed. A fourth word means the server changed under
   us, and reading it as context would draw an unchanged line where something
   happened -- the opposite of whatever it was. *)
let test_an_unknown_kind_is_rejected () =
  let detail =
    decode_error
      {|{"has_changes":true,"unified":[{"kind":"rename","oldLine":1,"newLine":1,"text":"x"}]}|}
  in
  check bool "the word is named" true
    (let needle = "rename" in
     let n = String.length needle and h = String.length detail in
     let rec at i = i + n <= h && (String.sub detail i n = needle || at (i + 1)) in
     at 0)
;;

(* No changes and no rows is a real answer: the file matches its base. It has
   to survive decoding as itself rather than as a failure. *)
let test_a_clean_file_decodes () =
  let diff = decode_ok {|{"has_changes":false,"unified":[]}|} in
  check bool "no changes" false diff.D.gd_has_changes;
  check int "and no rows" 0 (List.length diff.D.gd_rows)
;;

let test_a_missing_field_is_rejected () =
  let _ = decode_error {|{"unified":[]}|} in
  let _ = decode_error {|{"has_changes":true}|} in
  check bool "both rejected" true true
;;

let () =
  run "tui_git_diff_decode"
    [ ( "rows"
      , [ test_case "the three kinds" `Quick test_reads_the_three_kinds
        ; test_case "a missing number stays missing" `Quick
            test_a_missing_number_stays_missing
        ] )
    ; ( "rejection"
      , [ test_case "an unknown kind" `Quick test_an_unknown_kind_is_rejected
        ; test_case "a missing field" `Quick test_a_missing_field_is_rejected
        ] )
    ; ("empty", [ test_case "a clean file" `Quick test_a_clean_file_decodes ])
    ]
;;
